// roi_overlay.v — 在显示画面上画出 video_to_cnn 实际采样的那个 ROI 方框(双层)
//
// 为什么需要:
//   CNN 只吃中央固定的 448x448(video_to_cnn.v 的 ROI_X0/ROI_Y0/ROI_SZ),
//   而 MNIST 的数字笔画都归一化在约 20x20/28x28 内。数字**没占满**这个框时,
//   16x16 平均会把笔画糊平,离线扫描显示准确率会从 0.98 掉到 0.5 甚至 0.28。
//   所以上板时必须有个框告诉操作者"把数字放进这里、并且尽量填满"。
//
// 外层(绿,2px)= CNN 的采样区,**画错就是骗人** —— 位置由 a/check_roi_overlay.py
//   与 video_to_cnn.v 逐项机器校对。对不上时数字明明在框里却认不出。
// 内层(黄,1px)= MNIST 的**目标几何**。人眼判断不了"我占了百分之多少",
//   所以把 20/28 这个目标直接画出来:数字的**上下顶点**对到黄框即可(见下方 INNER_SZ 注释)。
//
// 关键约束:必须是**纯组合、零延迟**。
//   本模块插在 u_video_out → u_hdmi_mixer 之间(与 gamma_corr 同一个插入点)。
//   hdmi_mixer.v 的 `assign O_video_rd_en = I_video_de;` 用 de 反馈驱动 u_video_out
//   的 DDR 读,mixer 再把 I_video_de / I_video_rd_data 各延迟 3 拍对齐。
//   在这里插任何寄存器都会让数据相对 de 错开 1 拍 ⇒ 整屏错位。
//   它的时序路径是"计数器寄存器 -> 比较器 -> 颜色 mux -> mixer 输入寄存器",
//   与 OSD 那条关键路径(hdmi_mixer 内部,2026-10-11 实测 SWNS +1.477ns / Max-Level 14)完全无关。
//
// 计数器与 video_to_cnn.v 的 S_x/S_y **逐行相同**,所以框的位置就是 CNN 采样区的位置,
// 不是"看起来差不多"——这是诊断能成立的前提。
// 显示为 1280x720 且摄像头也是 1280x720,1:1 无缩放,坐标直接对应。
`timescale 1ns/1ps
module roi_overlay #(
    parameter IMG_W  = 1280,
    parameter IMG_H  = 720,
    // 必须与 video_to_cnn.v 的 localparam 一致(靠 a/check_roi_overlay.py 校对)
    parameter ROI_X0 = 416,          // (1280-448)/2
    parameter ROI_Y0 = 136,          // (720-448)/2
    parameter ROI_SZ = 448,
    parameter THICK  = 2,            // 外框粗细(像素)
    parameter [23:0] COLOR = 24'h00ff00,        // 外框:绿
    parameter INNER_THICK = 1,       // 内框粗细(像素) —— 比外框细,避免喧宾夺主
    parameter [23:0] COLOR_INNER = 24'hffff00,  // 内框:黄
    parameter ENABLE = 1             // 置 0 可整体关掉,便于 A/B
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_video_de,
    input  wire        I_video_user,
    input  wire        I_video_last,
    input  wire [23:0] I_data,
    output wire [23:0] O_data
);

    localparam X1 = ROI_X0 + ROI_SZ;     // 864
    localparam Y1 = ROI_Y0 + ROI_SZ;     // 584

    // ---- 内框:MNIST 的归一化几何,不是随手画的 ----
    // MNIST 把数字按**最长边**缩放到 20/28 并居中(= 四周各留 4 像素空白),见 LeCun 原文。
    // 本设计 ROI_SZ/GRID = 448/28 = 16 像素/格,所以"最长边占 20 格" == 20*16 = 320 像素。
    // 整数运算 ROI_SZ*20/28 恰好得 320,不需要浮点,也没有取整误差。
    // 用法:把数字的**上下顶点**对到黄框。因为按最长边归一化,
    //   **宽数字(0/8 这类)横向超出黄框是正常的**,别硬塞进去 —— 硬塞反而破坏比例。
    localparam INNER_SZ = ROI_SZ * 20 / 28;                     // 320
    localparam INNER_X0 = ROI_X0 + (ROI_SZ - INNER_SZ) / 2;     // 480
    localparam INNER_Y0 = ROI_Y0 + (ROI_SZ - INNER_SZ) / 2;     // 200
    localparam INNER_X1 = INNER_X0 + INNER_SZ;                  // 800
    localparam INNER_Y1 = INNER_Y0 + INNER_SZ;                  // 520

    reg [11:0] S_x, S_y;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end
        else if (I_video_user) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end
        else begin
            if (I_video_de) begin
                if (S_x == IMG_W-1) S_x <= 12'd0;
                else                S_x <= S_x + 12'd1;
            end
            if (I_video_last) begin
                S_y <= S_y + 12'd1;
            end
        end
    end

    wire S_in_x = (S_x >= ROI_X0) && (S_x < X1);
    wire S_in_y = (S_y >= ROI_Y0) && (S_y < Y1);
    // 只画边框,中间留空 —— 否则会把要识别的数字盖住
    wire S_on_border = (S_x < ROI_X0 + THICK) || (S_x >= X1 - THICK) ||
                       (S_y < ROI_Y0 + THICK) || (S_y >= Y1 - THICK);

    // 内框同构,只是更细更小。S_in_inner 那层门控不可省:
    // 少了它,S_x=0 这类远处坐标会满足 "S_x < INNER_X0+1" 而在左上角画出一条线。
    wire S_in_inner = (S_x >= INNER_X0) && (S_x < INNER_X1) &&
                      (S_y >= INNER_Y0) && (S_y < INNER_Y1);
    wire S_on_inner = (S_x < INNER_X0 + INNER_THICK) || (S_x >= INNER_X1 - INNER_THICK) ||
                      (S_y < INNER_Y0 + INNER_THICK) || (S_y >= INNER_Y1 - INNER_THICK);

    // 外框优先(内框严格在外框内部,两者本来就不重叠,这里只是把顺序写死)
    assign O_data = (ENABLE && I_video_de && S_in_x && S_in_y && S_on_border)
                    ? COLOR
                    : ((ENABLE && I_video_de && S_in_inner && S_on_inner)
                       ? COLOR_INNER : I_data);

endmodule
