// cnn_stimulus.v — 综合用自激激励:反复写入 784 字节测试图并启动 CNN 推理,
// 使 cnn_top 在综合时处于“被使用”状态,数据通路不被 optimize_gate 裁剪。
// 仅供上板/综合验证;仿真时仍由 cnn_tb.v 直接驱动 cnn_top。
`timescale 1ns/1ps
module cnn_stimulus (
  input  wire        I_clk,
  input  wire        I_rst_n,
  input  wire        I_cnn_done,
  output reg         O_img_wr_en,
  output reg  [9:0]  O_img_wr_addr,
  output reg  [7:0]  O_img_wr_data,
  output reg         O_start
);

  localparam ST_WRITE = 2'd0;
  localparam ST_START = 2'd1;
  localparam ST_WAIT  = 2'd2;

  reg [1:0] state;
  reg [9:0] addr;

  // 固定测试图(MNIST 测试图 #0,label=7),784 字节;替换原斜坡,便于上板比对期望 class。
  reg [7:0] S_img [0:783];
  initial $readmemh("weights/test_img.mem", S_img);

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
      state         <= ST_WRITE;
      addr          <= 10'd0;
      O_img_wr_en   <= 1'b0;
      O_img_wr_addr <= 10'd0;
      O_img_wr_data <= 8'd0;
      O_start       <= 1'b0;
    end else begin
      O_start <= 1'b0;   // 默认拉低,只在 ST_START 拉高一拍
      case (state)
        ST_WRITE: begin
          O_img_wr_en   <= 1'b1;
          O_img_wr_addr <= addr;
          O_img_wr_data <= S_img[addr];   // 固定测试图(数字 7)
          if (addr == 10'd783) begin
            addr  <= 10'd0;
            state <= ST_START;
          end else begin
            addr <= addr + 10'd1;
          end
        end
        ST_START: begin
          O_img_wr_en <= 1'b0;
          O_start     <= 1'b1;
          state       <= ST_WAIT;
        end
        ST_WAIT: begin
          O_img_wr_en <= 1'b0;
          if (I_cnn_done) begin
            addr  <= 10'd0;
            state <= ST_WRITE;
          end
        end
        default: state <= ST_WRITE;
      endcase
    end
  end

endmodule
