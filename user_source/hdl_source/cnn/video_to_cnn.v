// video_to_cnn.v — 摄像头画面 → 28x28 灰度降采样 → 喂 CNN 推理核
//
// 双时钟域:
//   I_clk_pix (75MHz, HDMI 像素域): 从实时视频流累积 28x28 灰度 bin,
//       每 16 行 flush 一整列(28 个 bin)写入双口 BRAM 的 A 口(75MHz 写)。
//   I_clk_cnn (100MHz, CNN 域): 检测新帧就绪,从 B 口(100MHz 读)读回,
//       写 img_mem,拉 I_start。
//
// 取像素点: u_video_out 之后、u_hdmi_mixer 之前的 RGB888 逐像素流
//   (post-ISP、pre-OSD,不会被显示的 class 数字污染造成反馈)。
// 采样区: 中央方形 448x448,每 16x16 像素合成 1 个灰度 bin(28x28)。
// 灰度: G 通道(I_video_data[15:8])。
//
// bin 预处理(顺序: 灰度均值 -> 极性 -> 按量程中点二值化)——
//   这两步是"能不能认出数字"的关键,缺一不可:
//     · INVERT=1: 摄像头拍白纸黑字时纸亮墨暗,与 MNIST(黑底白字)相反,不反色就是喂负片。
//     · 中点阈值: 用**上一帧**整帧的 min/max 算出量程 rng = hi-lo,
//                判据 (p - lo) > rng/2 —— 阈值取量程中点。
//   为什么是"中点"而不是"固定阈值 T":
//     一开始的设计是"把量程拉伸到满幅再和常量 T 比",但移位拉伸的顶端
//     不饱和到 255(rng=150 时只到 150,rng=210 时到 210),于是同一个 T
//     在不同光照下代表的位置完全不同 —— 固定 T 等于把阈值绑死在一种光照上。
//     离线扫描(a/hw_preproc_study.py 实验 E/F)证实:T 从 64 到 160
//     在理想取景下准确率从 0.977 掉到 0.137;而"中点"在 10 个条件里 6 个最优、
//     平均与最好的固定 T 持平,且**恰好赢在量程偏离标定值的那些场景**。
//     硬件上还更省:不需要移位器,不需要饱和到 255。
//   代价只是几十个寄存器 + 一个比较器,不需要两遍扫描、不需要额外存储。
//   离线验证见 a/hw_preproc_study.py(现状 0.080 -> 修复后 0.98,接近 MNIST 原图基线 0.993)。
//
// 跨时钟存储:显式例化 PH1P_LOGIC_ERAM(MODE=DP, CLKMODE=ASYNC),
//   把 784x8 输出缓冲放在真双口 BRAM 里。若改用可推断数组,TD 无法推断
//   双时钟 RAM,会退回寄存器堆(784:1 读 mux),吃掉 ~5500 FF + ~4700 LUT,
//   既挤垮布局又形成跨时钟组合路径。
//   读侧 NOREG = 1 拍延迟(地址当拍驱动、下一拍 dob 有效);
//   写侧的 addr/en 各多寄存一级与 data 对齐(见 100MHz 域注释,踩过整幅错位 1 字节的坑)。
//
// 累加结构:每列一个 16bit 累加寄存器 col_sum[0:27](只有 28 个,推断成寄存器
//   或无歧义的小分布式 RAM 均安全),每像素 col_sum[bx] += gray;
//   走完 16 行(ly[3:0]==15 且行结束)时在行消隐期把该列 28 个 bin >>8
//   写入 ERAM A 口并清零。
`timescale 1ns/1ps
module video_to_cnn #(
    // 1 = 反色(255-gray)。**必须为 1**:摄像头对着白纸黑字时,纸亮(高值)、墨暗(低值),
    // 而 MNIST 是黑底白字;不反色进 CNN 的就是一张负片,永远认不对。
    parameter INVERT    = 1,
    parameter IMG_W     = 1280,
    parameter IMG_H     = 720,
    parameter ROI_SZ    = 448,   // 中央方形 ROI 边长
    parameter GRID      = 28,    // 输出 28x28
    parameter CELL_LOG2 = 4,     // log2(ROI_SZ/GRID) = log2(16)
    // 二值化阈值 = 上一帧量程 rng 右移 TH_SHIFT 位。
    //   TH_SHIFT=1 => rng/2,即量程中点(默认,离线扫描最优)。
    //   调参方向:加大 TH_SHIFT => 阈值降低 => 更多像素判为笔画(笔画变粗/更容易糊);
    //             减小则相反。TH_SHIFT=0 会变成"off > rng",永不成立,别用。
    parameter TH_SHIFT  = 1,
    // 整帧 lo/hi 之差小于此值 => 画面太平(对着白墙),整幅输出 0,避免把噪声二值化成雪花。
    parameter MIN_RANGE = 24
)(
    // ---- 像素域 (75MHz) ----
    input  wire        I_clk_pix,
    input  wire        I_rst_pix_n,
    input  wire        I_video_de,       // 有效像素
    input  wire        I_video_user,     // 帧起始脉冲
    input  wire        I_video_last,     // 行结束脉冲
    input  wire [23:0] I_video_data,     // RGB888: [23:16]=R [15:8]=G [7:0]=B
    // ---- CNN 域 (100MHz) ----
    input  wire        I_clk_cnn,
    input  wire        I_rst_cnn_n,
    input  wire        I_cnn_done,
    // ---- CNN 输入 (100MHz 域) ----
    output reg         O_img_wr_en,
    output reg  [9:0]  O_img_wr_addr,
    output reg  [7:0]  O_img_wr_data,
    output reg         O_start,
    // ---- 屏幕预览:把**最终写进 CNN 的那一份字节**同步输出给显示通路 ----
    // 三个信号一起延迟 1 拍,接收侧(HDMI mixer 里的预览缓冲)按同一拍写入,互相仍然对齐。
    output reg         O_prev_we,
    output reg  [9:0]  O_prev_addr,
    output reg  [7:0]  O_prev_data
);

    localparam BIN_N  = GRID * GRID;          // 784
    localparam ROI_X0 = (IMG_W - ROI_SZ) / 2; // 416
    localparam ROI_Y0 = (IMG_H - ROI_SZ) / 2; // 136

    // ================= 75MHz 域:累加 + flush 写 =================
    reg [11:0] S_x, S_y;
    reg [15:0] col_sum [0:GRID-1];   // 28 个列累加器(每 bin 256 像素,sum<=65280)
    reg        S_flushing;
    reg [4:0]  S_flush_cnt;          // 0..27
    reg [4:0]  S_flush_by;           // 0..27
    reg        S_frame_toggle;
    integer    ci;

    // ---- 整帧灰度统计(极性之后的最小/最大),给**下一帧**定二值化阈值 ----
    // 用上一帧而不是本帧,是为了避免"要先扫完一遍才知道该怎么归一化"的两遍扫描:
    // 帧末锁存一次即可,零额外存储。60fps 下滞后 16ms,肉眼不可见。
    reg [7:0]  S_stat_min, S_stat_max;   // 本帧运行中的 min/max
    reg [7:0]  S_prev_lo,  S_prev_hi;    // 上一帧锁存值,flush 时用来定阈值

    // ================= bin 预处理:极性 -> 按量程中点二值化 =================
    // 与 a/hw_preproc_study.py 的 pp_mid() 一致(该脚本已在 MNIST 上验证过效果)。
    // 为什么必须做:
    //   1) 极性:摄像头拍"白纸黑字"时纸亮墨暗,与 MNIST 的黑底白字相反。
    //      注意反色在**累加之前**就做了(见 S_gray),这里拿到的是已经统一成
    //      "笔画=高值"的 16x16 均值。(先反色再平均 与 先平均再反色 最多差 1 LSB,
    //      但边界 bin 会被阈值翻转,所以顺序必须和 RTL 一致 ——
    //      a/check_v2c_frame.py 的参考模型就是按这个顺序写的。)
    //   2) 二值化:MNIST 输入近似二值(测试图 #0 的 784 字节里 668 个是 0x00)。
    //      阈值取上一帧量程的中点。上一帧而不是本帧,是为了避免"先扫一遍才知道
    //      该怎么归一化"的两遍扫描;60fps 下滞后 16ms,肉眼不可见。
    //
    // 位置注意:这段**必须**在下面的 flush 状态机之前 —— 它用到 S_min_nxt/
    // S_max_nxt/S_frame_end,而 Verilog 要求先声明后使用(放到文件末尾会编译不过)。
    // 注意:极性已经在 S_gray 里**逐像素**反过了(累加之前),这里**不能再反一次** ——
    // 这里若再写一遍 `INVERT ? 255-b : b` 就是双重反色,净效果等于没反,
    // 结果是"纸"被判成笔画、整幅变成负片(踩过:输出恰好是参考模型的补集)。
    wire [7:0]  S_bin_raw   = col_sum[S_flush_cnt] >> 8;                 // 256 像素和 >>8 = 均值
    wire [7:0]  S_bin_pol   = S_bin_raw;                                 // 已是"笔画=高值"
    wire [8:0]  S_prev_rng  = {1'b0, S_prev_hi} - {1'b0, S_prev_lo};
    wire        S_prev_flat = (S_prev_rng < MIN_RANGE);                  // 画面太平 => 整幅输出 0
    wire [7:0]  S_bin_th    = S_prev_rng[7:0] >> TH_SHIFT;               // 量程中点(rng >= 24 时非零)
    // 注意必须有下面这个下界钳位:上一帧的 lo 可能高于本帧的某个值。
    // 若直接做无符号减法会回绕成一个很大的数,被当成"笔画",这是最容易踩的坑。
    wire [8:0]  S_bin_off   = (S_bin_pol > S_prev_lo)
                            ? ({1'b0, S_bin_pol} - {1'b0, S_prev_lo}) : 9'd0;
    wire [7:0]  S_bin_out   = S_prev_flat ? 8'd0
                            : ((S_bin_off > {1'b0, S_bin_th}) ? 8'd255 : 8'd0);

    // 帧末 = 最后一个行块的最后一个 bin;此刻锁存统计量给下一帧
    wire [7:0]  S_min_nxt   = (S_bin_pol < S_stat_min) ? S_bin_pol : S_stat_min;
    wire [7:0]  S_max_nxt   = (S_bin_pol > S_stat_max) ? S_bin_pol : S_stat_max;
    wire        S_frame_end = S_flushing && (S_flush_cnt == GRID-1) && (S_flush_by == GRID-1);

    // x/y 坐标计数器:x 在 de 自增并回绕,y 在 last 自增,user 清零。
    always @(posedge I_clk_pix or negedge I_rst_pix_n) begin
        if (!I_rst_pix_n) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end else if (I_video_user) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end else begin
            if (I_video_de) begin
                if (S_x == IMG_W-1) S_x <= 12'd0;
                else                S_x <= S_x + 12'd1;
            end
            if (I_video_last) begin
                S_y <= S_y + 12'd1;
            end
        end
    end

    // ROI 命中 + bin 译码(组合)
    wire        S_in_roi   = (S_x >= ROI_X0) && (S_x < ROI_X0 + ROI_SZ) &&
                             (S_y >= ROI_Y0) && (S_y < ROI_Y0 + ROI_SZ);
    wire [11:0] S_lx       = S_x - ROI_X0;
    wire [11:0] S_ly       = S_y - ROI_Y0;
    wire [4:0]  S_bx       = S_lx >> CELL_LOG2;   // 0..27
    wire [4:0]  S_by       = S_ly >> CELL_LOG2;   // 0..27
    wire        S_row_last = (S_ly[3:0] == 4'hF);  // 本 by-row 的最后一行
    // 只管 y 的 ROI 判据,给 flush 触发用:**不能**用 S_in_roi。
    //   行末那一拍 S_x 已经是 1279(板级 de&&last 同拍生效,见 uivtc.v:128:
    //   O_vtc_de_valid = de 延迟 2,vtc_last_r2 也对齐到同一条延迟后的流),
    //   所以含 x 的 S_in_roi 在行末必然为假 —— flush 会一次都不触发(踩过)。
    //   S_row_last 本身只看 S_ly[3:0],配合 S_in_roi_y 就排除了 ROI 上下方的回绕。
    wire        S_in_roi_y = (S_y >= ROI_Y0) && (S_y < ROI_Y0 + ROI_SZ);
    wire [7:0]  S_gray     = INVERT ? (8'hFF - I_video_data[15:8]) : I_video_data[15:8];

    // 列累加 + 每 16 行 flush 一整列(单写口 col_sum)
    always @(posedge I_clk_pix or negedge I_rst_pix_n) begin
        if (!I_rst_pix_n) begin
            S_flushing      <= 1'b0;
            S_flush_cnt     <= 5'd0;
            S_flush_by      <= 5'd0;
            S_frame_toggle  <= 1'b0;
            S_stat_min      <= 8'hFF;
            S_stat_max      <= 8'd0;
            // 首帧没有"上一帧":lo=0/hi=255 => 不拉伸,只做极性 + 固定阈值。
            // 第 2 帧起统计量就对了。
            S_prev_lo       <= 8'd0;
            S_prev_hi       <= 8'hFF;
            // 累加器必须显式清零:否则首帧第一个行块累加的是 X(仿真)/上电初值,
            // flush 出的 28 个 bin 全错。后续行块靠 flush 清零才“看起来正常”。
            for (ci = 0; ci < GRID; ci = ci + 1) col_sum[ci] <= 16'd0;
        end else if (S_flushing) begin
            col_sum[S_flush_cnt] <= 16'd0;
            // 整帧 min/max 增量统计;帧末(最后一个 band 的最后一个 bin)锁存给下一帧并复位
            S_stat_min <= S_frame_end ? 8'hFF : S_min_nxt;
            S_stat_max <= S_frame_end ? 8'd0   : S_max_nxt;
            if (S_frame_end) begin
                S_prev_lo <= S_min_nxt;
                S_prev_hi <= S_max_nxt;
            end
            if (S_flush_cnt == GRID-1) begin
                S_flushing <= 1'b0;
                if (S_flush_by == GRID-1) S_frame_toggle <= ~S_frame_toggle;
            end else begin
                S_flush_cnt <= S_flush_cnt + 5'd1;
            end
        end else begin
            if (I_video_de && S_in_roi) begin
                col_sum[S_bx] <= col_sum[S_bx] + {8'd0, S_gray};
            end
            // S_in_roi_y 是**必须**的,不是保险措施:
            //   S_ly = S_y - ROI_Y0 是 12 位无符号减法,ROI 之外会回绕成大数,
            //   而 S_ly[3:0]==15 照样会成立 —— 于是每帧在 ROI 上方(y=7,23,...,135)
            //   和下方(y=599,...,719)会各触发约 9 次**伪 flush**:用一个被截断到
            //   5 位的垃圾 S_by 当行号写入(覆盖正确数据),还把 col_sum 提前清零、
            //   把垃圾值并进 min/max 统计。
            //   旧 TB 用 448x448 帧(ROI 正好铺满整帧)时 S_ly 永不回绕,所以这个
            //   bug 一直测不出来,但上板时每帧都在破坏数据。
            //   抓到它的是 sim/video_to_cnn_frame_tb.v(真实 1280x720 + 逐字节比对)。
            if (I_video_last && S_in_roi_y && S_row_last) begin
                S_flushing  <= 1'b1;
                S_flush_cnt <= 5'd0;
                S_flush_by  <= S_by;
            end
        end
    end

    // (bin 预处理的组合逻辑见文件上半部分 —— 必须在 flush 状态机之前声明)

    // ================= 双口 BRAM:784x8,75MHz 写 / 100MHz 读 =================
    // ERAM 写口信号(75MHz 域)
    wire        S_cap_we    = S_flushing;
    wire [9:0]  S_cap_waddr = S_flush_by * GRID + S_flush_cnt;   // 0..783
    wire [7:0]  S_cap_wdata = S_bin_out;                         // 预处理后的字节(喂 CNN)

    // 屏幕预览:把这一份字节同步送给显示通路(HDMI mixer 里的预览缓冲按同一拍写)
    always @(posedge I_clk_pix or negedge I_rst_pix_n) begin
        if (!I_rst_pix_n) begin
            O_prev_we   <= 1'b0;
            O_prev_addr <= 10'd0;
            O_prev_data <= 8'd0;
        end else begin
            O_prev_we   <= S_cap_we;
            O_prev_addr <= S_cap_waddr;
            O_prev_data <= S_cap_wdata;
        end
    end

    // ERAM 读口信号(100MHz 域)
    reg  [9:0]  f_addr;
    wire [7:0]  S_cap_dout;

    PH1P_LOGIC_ERAM #(
        .DATA_WIDTH_A(8),  .DATA_WIDTH_B(8),
        .ADDR_WIDTH_A(10), .ADDR_WIDTH_B(10),
        .DATA_DEPTH_A(1024), .DATA_DEPTH_B(1024),
        .BYTE_ENABLE(0),   .BYTE_A(1), .BYTE_B(1),
        .MODE("DP"),
        .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE_A("ASYNC"), .RESETMODE_B("ASYNC"),
        .OREGSET_A("RESET"), .OREGSET_B("RESET"),
        .SSROVERCE("DISABLE"),
        .ECC_DECODE("DISABLE"), .ECC_ENCODE("DISABLE"),
        .ASYNC_RESET_RELEASE_A("ASYNC"), .ASYNC_RESET_RELEASE_B("ASYNC"),
        .CLKMODE("ASYNC"),
        .DEBUGGABLE("NO"), .PACKABLE("NO"), .FORCE_KEEP("OFF"),
        .INIT_FILE("NONE"), .FILL_ALL("NONE"),
        .IMPLEMENT("20K(FAST)")
    ) u_cap_ram (
        .dia(S_cap_wdata), .dib(8'd0),
        .addra(S_cap_waddr), .addrb(f_addr),
        .cea(S_cap_we), .ceb(1'b1),
        .ocea(1'b0), .oceb(1'b0),
        .clka(I_clk_pix), .clkb(I_clk_cnn),
        .wea(1'b1), .web(1'b0),
        .bea(1'b0), .beb(1'b0),
        .rsta(1'b0), .rstb(1'b0),
        .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0),
        .doa(), .dob(S_cap_dout),
        .ecc_sbiterr(), .ecc_dbiterr()
    );

    // ================= 100MHz 域:读回 + 喂 CNN =================
    reg S_toggle_s1, S_toggle_s2, S_toggle_s3;
    wire S_frame_ready = S_toggle_s2 ^ S_toggle_s3;

    localparam F_IDLE  = 3'd0;
    localparam F_WRITE = 3'd1;
    localparam F_DRAIN = 3'd2;   // 等写流水线排空,避免 O_start 与最后 1 次写同拍
    localparam F_START = 3'd3;
    localparam F_WAIT  = 3'd4;

    reg [2:0] f_state;
    reg [9:0] f_cnt;
    reg [9:0] f_a1;      // f_addr 延迟 1 拍
    reg       f_dv;      // 读流水线有效(F_WRITE 延迟 1 拍)
    reg [1:0] f_drain;

    // 三条流的延迟对齐(以「第 X 拍」为准,A(X) 记 f_addr 的值):
    //   ERAM 读延迟 1 拍 → S_cap_dout(X) = cap_ram[A(X-1)]
    //   O_img_wr_data 再寄存 1 拍 → data(X) = cap_ram[A(X-2)]
    //   O_img_wr_addr = f_a1 再寄存   → addr(X) = A(X-2)      ← 与 data 对齐
    //   O_img_wr_en   = f_dv  再寄存   → en(X) = (f_state(X-2)==F_WRITE)
    // 三者条件完全相同,故每次写都命中正确的 (addr, data) 对。
    //   (曾经的 bug:addr 用 f_cnt 直接寄存,只延迟 1 拍,比 data 早 1 拍
    //    → 整幅图错位一个字节;上板只表现为识别错乱,极难察觉。)
    always @(posedge I_clk_cnn or negedge I_rst_cnn_n) begin
        if (!I_rst_cnn_n) begin
            S_toggle_s1 <= 1'b0;
            S_toggle_s2 <= 1'b0;
            S_toggle_s3 <= 1'b0;
            f_state     <= F_IDLE;
            f_cnt       <= 10'd0;
            f_addr      <= 10'd0;
            f_a1        <= 10'd0;
            f_dv        <= 1'b0;
            f_drain     <= 2'd0;
            O_img_wr_en   <= 1'b0;
            O_img_wr_addr <= 10'd0;
            O_img_wr_data <= 8'd0;
            O_start       <= 1'b0;
        end else begin
            // toggle 2-FF 同步(慢变电平)
            S_toggle_s1 <= S_frame_toggle;
            S_toggle_s2 <= S_toggle_s1;
            S_toggle_s3 <= S_toggle_s2;

            // ERAM 读/写流水线(每拍无条件推进)
            f_a1          <= f_addr;
            f_dv          <= (f_state == F_WRITE);
            O_img_wr_en   <= f_dv;
            O_img_wr_addr <= f_a1;
            O_img_wr_data <= S_cap_dout;

            O_start <= 1'b0;   // 默认拉低

            case (f_state)
                F_IDLE: begin
                    f_addr <= 10'd0;
                    if (S_frame_ready) begin
                        f_state <= F_WRITE;
                        f_cnt   <= 10'd0;
                    end
                end
                F_WRITE: begin
                    if (f_cnt == BIN_N-1) begin
                        f_state <= F_DRAIN;
                        f_drain <= 2'd0;
                    end else begin
                        f_cnt  <= f_cnt + 10'd1;
                        f_addr <= f_addr + 10'd1;
                    end
                end
                F_DRAIN: begin
                    if (f_drain == 2'd2) f_state <= F_START;
                    else                 f_drain <= f_drain + 2'd1;
                end
                F_START: begin
                    O_start <= 1'b1;
                    f_state <= F_WAIT;
                end
                F_WAIT: begin
                    if (I_cnn_done) f_state <= F_IDLE;
                end
                default: f_state <= F_IDLE;
            endcase
        end
    end

endmodule
