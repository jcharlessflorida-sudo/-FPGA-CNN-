// cnn_top.v — MNIST CNN 推理核(conv-relu-pool-affine-relu-affine-argmax)
// int8 权重 / int8 激活 / int32 累加。纯通用 Verilog(不实例化 PH1P 原语),
// 可被 ModelSim 直接仿真,TD 综合时内存推断为块 RAM。
//
// 接口:
//   I_img_wr_en/addr/data : 推理前写入 784 字节输入图(0..255 原始像素)
//   I_start               : 一拍脉冲,开始推理
//   O_done                : 一拍脉冲,推理完成
//   O_class               : argmax 类别 0..9
//   O_logits              : 10 个 int32 logits(扁平 320 位)
`timescale 1ns/1ps
module cnn_top (
  input  wire         I_clk,
  input  wire         I_rst_n,
  input  wire         I_start,
  input  wire         I_img_wr_en,
  input  wire [9:0]   I_img_wr_addr,
  input  wire [7:0]   I_img_wr_data,
  output reg          O_done,
  output reg  [3:0]   O_class,
  output wire [319:0] O_logits
);

  `include "cnn_params.vh"

  // ---------------- 内存 ----------------
  reg [7:0]         img_mem   [0:CNN_IMG_H*CNN_IMG_W-1];          // 784
  reg [7:0]         w1_mem    [0:CNN_F*CNN_KH*CNN_KW-1];          // 72
  reg [7:0]         w3_mem    [0:CNN_HIDDEN*CNN_OUT-1];           // 320
  reg signed [31:0] b1_mem    [0:CNN_F-1];
  reg signed [31:0] b2_mem    [0:CNN_HIDDEN-1];
  reg signed [31:0] b3_mem    [0:CNN_OUT-1];
  reg [7:0]         conv_mem  [0:CNN_F*CNN_CONV_OH*CNN_CONV_OW-1]; // 5408
  reg [7:0]         pool_mem  [0:CNN_F*CNN_POOL_H*CNN_POOL_W-1];   // 1352
  reg [7:0]         hidden_mem[0:CNN_HIDDEN-1];
  reg signed [31:0] logit_mem [0:CNN_OUT-1];

  // w2(43264x8b)是唯一大权重表:组合读会被推断为分布式 LUT ROM 放不下,
  // 故仿真走通用数组、综合走显式 PH1P_LOGIC_ERAM 块 RAM(cnn_w2_rom, 见下文)。
`ifdef SIM
  reg [7:0]         w2_mem    [0:CNN_FC1_IN*CNN_HIDDEN-1];        // 43264
`endif

  initial begin
    $readmemh("weights/w1.mem", w1_mem);
`ifdef SIM
    $readmemh("weights/w2.mem", w2_mem);
`endif
    $readmemh("weights/w3.mem", w3_mem);
    $readmemh("weights/b1.mem", b1_mem);
    $readmemh("weights/b2.mem", b2_mem);
    $readmemh("weights/b3.mem", b3_mem);
  end

  // 输入图写口(推理前由测试台写入)
  always @(posedge I_clk) begin
    if (I_img_wr_en) img_mem[I_img_wr_addr] <= I_img_wr_data;
  end

  // ---------------- 状态机 ----------------
  localparam ST_IDLE   = 3'd0;
  localparam ST_CONV   = 3'd1;
  localparam ST_POOL   = 3'd2;
  localparam ST_FC1    = 3'd3;
  localparam ST_FC2    = 3'd4;
  localparam ST_ARGMAX = 3'd5;
  localparam ST_DONE   = 3'd6;

  // 每层步数: 偏置装载 + 各 tap + 锁存
  localparam CONV_STEPS = CNN_KH*CNN_KW + 3;   // 12
  localparam FC1_STEPS  = CNN_FC1_IN + 3;      // 1355
  localparam FC2_STEPS  = CNN_HIDDEN + 3;      // 35

  reg [2:0]  state;
  reg [10:0] c_step;        // 当前层内步进
  reg [2:0]  c_f;           // 卷积滤波器 0..F-1
  reg [4:0]  c_oh, c_ow;    // 卷积输出 0..25
  reg [3:0]  c_ph, c_pw;    // 池化输出 0..12
  reg [5:0]  c_j;           // FC1 输出 0..HIDDEN-1
  reg [3:0]  c_k;           // FC2 输出 0..OUT-1
  reg [3:0]  c_am;          // argmax 0..9
  reg signed [31:0] max_val;
  reg [3:0]  max_idx;

  // ---------------- 组合操作数译码 ----------------
  // tap/索引 = c_step-1,仅在 MAC 周期有效,否则钳 0 以免越界读
  wire S_en_conv = (state==ST_CONV) && (c_step>=1) && (c_step<=CNN_KH*CNN_KW);
  wire S_en_fc1  = (state==ST_FC1 ) && (c_step>=1) && (c_step<=CNN_FC1_IN);
  wire S_en_fc2  = (state==ST_FC2 ) && (c_step>=1) && (c_step<=CNN_HIDDEN);

  wire [3:0]  S_tap = S_en_conv ? (c_step[3:0] - 4'd1) : 4'd0;
  wire [1:0]  S_kh  = S_tap / 3;
  wire [1:0]  S_kw  = S_tap % 3;

  wire [6:0]  S_w1_addr  = c_f*9 + S_tap;
  // S_img_addr = (c_oh+S_kh)*28 + (c_ow+S_kw)。28 写成移位加(<<5 减 <<2),**不要写成乘法**:
  // 常量乘法会被 TD 映射成 DSP,而 DSP 只能落在固定的 DSP 列(实测 x027),这条路径就得专程
  // 跑去 DSP 列再跑回来 —— 实测单程线延 ~0.8ns、整个 DSP 段 3.77ns,是 100MHz 域最差路径的
  // 主因(改动前的原文件备份在 a/cnn_top.v.pre_shift_fix.bak)。
  wire [4:0]  S_row = c_oh + S_kh;                                       // 0..27
  wire [4:0]  S_col = c_ow + S_kw;                                       // 0..27
  wire [9:0]  S_img_addr = ({S_row, 5'b0} - ({5'b0, S_row} << 2)) + {5'b0, S_col};

  wire [10:0] S_i        = S_en_fc1 ? (c_step[10:0] - 11'd1) : 11'd0;
  wire [15:0] S_w2_addr  = S_i*CNN_HIDDEN + c_j;

  wire [5:0]  S_j        = S_en_fc2 ? (c_step[5:0] - 6'd1) : 6'd0;
  wire [8:0]  S_w3_addr  = S_j*CNN_OUT + c_k;

  wire signed [7:0] S_mac_w13 = (state==ST_CONV) ? w1_mem[S_w1_addr] : w3_mem[S_w3_addr];

  // w2 读:统一为“1 周期读”语义(与 PH1P_LOGIC_ERAM NOREG 读一致)。
  //   SIM   : 通用数组 + 地址寄存器(地址延迟 1 拍后组合读)
  //   SYNTH : cnn_w2_rom(显式 ERAM,NOREG 已 1 周期)
`ifdef SIM
  reg [15:0] S_w2_addr_d;
  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) S_w2_addr_d <= 16'd0;
    else          S_w2_addr_d <= S_w2_addr;
  end
  wire signed [7:0] S_w2_q = w2_mem[S_w2_addr_d];
`else
  wire signed [7:0] S_w2_q;
  cnn_w2_rom u_w2_rom (
    .I_clk(I_clk),
    .I_addr(S_w2_addr),
    .O_data(S_w2_q)
  );
`endif
  wire signed [7:0] S_mac_a = (state==ST_CONV) ? (img_mem[S_img_addr] >> 1) :
                              (state==ST_FC1 ) ? pool_mem[S_i] : hidden_mem[S_j];
  wire signed [31:0] S_bias = (state==ST_CONV) ? b1_mem[c_f] :
                              (state==ST_FC1 ) ? b2_mem[c_j] : b3_mem[c_k];

  wire S_load_bias = (state==ST_CONV && c_step==0) ||
                     (state==ST_FC1  && c_step==0) ||
                     (state==ST_FC2  && c_step==0);
  wire S_mac_en    = S_en_conv || S_en_fc1 || S_en_fc2;

  // ---------------- 1 级流水:寄存内存读数据与控制,使读变同步(可推断 BRAM) ----------------
  reg signed [7:0]  S_mac_w_d;   // w1/w3 组合读寄存
  reg signed [7:0]  S_mac_a_d;
  reg signed [31:0] S_bias_d;
  reg               S_load_bias_d;
  reg               S_mac_en_d;
  reg [2:0]         S_state_d;   // 延迟状态,用于选择 w2 与 w1/w3 操作数
  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      S_mac_w_d     <= 8'sd0;
      S_mac_a_d     <= 8'sd0;
      S_bias_d      <= 32'sd0;
      S_load_bias_d <= 1'b0;
      S_mac_en_d    <= 1'b0;
      S_state_d     <= ST_IDLE;
    end else begin
      S_mac_w_d     <= S_mac_w13;
      S_mac_a_d     <= S_mac_a;
      S_bias_d      <= S_bias;
      S_load_bias_d <= S_load_bias;
      S_mac_en_d    <= S_mac_en;
      S_state_d     <= state;
    end
  end

  // MAC 权重操作数:FC1 走 w2(1 周期读),CONV/FC2 走 w1/w3(组合读 + 1 周期寄存),
  // 用 S_state_d 对齐(二者都对应 1 拍前的状态/操作数)。
  wire signed [7:0] S_mac_w_op = (S_state_d==ST_FC1) ? S_w2_q : S_mac_w_d;

  // ---------------- MAC ----------------
  wire signed [31:0] S_acc;
  cnn_mac u_mac (
    .I_clk(I_clk), .I_rst_n(I_rst_n),
    .I_clear(1'b0), .I_load_bias(S_load_bias_d), .I_en(S_mac_en_d),
    .I_w(S_mac_w_op), .I_a(S_mac_a_d), .I_bias(S_bias_d),
    .O_acc(S_acc)
  );

  // ---------------- 重新量化: ReLU + 加半 + 算术右移 + 饱和到 int8 ----------------
  function [7:0] f_requant;
    input signed [31:0] acc;
    input [4:0] sh;
    reg signed [31:0] r, s;
    begin
      if (acc <= 0) f_requant = 8'd0;
      else begin
        r = (sh == 0) ? acc : (acc + (32'sd1 << (sh - 1)));
        s = r >>> sh;
        f_requant = (s > 32'sd127) ? 8'd127 : s[7:0];
      end
    end
  endfunction

  // 2x2 最大值池化:对 4 个已寄存的读值取 max。
  // 池化拆两拍(见 ST_POOL):第 0 拍寄存 conv_mem 读地址,第 1 拍组合读 + 本函数取 max,
  // 避免 conv_mem(5408x8 分布式 RAM,地址大扇出)组合读 + 地址计算 + max 全挤一拍。
  function [7:0] f_pool_max4;
    input [7:0] a, b, c, d;
    reg [7:0] m;
    begin
      m = a;
      if (b > m) m = b;
      if (c > m) m = c;
      if (d > m) m = d;
      f_pool_max4 = m;
    end
  endfunction

  // 池化读地址(组合,第 0 拍寄存)与 4 个读值(组合,第 1 拍取 max)。
  wire [12:0] S_pool_base = c_f*676 + (c_ph*2)*26 + (c_pw*2);
  reg  [12:0] S_pool_base_r;
  wire [7:0]  S_pool_r0 = conv_mem[S_pool_base_r];
  wire [7:0]  S_pool_r1 = conv_mem[S_pool_base_r + 13'd1];
  wire [7:0]  S_pool_r2 = conv_mem[S_pool_base_r + 13'd26];
  wire [7:0]  S_pool_r3 = conv_mem[S_pool_base_r + 13'd27];

  // ---------------- 主状态机 ----------------
  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      state <= ST_IDLE;
      c_step <= 0; c_f <= 0; c_oh <= 0; c_ow <= 0;
      c_ph <= 0; c_pw <= 0; c_j <= 0; c_k <= 0; c_am <= 0;
      O_done <= 0; O_class <= 0;
      max_val <= 32'h80000000; max_idx <= 0;
    end
    else begin
      O_done <= 0;   // 默认拉低,只在 ST_DONE 拉高一拍
      case (state)

        ST_IDLE: begin
          if (I_start) begin
            state <= ST_CONV; c_step <= 0; c_f <= 0; c_oh <= 0; c_ow <= 0;
          end
        end

        ST_CONV: begin
          if (c_step == CONV_STEPS-1) begin   // 锁存结果
            conv_mem[c_f*CNN_CONV_OH*CNN_CONV_OW + c_oh*CNN_CONV_OW + c_ow] <= f_requant(S_acc, CNN_S1);
            c_step <= 0;
            if (c_ow == CNN_CONV_OW-1) begin
              c_ow <= 0;
              if (c_oh == CNN_CONV_OH-1) begin
                c_oh <= 0;
                if (c_f == CNN_F-1) begin
                  c_f <= 0; state <= ST_POOL; c_ph <= 0; c_pw <= 0;
                end else c_f <= c_f + 1;
              end else c_oh <= c_oh + 1;
            end else c_ow <= c_ow + 1;
          end else begin
            c_step <= c_step + 1;
          end
        end

        ST_POOL: begin
          if (c_step == 0) begin   // 第 0 拍:寄存 conv_mem 读地址(拆掉长组合读)
            S_pool_base_r <= S_pool_base;
            c_step <= 1;
          end else begin           // 第 1 拍:取 2x2 max 写 pool_mem,推进坐标
            pool_mem[c_f*CNN_POOL_H*CNN_POOL_W + c_ph*CNN_POOL_W + c_pw] <= f_pool_max4(S_pool_r0, S_pool_r1, S_pool_r2, S_pool_r3);
            c_step <= 0;
            if (c_pw == CNN_POOL_W-1) begin
              c_pw <= 0;
              if (c_ph == CNN_POOL_H-1) begin
                c_ph <= 0;
                if (c_f == CNN_F-1) begin
                  c_f <= 0; state <= ST_FC1; c_step <= 0; c_j <= 0;
                end else c_f <= c_f + 1;
              end else c_ph <= c_ph + 1;
            end else c_pw <= c_pw + 1;
          end
        end

        ST_FC1: begin
          if (c_step == FC1_STEPS-1) begin
            hidden_mem[c_j] <= f_requant(S_acc, CNN_S2);
            c_step <= 0;
            if (c_j == CNN_HIDDEN-1) begin
              c_j <= 0; state <= ST_FC2; c_step <= 0; c_k <= 0;
            end else c_j <= c_j + 1;
          end else begin
            c_step <= c_step + 1;
          end
        end

        ST_FC2: begin
          if (c_step == FC2_STEPS-1) begin
            logit_mem[c_k] <= S_acc;   // int32 logit,不重新量化
            c_step <= 0;
            if (c_k == CNN_OUT-1) begin
              c_k <= 0; state <= ST_ARGMAX; c_am <= 0;
              max_val <= 32'h80000000; max_idx <= 0;
            end else c_k <= c_k + 1;
          end else begin
            c_step <= c_step + 1;
          end
        end

        ST_ARGMAX: begin
          if (logit_mem[c_am] > max_val) begin
            max_val <= logit_mem[c_am];
            max_idx <= c_am;
          end
          if (c_am == CNN_OUT-1) begin
            c_am <= 0; state <= ST_DONE;
          end else c_am <= c_am + 1;
        end

        ST_DONE: begin
          O_class <= max_idx;
          O_done <= 1;
          state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

  // ---------------- 输出 logits ----------------
  genvar g;
  generate
    for (g = 0; g < CNN_OUT; g = g + 1) begin : gen_logits
      assign O_logits[g*32 +: 32] = logit_mem[g];
    end
  endgenerate

endmodule
