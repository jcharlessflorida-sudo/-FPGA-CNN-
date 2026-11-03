module hdmi_mixer #(
    parameter H_OFFSET = 128,
    parameter V_OFFSET = 60,
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720,
    parameter integer DEBUG_MODE = 0,
    // 1 秒门控窗口的拍数(75.000MHz x 1s)。做成 parameter 便于仿真时调小快速验证;
    // 综合/上板一律用默认值。
    parameter integer FPS_GATE_MAX = 75000000
)(
    input wire        I_clk,
    input wire        I_rst_n,

    input wire        I_video_vsync,
    input wire        I_video_hsync,
    input wire        I_video_de,
    input wire        I_video_user,
    input wire        I_video_last,

    input wire[3:0]   I_debug_status,

    // FPS 计数用的两个脉冲,已由 design_top_wrapper 同步到本 I_clk(75MHz)域,
    // 每个都是单周期脉冲:cam = 摄像头帧起始,cnn = 一次推理完成。
    input wire        I_fps_cam_pulse,
    input wire        I_fps_cnn_pulse,

    // 28x28 预览缓冲写口:直接接 video_to_cnn 的 O_prev_we/addr/data(同为 75MHz 像素域)。
    // 写的是**最终喂进 CNN 的那一份字节**,所以屏幕上看到的就是 CNN 看到的。
    input wire        I_thumb_we,
    input wire[9:0]   I_thumb_addr,
    input wire[7:0]   I_thumb_data,

    output wire       O_video_rd_en,
    input wire[23:0]  I_video_rd_data,

    output reg        O_hdmi_vsync,
    output reg        O_hdmi_hsync,
    output reg        O_hdmi_de,
    output reg[23:0]  O_hdmi_data
);

    reg        S_video_vsync_1d;
    reg        S_video_vsync_2d;
    reg        S_video_hsync_1d;
    reg        S_video_hsync_2d;
    reg        S_video_de_1d;
    reg        S_video_de_2d;
    reg [23:0] S_video_data_1d;
    reg [23:0] S_video_data_2d;
    reg [11:0] S_x;
    reg [11:0] S_y;
    reg [11:0] S_x_1d;
    reg [11:0] S_x_2d;
    reg [11:0] S_y_1d;
    reg [11:0] S_y_2d;

    reg        S_osd_hit;
    reg [23:0] S_osd_color;
    reg [3:0]  S_char_idx;
    reg [2:0]  S_char_row;
    reg [2:0]  S_char_col;
    reg [4:0]  S_char_bits;
    reg        S_char_on;
    reg        S_logo_blue_on;
    reg        S_logo_red_on;
    reg [11:0] S_logo_tmp_y;
    reg [3:0]  S_logo_red_band;
    reg [11:0] S_logo_red_x_start;
    reg [11:0] S_logo_red_x_end;
    reg [12:0] S_logo_addr_r;
    wire[24:0] S_logo_pixel;
    reg [9:0]  S_thumb_addr_r;
    wire[7:0]  S_thumb_pixel;
    // 窗口命中位,已在 3d 级之前算好寄存。名字里的 w3 表示"在 S_x_3d/S_y_3d 那一级有效",
    // **不是因为打了三拍** —— 源是 2d 计数器,只需要一拍。
    reg        S_thumb_w3;
    reg        S_logo_w3;
    reg [11:0] S_x_3d;
    reg [11:0] S_y_3d;
    reg        S_video_vsync_3d;
    reg        S_video_hsync_3d;
    reg        S_video_de_3d;
    reg [23:0] S_video_data_3d;
    reg [31:0] S_frame_cnt;
    reg [11:0] S_dyn_x;
    reg [11:0] S_dyn_y;
    reg [3:0]  S_dyn_char;
    reg [2:0]  S_dyn_col;
    reg [2:0]  S_dyn_row;
    reg [4:0]  S_dyn_bits;
    reg        S_dyn_on;
    reg [3:0]  S_dyn_digit_idx;
    reg [11:0] S_dyn_digit_x;
    reg [6:0]  S_dyn_seg;
    reg [3:0]  S_cnt_d0;
    reg [3:0]  S_cnt_d1;
    reg [3:0]  S_cnt_d2;
    reg [3:0]  S_cnt_d3;
    reg [3:0]  S_cnt_d4;
    reg [3:0]  S_cnt_d5;
    reg [2:0]  S_lbl_row;
    reg [2:0]  S_lbl_col;
    reg [1:0]  S_lbl_idx;
    reg [4:0]  S_lbl_bits;
    reg [6:0]  S_lbl_local_x;
    reg [3:0]  S_dyn_dec_digit;
    reg [4:0]  S_cn_local_x;
    reg [4:0]  S_cn_local_y;
    reg [3:0]  S_cn_col;
    reg [3:0]  S_cn_row;
    reg [15:0] S_cn_row_bits;
    reg        S_cn_on;
    reg [9:0]  S_cn_scale_x;
    reg [9:0]  S_cn_scale_y;
    reg [7:0]  S_pf_char;
    reg [4:0]  S_pf_local_x;
    reg [4:0]  S_pf_local_y;
    reg [3:0]  S_pf_col;
    reg [3:0]  S_pf_row;
    wire [15:0] S_pf_row_bits;
    reg        S_pf_on;
    reg [9:0]  S_pf_scale_x;
    reg [9:0]  S_pf_scale_y;
    reg [3:0]  S_cls_sync1;
    reg [3:0]  S_cls_digit;
    reg [5:0]  S_cls_local_x;
    reg [5:0]  S_cls_local_y;

    // ---- FPS 计数/显示 ----
    reg [26:0] S_fps_gate_cnt;      // 1 秒门控计数器
    reg        S_fps_gate_tick;     // 门控到期单周期脉冲
    reg [6:0]  S_fps_cam_acc;       // 本窗口内摄像头帧数
    reg [6:0]  S_fps_cnn_acc;       // 本窗口内 CNN 完成次数
    reg [3:0]  S_fps_cam_d1;        // 摄像头速率 十位
    reg [3:0]  S_fps_cam_d0;        // 摄像头速率 个位
    reg [3:0]  S_fps_cnn_d1;        // CNN 速率 十位
    reg [3:0]  S_fps_cnn_d0;        // CNN 速率 个位
    reg        S_fps_w3;            // 窗口命中,3d 级有效(源为 2d 计数)
    reg        S_fps_on3;           // 字形笔画位,3d 级有效(2d 算好寄存一拍)
    reg [7:0]  S_fps_char_code;     // 2d 组合:字符编码
    reg [3:0]  S_fps_glyph_col;     // 2d 组合:字形列
    reg [3:0]  S_fps_glyph_row;     // 2d 组合:字形行
    reg        S_fps_on_2d;         // 2d 组合:笔画位(寄存后为 S_fps_on3)
    wire [15:0] S_fps_row_bits;     // FPS 专用字形 ROM 输出

    // ---- 屏幕布局(各窗口互不重叠)----
    //   预览 28x28  x 0..112      (左上角)
    //   logo        x 1120..1280  (右上角 = 1280-160)
    //   取景框      x 416..864 / y 136..584
    //   DYN 文本    x 375..575 / 类别数字 x 624..688
    // logo 的**显示窗口**仍是 160x160(x 1120..1280),位置/大小与原厂一致;
    // 但查表分辨率降到 80x80 且表存进 **块 RAM**(见 logo_rom_eram.v),读地址按 >>1 取,
    // 屏幕上就是 2x2 块状放大,而 fabric 里一个查找逻辑都不再占。
    //
    // 为什么最后选了 ERAM:原厂全分辨率 ROM 的 6387 条稀疏组合 case 占约 1918 slices,
    // 把利用率推到 82.79%,CNN 的 100MHz 域就从基准的 14 个违规端点涨到 136 个;
    // 2× 降采样(1769 条,约 700 slices)把违规端点降到 72、TNS 减半,但 **WNS 几乎没动**
    // (-0.558 → -0.577ns)—— 最差的那条路径整条都在 u_cnn_top 内部,logo 根本不在路径上,
    // 只能靠挤占落点坑它。据此判断:那条路径对 logo 的**面积不敏感,只对"在不在 fabric"敏感**,
    // 继续降采样没用 ⇒ 整体搬进 ERAM(8192×25bit,占器件空闲的 38 块 ERAM 里十几块)。
    // 该 ROM 的可见笔画落在窗口第 34..127 行,贴顶放仍完整可见。
    localparam LOGO_X = 12'd1120;
    localparam LOGO_Y = 12'd0;
    localparam LOGO_W = 12'd160;
    localparam LOGO_H = 12'd160;
    localparam LOGO_SRC_W = 12'd80;           // = LOGO_W/2,降采样后表的宽度

    // 28x28 预览窗口:左上角,在取景框之外,且与右上角的 logo 不打架。
    // 放大倍数取 4(纯移位 >>2)= 112x112,正好塞进 160x160 的 logo 窗口。
    // 原计划 5 倍(140x140)更满,但要除以 5,不值当;4 倍 112x112 已经一眼可辨。
    localparam THUMB_X      = 12'd0;
    localparam THUMB_Y      = 12'd0;
    localparam THUMB_W      = 12'd112;
    localparam THUMB_H      = 12'd112;
    localparam THUMB_SCL_L2 = 2;              // log2(放大倍数)
    localparam COLOR_THUMB_ON  = 24'hffffff;  // 笔画 = 白
    localparam COLOR_THUMB_OFF = 24'h000000;  // 背景 = 黑

    localparam COLOR_LOGO_BLUE   = 24'h1f315c;
    localparam COLOR_LOGO_RED    = 24'hec1c2d;
    localparam COLOR_TEXT        = 24'h00e6ff;
    localparam DYN_OSD_X         = 12'd375;
    localparam DYN_OSD_Y         = 12'd120;
    localparam DYN_OSD_W         = 12'd200;
    localparam DYN_OSD_H         = 12'd24;
    localparam CN_Y_OFFSET       = 12'd2;
    localparam COLOR_DYN_TEXT    = 24'hfff200;
    localparam CHAR_AN           = 8'h80;
    localparam CHAR_LU           = 8'h81;
    localparam CHAR_C            = 8'h43;
    localparam CHAR_N            = 8'h4e;
    localparam CHAR_T            = 8'h54;
    localparam CHAR_0            = 8'h30;
    localparam CHAR_COLON        = 8'h3a;

    // CNN 分类结果数字(0-9)叠加:4× 放大 16×16 字模,屏幕顶部中央。
    localparam CLASS_DIGIT_X     = 12'd624;
    localparam CLASS_DIGIT_Y     = 12'd40;
    localparam CLASS_DIGIT_W     = 12'd64;
    localparam CLASS_DIGIT_H     = 12'd64;
    localparam COLOR_CLASS       = 24'h00ffff;

    // ---- FPS 读数(CNN 识别速率 + 摄像头输入帧率):左下角空白区 ----
    // ROI 取景框到 y=583 为止,所以 y>=640 这条带整幅宽度都是空的。
    // 16x16 字模 2x 放大(>>1 纯位切片)= 每字 32x32;字符串 "CNN:12 CAM:59"
    // 共 13 字符 = 416 像素宽、32 高;左右各 16、上下各 8 的暗化内边距 ⇒ 448x48。
    localparam FPS_BOX_X     = 12'd32;
    localparam FPS_BOX_Y     = 12'd640;
    localparam FPS_BOX_W     = 12'd448;
    localparam FPS_BOX_H     = 12'd48;
    localparam FPS_PAD_X     = 12'd16;
    localparam FPS_PAD_Y     = 12'd8;
    localparam FPS_TEXT_W    = 12'd416;      // 13 字符 x 32
    localparam FPS_TEXT_H    = 12'd32;       // 1 行 x 32
    localparam COLOR_FPS     = 24'hff8800;   // 橙色:字形笔画(避开已用的青/黄/绿)
    localparam CHAR_A        = 8'h41;
    localparam CHAR_M        = 8'h4d;

    function [4:0] F_logo_text_bits;
        input [3:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'd0: begin
                    case(I_row) // A
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10001;
                        3'd3: F_logo_text_bits = 5'b11111;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b10001;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd1: begin
                    case(I_row) // N
                        3'd0: F_logo_text_bits = 5'b10001;
                        3'd1: F_logo_text_bits = 5'b11001;
                        3'd2: F_logo_text_bits = 5'b10101;
                        3'd3: F_logo_text_bits = 5'b10011;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b10001;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd2: begin
                    case(I_row) // L
                        3'd0: F_logo_text_bits = 5'b10000;
                        3'd1: F_logo_text_bits = 5'b10000;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10000;
                        3'd4: F_logo_text_bits = 5'b10000;
                        3'd5: F_logo_text_bits = 5'b10000;
                        3'd6: F_logo_text_bits = 5'b11111;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd3: begin
                    case(I_row) // O
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10001;
                        3'd3: F_logo_text_bits = 5'b10001;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd4: begin
                    case(I_row) // G
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10111;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd5: begin
                    case(I_row) // I
                        3'd0: F_logo_text_bits = 5'b11111;
                        3'd1: F_logo_text_bits = 5'b00100;
                        3'd2: F_logo_text_bits = 5'b00100;
                        3'd3: F_logo_text_bits = 5'b00100;
                        3'd4: F_logo_text_bits = 5'b00100;
                        3'd5: F_logo_text_bits = 5'b00100;
                        3'd6: F_logo_text_bits = 5'b11111;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd6: begin
                    case(I_row) // C
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10000;
                        3'd4: F_logo_text_bits = 5'b10000;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                default: F_logo_text_bits = 5'b00000;
            endcase
        end
    endfunction

    // 7-seg bit mapping: {a,b,c,d,e,f,g}
    function [6:0] F_hex7seg;
        input [3:0] I_hex;
        begin
            case(I_hex)
                4'h0: F_hex7seg = 7'b1111110;
                4'h1: F_hex7seg = 7'b0110000;
                4'h2: F_hex7seg = 7'b1101101;
                4'h3: F_hex7seg = 7'b1111001;
                4'h4: F_hex7seg = 7'b0110011;
                4'h5: F_hex7seg = 7'b1011011;
                4'h6: F_hex7seg = 7'b1011111;
                4'h7: F_hex7seg = 7'b1110000;
                4'h8: F_hex7seg = 7'b1111111;
                4'h9: F_hex7seg = 7'b1111011;
                4'ha: F_hex7seg = 7'b1110111;
                4'hb: F_hex7seg = 7'b0011111;
                4'hc: F_hex7seg = 7'b1001110;
                4'hd: F_hex7seg = 7'b0111101;
                4'he: F_hex7seg = 7'b1001111;
                4'hf: F_hex7seg = 7'b1000111;
                default: F_hex7seg = 7'b0000000;
            endcase
        end
    endfunction

    function [4:0] F_cnt_label_bits;
        input [1:0] I_idx;
        input [2:0] I_row;
        begin
            case(I_idx)
                2'd0: begin // C
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b01110;
                        3'd1: F_cnt_label_bits = 5'b10001;
                        3'd2: F_cnt_label_bits = 5'b10000;
                        3'd3: F_cnt_label_bits = 5'b10000;
                        3'd4: F_cnt_label_bits = 5'b10000;
                        3'd5: F_cnt_label_bits = 5'b10001;
                        3'd6: F_cnt_label_bits = 5'b01110;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                2'd1: begin // N
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b10001;
                        3'd1: F_cnt_label_bits = 5'b11001;
                        3'd2: F_cnt_label_bits = 5'b10101;
                        3'd3: F_cnt_label_bits = 5'b10011;
                        3'd4: F_cnt_label_bits = 5'b10001;
                        3'd5: F_cnt_label_bits = 5'b10001;
                        3'd6: F_cnt_label_bits = 5'b10001;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                2'd2: begin // T
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b11111;
                        3'd1: F_cnt_label_bits = 5'b00100;
                        3'd2: F_cnt_label_bits = 5'b00100;
                        3'd3: F_cnt_label_bits = 5'b00100;
                        3'd4: F_cnt_label_bits = 5'b00100;
                        3'd5: F_cnt_label_bits = 5'b00100;
                        3'd6: F_cnt_label_bits = 5'b00100;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                default: begin // ':'
                    case(I_row)
                        3'd2: F_cnt_label_bits = 5'b00100;
                        3'd5: F_cnt_label_bits = 5'b00100;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
            endcase
        end
    endfunction

    // Minimal 16x16 Chinese bitmap rows for "an" and "lu".
    function [15:0] F_cn16_row;
        input I_char; // 0: an, 1: lu
        input [3:0] I_row;
        begin
            if(!I_char) begin
                case(I_row)
                    4'd0:  F_cn16_row = 16'h0200;
                    4'd1:  F_cn16_row = 16'h7ff0;
                    4'd2:  F_cn16_row = 16'h4410;
                    4'd3:  F_cn16_row = 16'h0400;
                    4'd4:  F_cn16_row = 16'h7ff0;
                    4'd5:  F_cn16_row = 16'h0840;
                    4'd6:  F_cn16_row = 16'h1040;
                    4'd7:  F_cn16_row = 16'h1c80;
                    4'd8:  F_cn16_row = 16'h0300;
                    4'd9:  F_cn16_row = 16'h0cc0;
                    4'd10: F_cn16_row = 16'h7020;
                    4'd11: F_cn16_row = 16'h0000;
                    4'd12: F_cn16_row = 16'h0000;
                    4'd13: F_cn16_row = 16'h0000;
                    4'd14: F_cn16_row = 16'h0000;
                    4'd15: F_cn16_row = 16'h0000;
                    default: F_cn16_row = 16'h0000;
                endcase
            end
            else begin
                case(I_row)
                    4'd0:  F_cn16_row = 16'h79e0;
                    4'd1:  F_cn16_row = 16'h4a20;
                    4'd2:  F_cn16_row = 16'h4d40;
                    4'd3:  F_cn16_row = 16'h7880;
                    4'd4:  F_cn16_row = 16'h1140;
                    4'd5:  F_cn16_row = 16'h1630;
                    4'd6:  F_cn16_row = 16'h5be0;
                    4'd7:  F_cn16_row = 16'h5220;
                    4'd8:  F_cn16_row = 16'h5220;
                    4'd9:  F_cn16_row = 16'h5be0;
                    4'd10: F_cn16_row = 16'h6220;
                    4'd11: F_cn16_row = 16'h0000;
                    4'd12: F_cn16_row = 16'h0000;
                    4'd13: F_cn16_row = 16'h0000;
                    4'd14: F_cn16_row = 16'h0000;
                    4'd15: F_cn16_row = 16'h0000;
                    default: F_cn16_row = 16'h0000;
                endcase
            end
        end
    endfunction

    function [4:0] F_dyn_char_bits;
        input [3:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'h0: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10011; 3'd3:F_dyn_char_bits=5'b10101; 3'd4:F_dyn_char_bits=5'b11001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h1: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00100; 3'd1:F_dyn_char_bits=5'b01100; 3'd2:F_dyn_char_bits=5'b00100; 3'd3:F_dyn_char_bits=5'b00100; 3'd4:F_dyn_char_bits=5'b00100; 3'd5:F_dyn_char_bits=5'b00100; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h2: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b00001; 3'd3:F_dyn_char_bits=5'b00110; 3'd4:F_dyn_char_bits=5'b01000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b11111; default:F_dyn_char_bits=5'b00000; endcase end
                4'h3: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b00001; 3'd2:F_dyn_char_bits=5'b00001; 3'd3:F_dyn_char_bits=5'b01110; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b00001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h4: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00010; 3'd1:F_dyn_char_bits=5'b00110; 3'd2:F_dyn_char_bits=5'b01010; 3'd3:F_dyn_char_bits=5'b10010; 3'd4:F_dyn_char_bits=5'b11111; 3'd5:F_dyn_char_bits=5'b00010; 3'd6:F_dyn_char_bits=5'b00010; default:F_dyn_char_bits=5'b00000; endcase end
                4'h5: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b11110; 3'd3:F_dyn_char_bits=5'b00001; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h6: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00110; 3'd1:F_dyn_char_bits=5'b01000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h7: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b00001; 3'd2:F_dyn_char_bits=5'b00010; 3'd3:F_dyn_char_bits=5'b00100; 3'd4:F_dyn_char_bits=5'b01000; 3'd5:F_dyn_char_bits=5'b01000; 3'd6:F_dyn_char_bits=5'b01000; default:F_dyn_char_bits=5'b00000; endcase end
                4'h8: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b01110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h9: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b01111; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b00010; 3'd6:F_dyn_char_bits=5'b11100; default:F_dyn_char_bits=5'b00000; endcase end
                4'ha: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b11111; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b10001; default:F_dyn_char_bits=5'b00000; endcase end
                4'hb: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'hc: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b10000; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'hd: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b10001; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'he: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b11111; default:F_dyn_char_bits=5'b00000; endcase end
                4'hf: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b10000; default:F_dyn_char_bits=5'b00000; endcase end
                default: F_dyn_char_bits = 5'b00000;
            endcase
        end
    endfunction

    // Unified prefix character library (16x16 rows): an/lu/C/N/T/:
    function [15:0] F_osd_char16_row;
        input [7:0] I_char;
        input [3:0] I_row;
        begin
            case(I_char)
                CHAR_AN: begin
                    case(I_row)
                        4'd0:  F_osd_char16_row = 16'h0200;
                        4'd1:  F_osd_char16_row = 16'h7ff0;
                        4'd2:  F_osd_char16_row = 16'h4410;
                        4'd3:  F_osd_char16_row = 16'h0400;
                        4'd4:  F_osd_char16_row = 16'h7ff0;
                        4'd5:  F_osd_char16_row = 16'h0840;
                        4'd6:  F_osd_char16_row = 16'h1040;
                        4'd7:  F_osd_char16_row = 16'h1c80;
                        4'd8:  F_osd_char16_row = 16'h0300;
                        4'd9:  F_osd_char16_row = 16'h0cc0;
                        4'd10: F_osd_char16_row = 16'h7020;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_LU: begin
                    case(I_row)
                        4'd0:  F_osd_char16_row = 16'h79e0;
                        4'd1:  F_osd_char16_row = 16'h4a20;
                        4'd2:  F_osd_char16_row = 16'h4d40;
                        4'd3:  F_osd_char16_row = 16'h7880;
                        4'd4:  F_osd_char16_row = 16'h1140;
                        4'd5:  F_osd_char16_row = 16'h1630;
                        4'd6:  F_osd_char16_row = 16'h5be0;
                        4'd7:  F_osd_char16_row = 16'h5220;
                        4'd8:  F_osd_char16_row = 16'h5220;
                        4'd9:  F_osd_char16_row = 16'h5be0;
                        4'd10: F_osd_char16_row = 16'h6220;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_C: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h03f0;
                        4'd3:  F_osd_char16_row = 16'h0c0c;
                        4'd4:  F_osd_char16_row = 16'h1800;
                        4'd5:  F_osd_char16_row = 16'h3000;
                        4'd6:  F_osd_char16_row = 16'h3000;
                        4'd7:  F_osd_char16_row = 16'h3000;
                        4'd8:  F_osd_char16_row = 16'h3000;
                        4'd9:  F_osd_char16_row = 16'h3000;
                        4'd10: F_osd_char16_row = 16'h1800;
                        4'd11: F_osd_char16_row = 16'h0c0c;
                        4'd12: F_osd_char16_row = 16'h03f0;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_N: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h300c;
                        4'd3:  F_osd_char16_row = 16'h380c;
                        4'd4:  F_osd_char16_row = 16'h3c0c;
                        4'd5:  F_osd_char16_row = 16'h360c;
                        4'd6:  F_osd_char16_row = 16'h330c;
                        4'd7:  F_osd_char16_row = 16'h318c;
                        4'd8:  F_osd_char16_row = 16'h30cc;
                        4'd9:  F_osd_char16_row = 16'h306c;
                        4'd10: F_osd_char16_row = 16'h303c;
                        4'd11: F_osd_char16_row = 16'h301c;
                        4'd12: F_osd_char16_row = 16'h300c;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_T: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h3ffc;
                        4'd3:  F_osd_char16_row = 16'h03c0;
                        4'd4:  F_osd_char16_row = 16'h03c0;
                        4'd5:  F_osd_char16_row = 16'h03c0;
                        4'd6:  F_osd_char16_row = 16'h03c0;
                        4'd7:  F_osd_char16_row = 16'h03c0;
                        4'd8:  F_osd_char16_row = 16'h03c0;
                        4'd9:  F_osd_char16_row = 16'h03c0;
                        4'd10: F_osd_char16_row = 16'h03c0;
                        4'd11: F_osd_char16_row = 16'h03c0;
                        4'd12: F_osd_char16_row = 16'h03c0;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_COLON: begin
                    case(I_row)
                        4'd6:  F_osd_char16_row = 16'h0180;
                        4'd7:  F_osd_char16_row = 16'h0180;
                        4'd10: F_osd_char16_row = 16'h0180;
                        4'd11: F_osd_char16_row = 16'h0180;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                default: F_osd_char16_row = 16'h0000;
            endcase
        end
    endfunction

    assign O_video_rd_en = I_video_de;

    // logo 表整体搬进块 RAM(见 a/gen_logo_rom_eram.py):显示窗口没变,表按 2× 降采样
    // 存进 ERAM,不再占任何 fabric 逻辑 —— 就是那 ~700 个分散 slice 在挤 CNN MAC/DSP
    // 的落点。ERAM 读是寄存 1 拍,地址约定见下面 S_logo_addr_r 的 always 块。
    logo_rom_eram u_logo_rom_eram(
        .I_clk   ( I_clk          ),
        .I_addr  ( S_logo_addr_r  ),
        .O_pixel ( S_logo_pixel   )
    );

    // 28x28 预处理预览缓冲:784x8,单时钟(读写都在本 75MHz 像素域)。
    // 为什么用显式 ERAM 而不是可推断数组:这里的读延迟决定地址要提前几级取,
    // 数组会被推断成分布式 RAM(组合读、~98 个 LUT),而 ERAM 是块 RAM(寄存读)。
    // 这条通路正处在 75MHz OSD 关键路径的同一片区域,块 RAM 更稳。
    // 注意 NOREG 读其实**寄存 1 拍**(见 cnn/sim/eram_model.v 头部),地址因此取自 1d 级。
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
        .CLKMODE("SYNC"),
        .DEBUGGABLE("NO"), .PACKABLE("NO"), .FORCE_KEEP("OFF"),
        .INIT_FILE("NONE"), .FILL_ALL("NONE"),
        .IMPLEMENT("20K(FAST)")
    ) u_thumb_ram (
        .dia(I_thumb_data), .dib(8'd0),
        .addra(I_thumb_addr), .addrb(S_thumb_addr_r),
        .cea(I_thumb_we), .ceb(1'b1),
        .ocea(1'b0), .oceb(1'b0),
        .clka(I_clk), .clkb(I_clk),
        .wea(1'b1), .web(1'b0),
        .bea(1'b0), .beb(1'b0),
        .rsta(1'b0), .rstb(1'b0),
        .ecc_sbiterrinj(1'b0), .ecc_dbiterrinj(1'b0),
        .doa(), .dob(S_thumb_pixel),
        .ecc_sbiterr(), .ecc_dbiterr()
    );

    osd_char_lib u_osd_char_lib(
        .I_char     ( S_pf_char     ),
        .I_row      ( S_pf_row      ),
        .O_row_bits ( S_pf_row_bits )
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end
        else if(I_video_user) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end
        else if(I_video_de) begin
            if(I_video_last) begin
                S_x <= 12'd0;
                S_y <= S_y + 12'd1;
            end
            else begin
                S_x <= S_x + 12'd1;
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_frame_cnt <= 32'd0;
            S_cnt_d0 <= 4'd0;
            S_cnt_d1 <= 4'd0;
            S_cnt_d2 <= 4'd0;
            S_cnt_d3 <= 4'd0;
            S_cnt_d4 <= 4'd0;
            S_cnt_d5 <= 4'd0;
        end
        else if(I_video_user) begin
            S_frame_cnt <= S_frame_cnt + 32'd1;
            if(S_cnt_d0 == 4'd9) begin
                S_cnt_d0 <= 4'd0;
                if(S_cnt_d1 == 4'd9) begin
                    S_cnt_d1 <= 4'd0;
                    if(S_cnt_d2 == 4'd9) begin
                        S_cnt_d2 <= 4'd0;
                        if(S_cnt_d3 == 4'd9) begin
                            S_cnt_d3 <= 4'd0;
                            if(S_cnt_d4 == 4'd9) begin
                                S_cnt_d4 <= 4'd0;
                                if(S_cnt_d5 == 4'd9)
                                    S_cnt_d5 <= 4'd0;
                                else
                                    S_cnt_d5 <= S_cnt_d5 + 4'd1;
                            end
                            else
                                S_cnt_d4 <= S_cnt_d4 + 4'd1;
                        end
                        else
                            S_cnt_d3 <= S_cnt_d3 + 4'd1;
                    end
                    else
                        S_cnt_d2 <= S_cnt_d2 + 4'd1;
                end
                else
                    S_cnt_d1 <= S_cnt_d1 + 4'd1;
            end
            else
                S_cnt_d0 <= S_cnt_d0 + 4'd1;
        end
    end

    // ---- FPS:1 秒门控 + 脉冲计数 + 二进制转 BCD ----
    // 全程在 75MHz 域内,且只在门控到期那一拍做除法/取模(每秒一次),不在每像素的
    // 组合链上,对 75MHz 的 OSD 临界路径零影响。累加器钳在 127,显示超过 99 时按 99。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_fps_gate_cnt  <= 27'd0;
            S_fps_gate_tick <= 1'b0;
            S_fps_cam_acc   <= 7'd0;
            S_fps_cnn_acc   <= 7'd0;
            S_fps_cam_d1    <= 4'd0;
            S_fps_cam_d0    <= 4'd0;
            S_fps_cnn_d1    <= 4'd0;
            S_fps_cnn_d0    <= 4'd0;
        end
        else begin
            if(S_fps_gate_cnt == (FPS_GATE_MAX - 27'd1)) begin
                S_fps_gate_cnt  <= 27'd0;
                S_fps_gate_tick <= 1'b1;
            end
            else begin
                S_fps_gate_cnt  <= S_fps_gate_cnt + 27'd1;
                S_fps_gate_tick <= 1'b0;
            end

            if(I_fps_cam_pulse && (S_fps_cam_acc != 7'd127))
                S_fps_cam_acc <= S_fps_cam_acc + 7'd1;
            if(I_fps_cnn_pulse && (S_fps_cnn_acc != 7'd127))
                S_fps_cnn_acc <= S_fps_cnn_acc + 7'd1;

            if(S_fps_gate_tick) begin
                if(S_fps_cam_acc > 7'd99) begin
                    S_fps_cam_d1 <= 4'd9;
                    S_fps_cam_d0 <= 4'd9;
                end
                else begin
                    S_fps_cam_d1 <= S_fps_cam_acc / 7'd10;
                    S_fps_cam_d0 <= S_fps_cam_acc % 7'd10;
                end

                if(S_fps_cnn_acc > 7'd99) begin
                    S_fps_cnn_d1 <= 4'd9;
                    S_fps_cnn_d0 <= 4'd9;
                end
                else begin
                    S_fps_cnn_d1 <= S_fps_cnn_acc / 7'd10;
                    S_fps_cnn_d0 <= S_fps_cnn_acc % 7'd10;
                end

                S_fps_cam_acc <= 7'd0;
                S_fps_cnn_acc <= 7'd0;
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x_1d <= 12'd0;
            S_x_2d <= 12'd0;
            S_x_3d <= 12'd0;
            S_y_1d <= 12'd0;
            S_y_2d <= 12'd0;
            S_y_3d <= 12'd0;
        end
        else begin
            S_x_1d <= S_x;
            S_x_2d <= S_x_1d;
            S_x_3d <= S_x_2d;
            S_y_1d <= S_y;
            S_y_2d <= S_y_1d;
            S_y_3d <= S_y_2d;
        end
    end

    // logo 地址取自 **1d 级**(S_x_1d/S_y_1d),与 S_thumb_addr_r 同一约定 —— 因为 ERAM
    // 读是寄存 1 拍(REGMODE_A("NOREG") 也照样寄存,见 cnn/sim/eram_model.v 头部),
    // 比组合 ROM 时代要多提前一拍。
    //   对齐:设第 n 拍 S_x_1d == X(n-1),则本寄存器在第 n+1 拍输出 X(n-1) 的地址、
    //   ERAM 在第 n+2 拍给出数据;而第 n+2 拍正是 S_x_3d == X(n-1) ⇒ 与 3d 级 OSD 链对齐。
    // 窗口/命中判定仍按 160x160 走(S_logo_w3 那边一个字都不动);只有查表地址减半:
    // >>1 是 2 倍降采样,乘 LOGO_SRC_W=80。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_logo_addr_r <= 13'd0;
        end
        else if((S_x_1d >= LOGO_X) && (S_x_1d < (LOGO_X + LOGO_W)) &&
                (S_y_1d >= LOGO_Y) && (S_y_1d < (LOGO_Y + LOGO_H))) begin
            S_logo_addr_r <= ((S_y_1d - LOGO_Y) >> 1) * LOGO_SRC_W +
                             ((S_x_1d - LOGO_X) >> 1);
        end
        else begin
            S_logo_addr_r <= 13'd0;
        end
    end

    // 预览地址:与 logo 同构(窗口判定 + 乘加算地址,结果寄存),但**取 1d 级**而不是 2d 级 ——
    // ERAM 的读输出寄存 1 拍,合起来才和 S_x_3d/S_y_3d 对齐;取 2d 会整体晚一拍(画面错位)。
    // 窗口只有 112x112,所以 (y>>2) 落在 0..27,不用额外钳位。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_thumb_addr_r <= 10'd0;
        end
        else if((S_x_1d >= THUMB_X) && (S_x_1d < (THUMB_X + THUMB_W)) &&
                (S_y_1d >= THUMB_Y) && (S_y_1d < (THUMB_Y + THUMB_H))) begin
            S_thumb_addr_r <= (((S_y_1d - THUMB_Y) >> THUMB_SCL_L2) * 12'd28) +
                              ((S_x_1d - THUMB_X) >> THUMB_SCL_L2);
        end
        else begin
            S_thumb_addr_r <= 10'd0;
        end
    end

    // 窗口命中判定**提前到 2d 级**算好并寄存,3d 级的 OSD 链就只需读 1bit 的 FF,
    // 不再摆 8 个比较器 + 6 个 AND。
    //
    // 对齐关系(与 S_logo_addr_r 完全同一套推理):设 S_x == X(n-2) 在第 n 拍,
    // 则第 n+1 拍时 S_x_3d == X(n-2),而本寄存器的输出也正是 X(n-2) 的判定结果
    // ⇒ 一拍寄存即与 3d 级对齐。这样 logo 那条分支能"免费"回到 OSD 链里,
    // 不占用 75MHz 那条关键路径(2026-10-11 实测 SWNS +1.477ns / Max-Level 14)。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_thumb_w3 <= 1'b0;
            S_logo_w3  <= 1'b0;
        end
        else begin
            S_thumb_w3 <= (S_x_2d >= THUMB_X) && (S_x_2d < (THUMB_X + THUMB_W)) &&
                          (S_y_2d >= THUMB_Y) && (S_y_2d < (THUMB_Y + THUMB_H));
            S_logo_w3  <= (S_x_2d >= LOGO_X ) && (S_x_2d < (LOGO_X  + LOGO_W )) &&
                          (S_y_2d >= LOGO_Y ) && (S_y_2d < (LOGO_Y  + LOGO_H ));
        end
    end

    // FPS 读数:字形解码放在 **2d 组合**里做,只把最终"笔画位"寄存一拍到 3d。
    // 这样 3d 那条约 75MHz 关键路径上,只有 S_fps_w3 / S_fps_on3 两个 1bit FF 参与
    // 颜色多路选择,**完全不碰 DYN/CLASS 共用的 S_pf_char/S_pf_row/S_pf_row_bits**。
    // (2026-10-26 实测教训:让 FPS 也去抢那套共用字形 ROM,会把 clk3 从 +0.39ns
    //  推到 -4.34ns —— 最差路径变成 logo ERAM -> S_pf_char mux -> 输出寄存器,21 级。)
    // FPS 用自己独立的 osd_char_lib 实例,输入是 2d 组合信号,与 3d 那条链彻底解耦。
    //
    // 字符布局 "CNN:12 CAM:59"(共 13 字符,每字符 32px):
    //   idx 0 C  1 N  2 N  3 :  4 cnn十  5 cnn个  6 空格  7 C  8 A  9 M  10 :  11 cam十  12 cam个
    // 框内、文字区外 => 字符码 8'h00(osd_char_lib 的 default 分支,全 0),只留暗化底。
    always @(*) begin
        S_fps_char_code = 8'd0;
        S_fps_glyph_col = 4'd0;
        S_fps_glyph_row = 4'd0;

        if((S_x_2d >= (FPS_BOX_X + FPS_PAD_X)) &&
           (S_x_2d <  (FPS_BOX_X + FPS_PAD_X + FPS_TEXT_W)) &&
           (S_y_2d >= (FPS_BOX_Y + FPS_PAD_Y)) &&
           (S_y_2d <  (FPS_BOX_Y + FPS_PAD_Y + FPS_TEXT_H))) begin
            // 2x 放大:字形列/行 = 局部坐标 >>1,赋给 4 位寄存器时自然截成 bit[4:1]
            S_fps_glyph_col = (S_x_2d - (FPS_BOX_X + FPS_PAD_X)) >> 1;
            S_fps_glyph_row = (S_y_2d - (FPS_BOX_Y + FPS_PAD_Y)) >> 1;

            case((S_x_2d - (FPS_BOX_X + FPS_PAD_X)) >> 5)   // /32 = 字符序号 0..12
                4'd0:    S_fps_char_code = CHAR_C;
                4'd1:    S_fps_char_code = CHAR_N;
                4'd2:    S_fps_char_code = CHAR_N;
                4'd3:    S_fps_char_code = CHAR_COLON;
                4'd4:    S_fps_char_code = CHAR_0 + {4'd0, S_fps_cnn_d1};
                4'd5:    S_fps_char_code = CHAR_0 + {4'd0, S_fps_cnn_d0};
                4'd6:    S_fps_char_code = 8'd0;            // 空格 => 空白
                4'd7:    S_fps_char_code = CHAR_C;
                4'd8:    S_fps_char_code = CHAR_A;
                4'd9:    S_fps_char_code = CHAR_M;
                4'd10:   S_fps_char_code = CHAR_COLON;
                4'd11:   S_fps_char_code = CHAR_0 + {4'd0, S_fps_cam_d1};
                4'd12:   S_fps_char_code = CHAR_0 + {4'd0, S_fps_cam_d0};
                default: S_fps_char_code = 8'd0;
            endcase
        end
    end

    // FPS 专用字形 ROM:与 3d 那条共用的 u_osd_char_lib 是两个独立实例。
    osd_char_lib u_osd_char_lib_fps(
        .I_char     ( S_fps_char_code ),
        .I_row      ( S_fps_glyph_row ),
        .O_row_bits ( S_fps_row_bits )
    );

    // 2d 组合位选择:16 路选 1
    always @(*) begin
        case(S_fps_glyph_col)
            4'd0:    S_fps_on_2d = S_fps_row_bits[15];
            4'd1:    S_fps_on_2d = S_fps_row_bits[14];
            4'd2:    S_fps_on_2d = S_fps_row_bits[13];
            4'd3:    S_fps_on_2d = S_fps_row_bits[12];
            4'd4:    S_fps_on_2d = S_fps_row_bits[11];
            4'd5:    S_fps_on_2d = S_fps_row_bits[10];
            4'd6:    S_fps_on_2d = S_fps_row_bits[9];
            4'd7:    S_fps_on_2d = S_fps_row_bits[8];
            4'd8:    S_fps_on_2d = S_fps_row_bits[7];
            4'd9:    S_fps_on_2d = S_fps_row_bits[6];
            4'd10:   S_fps_on_2d = S_fps_row_bits[5];
            4'd11:   S_fps_on_2d = S_fps_row_bits[4];
            4'd12:   S_fps_on_2d = S_fps_row_bits[3];
            4'd13:   S_fps_on_2d = S_fps_row_bits[2];
            4'd14:   S_fps_on_2d = S_fps_row_bits[1];
            4'd15:   S_fps_on_2d = S_fps_row_bits[0];
            default: S_fps_on_2d = 1'b0;
        endcase
    end

    // 寄存一拍 => 与 S_x_3d/S_y_3d 对齐(与 S_thumb_w3/S_logo_w3 同一约定)
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_fps_w3  <= 1'b0;
            S_fps_on3 <= 1'b0;
        end
        else begin
            S_fps_w3  <= (S_x_2d >= FPS_BOX_X) && (S_x_2d < (FPS_BOX_X + FPS_BOX_W)) &&
                         (S_y_2d >= FPS_BOX_Y) && (S_y_2d < (FPS_BOX_Y + FPS_BOX_H));
            S_fps_on3 <= S_fps_on_2d;
        end
    end

    // CNN class 4-bit 由 100MHz 域进来,打两拍同步到本 75MHz 域(慢变电平,2-FF 足够)。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_cls_sync1 <= 4'd0;
            S_cls_digit <= 4'd0;
        end
        else begin
            S_cls_sync1 <= I_debug_status;
            S_cls_digit <= S_cls_sync1;
        end
    end

    always @(*) begin
        S_osd_hit   = 1'b0;
        S_osd_color = 24'd0;

        S_char_idx = 4'd0;
        S_char_row = 3'd0;
        S_char_col = 3'd0;
        S_char_bits = 5'd0;
        S_char_on = 1'b0;
        S_logo_blue_on = 1'b0;
        S_logo_red_on = 1'b0;
        S_logo_tmp_y = 12'd0;
        S_logo_red_band = 4'd0;
        S_logo_red_x_start = 12'd0;
        S_logo_red_x_end = 12'd0;
        S_dyn_x = 12'd0;
        S_dyn_y = 12'd0;
        S_dyn_char = 4'd0;
        S_dyn_col = 3'd0;
        S_dyn_row = 3'd0;
        S_dyn_bits = 5'd0;
        S_dyn_on = 1'b0;
        S_dyn_digit_idx = 4'd0;
        S_dyn_digit_x = 12'd0;
        S_dyn_seg = 7'd0;
        S_lbl_row = 3'd0;
        S_lbl_col = 3'd0;
        S_lbl_idx = 2'd0;
        S_lbl_bits = 5'd0;
        S_lbl_local_x = 7'd0;
        S_dyn_dec_digit = 4'd0;
        S_cn_local_x = 5'd0;
        S_cn_local_y = 5'd0;
        S_cn_col = 4'd0;
        S_cn_row = 4'd0;
        S_cn_row_bits = 16'd0;
        S_cn_on = 1'b0;
        S_cn_scale_x = 10'd0;
        S_cn_scale_y = 10'd0;
        S_pf_char = 8'd0;
        S_pf_local_x = 5'd0;
        S_pf_local_y = 5'd0;
        S_pf_col = 4'd0;
        S_pf_row = 4'd0;
        S_pf_on = 1'b0;
        S_pf_scale_x = 10'd0;
        S_pf_scale_y = 10'd0;
        S_cls_local_x = 6'd0;
        S_cls_local_y = 6'd0;

        if(S_video_de_3d) begin
            // 左上角 = 28x28 预览(诊断用),右上角 = 原厂 logo,两者同屏显示。
            // 屏幕上不重叠(x 0..112 vs 1120..1280),所以合进同一条 if/else 链
            // **不改变语义**,却避免把 logo 插成链首分支给后面所有分支各加一级。
            //
            // 命中判定已提前寄存(S_thumb_w3 / S_logo_w3),这一级只剩"读 1bit FF",
            // 8 个比较器 + 6 个 AND 从 3d 级消失 —— 省下的逻辑级正好支付 logo 回归。
            if(S_thumb_w3) begin
                // 这一块必须和"白字黑底、笔画清晰"的 MNIST 很像 —— 不像就说明
                // 极性/取景/对比度还有问题,一眼可判。
                S_osd_hit   = 1'b1;
                S_osd_color = (S_thumb_pixel != 8'd0) ? COLOR_THUMB_ON
                                                      : COLOR_THUMB_OFF;
            end
            else if(S_logo_w3 && S_logo_pixel[24]) begin
                S_osd_hit   = 1'b1;
                S_osd_color = S_logo_pixel[23:0];
            end

            if((!S_osd_hit) &&
               (S_x_3d >= DYN_OSD_X) && (S_x_3d < (DYN_OSD_X + DYN_OSD_W)) &&
               (S_y_3d >= DYN_OSD_Y) && (S_y_3d < (DYN_OSD_Y + DYN_OSD_H))) begin
                S_dyn_x = S_x_3d - DYN_OSD_X;
                S_dyn_y = S_y_3d - DYN_OSD_Y;

                // Unified prefix render using one character library.
                // an:[0..23], lu:[24..47], C:[52..67], N:[68..83], T:[84..99], :[100..107]
                if((S_dyn_x < 12'd108) && (S_dyn_y < 12'd24)) begin
                    if((S_dyn_x < 12'd24) || ((S_dyn_x >= 12'd24) && (S_dyn_x < 12'd48))) begin
                        if(S_dyn_y >= CN_Y_OFFSET)
                            S_pf_local_y = S_dyn_y - CN_Y_OFFSET;
                        else
                            S_pf_local_y = 5'd31;

                        if(S_dyn_x < 12'd24) begin
                            S_pf_char = CHAR_AN;
                            S_pf_local_x = S_dyn_x;
                        end
                        else begin
                            S_pf_char = CHAR_LU;
                            S_pf_local_x = S_dyn_x - 12'd24;
                        end

                        if((S_pf_local_x < 5'd24) && (S_pf_local_y < 5'd24)) begin
                            S_pf_scale_x = S_pf_local_x * 10'd16;
                            S_pf_scale_y = S_pf_local_y * 10'd16;
                            S_pf_col = S_pf_scale_x / 10'd24;
                            S_pf_row = S_pf_scale_y / 10'd24;
                            case(S_pf_col)
                                4'd0:  S_pf_on = S_pf_row_bits[15];
                                4'd1:  S_pf_on = S_pf_row_bits[14];
                                4'd2:  S_pf_on = S_pf_row_bits[13];
                                4'd3:  S_pf_on = S_pf_row_bits[12];
                                4'd4:  S_pf_on = S_pf_row_bits[11];
                                4'd5:  S_pf_on = S_pf_row_bits[10];
                                4'd6:  S_pf_on = S_pf_row_bits[9];
                                4'd7:  S_pf_on = S_pf_row_bits[8];
                                4'd8:  S_pf_on = S_pf_row_bits[7];
                                4'd9:  S_pf_on = S_pf_row_bits[6];
                                4'd10: S_pf_on = S_pf_row_bits[5];
                                4'd11: S_pf_on = S_pf_row_bits[4];
                                4'd12: S_pf_on = S_pf_row_bits[3];
                                4'd13: S_pf_on = S_pf_row_bits[2];
                                4'd14: S_pf_on = S_pf_row_bits[1];
                                4'd15: S_pf_on = S_pf_row_bits[0];
                                default: S_pf_on = 1'b0;
                            endcase
                        end
                    end
                    else if((S_dyn_x >= 12'd52) && (S_dyn_x < 12'd100) && (S_dyn_y >= 12'd4) && (S_dyn_y < 12'd20)) begin
                        if(S_dyn_x < 12'd68) begin
                            S_pf_char = CHAR_C;
                            S_pf_local_x = S_dyn_x - 12'd52;
                        end
                        else if(S_dyn_x < 12'd84) begin
                            S_pf_char = CHAR_N;
                            S_pf_local_x = S_dyn_x - 12'd68;
                        end
                        else begin
                            S_pf_char = CHAR_T;
                            S_pf_local_x = S_dyn_x - 12'd84;
                        end
                        S_pf_local_y = S_dyn_y - 12'd4;
                        S_pf_col = S_pf_local_x[3:0];
                        S_pf_row = S_pf_local_y[3:0];
                        case(S_pf_col)
                            4'd0:  S_pf_on = S_pf_row_bits[15];
                            4'd1:  S_pf_on = S_pf_row_bits[14];
                            4'd2:  S_pf_on = S_pf_row_bits[13];
                            4'd3:  S_pf_on = S_pf_row_bits[12];
                            4'd4:  S_pf_on = S_pf_row_bits[11];
                            4'd5:  S_pf_on = S_pf_row_bits[10];
                            4'd6:  S_pf_on = S_pf_row_bits[9];
                            4'd7:  S_pf_on = S_pf_row_bits[8];
                            4'd8:  S_pf_on = S_pf_row_bits[7];
                            4'd9:  S_pf_on = S_pf_row_bits[6];
                            4'd10: S_pf_on = S_pf_row_bits[5];
                            4'd11: S_pf_on = S_pf_row_bits[4];
                            4'd12: S_pf_on = S_pf_row_bits[3];
                            4'd13: S_pf_on = S_pf_row_bits[2];
                            4'd14: S_pf_on = S_pf_row_bits[1];
                            4'd15: S_pf_on = S_pf_row_bits[0];
                            default: S_pf_on = 1'b0;
                        endcase
                    end
                    else if((S_dyn_x >= 12'd100) && (S_dyn_x < 12'd108) && (S_dyn_y >= 12'd4) && (S_dyn_y < 12'd20)) begin
                        S_pf_char = CHAR_COLON;
                        S_pf_local_x = S_dyn_x - 12'd100;
                        S_pf_local_y = S_dyn_y - 12'd4;
                        S_pf_scale_x = S_pf_local_x * 10'd16;
                        S_pf_col = S_pf_scale_x / 10'd8;
                        S_pf_row = S_pf_local_y[3:0];
                        case(S_pf_col)
                            4'd0:  S_pf_on = S_pf_row_bits[15];
                            4'd1:  S_pf_on = S_pf_row_bits[14];
                            4'd2:  S_pf_on = S_pf_row_bits[13];
                            4'd3:  S_pf_on = S_pf_row_bits[12];
                            4'd4:  S_pf_on = S_pf_row_bits[11];
                            4'd5:  S_pf_on = S_pf_row_bits[10];
                            4'd6:  S_pf_on = S_pf_row_bits[9];
                            4'd7:  S_pf_on = S_pf_row_bits[8];
                            4'd8:  S_pf_on = S_pf_row_bits[7];
                            4'd9:  S_pf_on = S_pf_row_bits[6];
                            4'd10: S_pf_on = S_pf_row_bits[5];
                            4'd11: S_pf_on = S_pf_row_bits[4];
                            4'd12: S_pf_on = S_pf_row_bits[3];
                            4'd13: S_pf_on = S_pf_row_bits[2];
                            4'd14: S_pf_on = S_pf_row_bits[1];
                            4'd15: S_pf_on = S_pf_row_bits[0];
                            default: S_pf_on = 1'b0;
                        endcase
                    end

                    if(S_pf_on)
                        S_dyn_on = 1'b1;
                end

                // Decimal 6 digits starts at x=110. Each digit is 15x24.
                if((S_dyn_x >= 12'd110) && (S_dyn_x < 12'd200)) begin
                    if(S_dyn_x < 12'd125) begin
                        S_dyn_digit_idx = 4'd0;
                        S_dyn_digit_x = S_dyn_x - 12'd110;
                        S_dyn_dec_digit = S_cnt_d5;
                    end
                    else if(S_dyn_x < 12'd140) begin
                        S_dyn_digit_idx = 4'd1;
                        S_dyn_digit_x = S_dyn_x - 12'd125;
                        S_dyn_dec_digit = S_cnt_d4;
                    end
                    else if(S_dyn_x < 12'd155) begin
                        S_dyn_digit_idx = 4'd2;
                        S_dyn_digit_x = S_dyn_x - 12'd140;
                        S_dyn_dec_digit = S_cnt_d3;
                    end
                    else if(S_dyn_x < 12'd170) begin
                        S_dyn_digit_idx = 4'd3;
                        S_dyn_digit_x = S_dyn_x - 12'd155;
                        S_dyn_dec_digit = S_cnt_d2;
                    end
                    else if(S_dyn_x < 12'd185) begin
                        S_dyn_digit_idx = 4'd4;
                        S_dyn_digit_x = S_dyn_x - 12'd170;
                        S_dyn_dec_digit = S_cnt_d1;
                    end
                    else begin
                        S_dyn_digit_idx = 4'd5;
                        S_dyn_digit_x = S_dyn_x - 12'd185;
                        S_dyn_dec_digit = S_cnt_d0;
                    end

                    // Render decimal digits through unified 16x16 character library.
                    // Keep enlarged 15x24 box for readability.
                    if((S_dyn_digit_x < 12'd15) && (S_dyn_y < 12'd24)) begin
                        S_pf_char = CHAR_0 + {4'd0, S_dyn_dec_digit};
                        S_pf_local_x = S_dyn_digit_x[4:0];
                        S_pf_local_y = S_dyn_y[4:0];
                        S_pf_scale_x = S_pf_local_x * 10'd16;
                        S_pf_scale_y = S_pf_local_y * 10'd16;
                        S_pf_col = S_pf_scale_x / 10'd15;
                        S_pf_row = S_pf_scale_y / 10'd24;
                        case(S_pf_col)
                            4'd0:  S_pf_on = S_pf_row_bits[15];
                            4'd1:  S_pf_on = S_pf_row_bits[14];
                            4'd2:  S_pf_on = S_pf_row_bits[13];
                            4'd3:  S_pf_on = S_pf_row_bits[12];
                            4'd4:  S_pf_on = S_pf_row_bits[11];
                            4'd5:  S_pf_on = S_pf_row_bits[10];
                            4'd6:  S_pf_on = S_pf_row_bits[9];
                            4'd7:  S_pf_on = S_pf_row_bits[8];
                            4'd8:  S_pf_on = S_pf_row_bits[7];
                            4'd9:  S_pf_on = S_pf_row_bits[6];
                            4'd10: S_pf_on = S_pf_row_bits[5];
                            4'd11: S_pf_on = S_pf_row_bits[4];
                            4'd12: S_pf_on = S_pf_row_bits[3];
                            4'd13: S_pf_on = S_pf_row_bits[2];
                            4'd14: S_pf_on = S_pf_row_bits[1];
                            4'd15: S_pf_on = S_pf_row_bits[0];
                            default: S_pf_on = 1'b0;
                        endcase
                        if(S_pf_on)
                            S_dyn_on = 1'b1;
                    end
                end

                if(S_dyn_on) begin
                    S_osd_hit = 1'b1;
                    S_osd_color = COLOR_DYN_TEXT;
                end
            end

            // CNN 分类结果数字(0-9):4× 放大 16×16 字模,屏幕顶部中央。
            if((!S_osd_hit) &&
               (S_x_3d >= CLASS_DIGIT_X) && (S_x_3d < (CLASS_DIGIT_X + CLASS_DIGIT_W)) &&
               (S_y_3d >= CLASS_DIGIT_Y) && (S_y_3d < (CLASS_DIGIT_Y + CLASS_DIGIT_H))) begin
                S_pf_char = CHAR_0 + {4'd0, S_cls_digit};
                S_cls_local_x = S_x_3d - CLASS_DIGIT_X;
                S_cls_local_y = S_y_3d - CLASS_DIGIT_Y;
                S_pf_col = S_cls_local_x[5:2];
                S_pf_row = S_cls_local_y[5:2];
                case(S_pf_col)
                    4'd0:  S_pf_on = S_pf_row_bits[15];
                    4'd1:  S_pf_on = S_pf_row_bits[14];
                    4'd2:  S_pf_on = S_pf_row_bits[13];
                    4'd3:  S_pf_on = S_pf_row_bits[12];
                    4'd4:  S_pf_on = S_pf_row_bits[11];
                    4'd5:  S_pf_on = S_pf_row_bits[10];
                    4'd6:  S_pf_on = S_pf_row_bits[9];
                    4'd7:  S_pf_on = S_pf_row_bits[8];
                    4'd8:  S_pf_on = S_pf_row_bits[7];
                    4'd9:  S_pf_on = S_pf_row_bits[6];
                    4'd10: S_pf_on = S_pf_row_bits[5];
                    4'd11: S_pf_on = S_pf_row_bits[4];
                    4'd12: S_pf_on = S_pf_row_bits[3];
                    4'd13: S_pf_on = S_pf_row_bits[2];
                    4'd14: S_pf_on = S_pf_row_bits[1];
                    4'd15: S_pf_on = S_pf_row_bits[0];
                    default: S_pf_on = 1'b0;
                endcase
                if(S_pf_on) begin
                    S_osd_hit   = 1'b1;
                    S_osd_color = COLOR_CLASS;
                end
            end

            // FPS 读数:CNN 识别速率 + 摄像头输入帧率,屏幕左下角。
            // 与 CNN 分类数字同样的画法:**只画字形笔画,不画背景** —— 笔画间像素直接
            // 透出底下画面。(早先那版在这里画"视频 >>1"的暗化底,但整条 24bit 总线右移
            //  会把 R 的 LSB 串进 G、G 的串进 B,上板表现为绿/蓝花斑,已删除。)
            // 字形查表/位选择都已在 2d 级做完并寄存成 S_fps_on3(1bit),这一级只是
            // "笔画才置 hit"的判断。**不碰共用的 S_pf_char/S_pf_row**,避免拖累 clk3。
            if((!S_osd_hit) && S_fps_w3 && S_fps_on3) begin
                S_osd_hit   = 1'b1;
                S_osd_color = COLOR_FPS;
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_video_vsync_1d <= 1'b0;
            S_video_vsync_2d <= 1'b0;
            S_video_vsync_3d <= 1'b0;
            S_video_hsync_1d <= 1'b0;
            S_video_hsync_2d <= 1'b0;
            S_video_hsync_3d <= 1'b0;
            S_video_de_1d    <= 1'b0;
            S_video_de_2d    <= 1'b0;
            S_video_de_3d    <= 1'b0;
            O_hdmi_vsync     <= 1'b0;
            O_hdmi_hsync     <= 1'b0;
            O_hdmi_de        <= 1'b0;
            O_hdmi_data      <= 24'd0;
        end
        else begin
            S_video_vsync_1d <= I_video_vsync;
            S_video_vsync_2d <= S_video_vsync_1d;
            S_video_vsync_3d <= S_video_vsync_2d;
            O_hdmi_vsync     <= S_video_vsync_3d;

            S_video_hsync_1d <= I_video_hsync;
            S_video_hsync_2d <= S_video_hsync_1d;
            S_video_hsync_3d <= S_video_hsync_2d;
            O_hdmi_hsync     <= S_video_hsync_3d;

            S_video_de_1d    <= I_video_de;
            S_video_de_2d    <= S_video_de_1d;
            S_video_de_3d    <= S_video_de_2d;
            O_hdmi_de        <= S_video_de_3d;
            S_video_data_1d  <= I_video_rd_data;
            S_video_data_2d  <= S_video_data_1d;
            S_video_data_3d  <= S_video_data_2d;

            if(DEBUG_MODE == 1) begin
                if(S_video_de_2d) begin
                    if(S_x < 12'd128)
                        O_hdmi_data <= 24'hff0000;
                    else if(S_x < 12'd256)
                        O_hdmi_data <= 24'h00ff00;
                    else if(S_x < 12'd384)
                        O_hdmi_data <= 24'h0000ff;
                    else if(S_x < 12'd512)
                        O_hdmi_data <= 24'hffff00;
                    else if(S_x < 12'd640)
                        O_hdmi_data <= 24'h00ffff;
                    else if(S_x < 12'd768)
                        O_hdmi_data <= 24'hff00ff;
                    else if(S_x < 12'd896)
                        O_hdmi_data <= 24'hffffff;
                    else
                        O_hdmi_data <= 24'h202020;
                end
                else begin
                    O_hdmi_data <= 24'd0;
                end
            end
            else if(DEBUG_MODE == 2) begin
                if(S_video_de_2d) begin
                    case (I_debug_status)
                        4'b0000: O_hdmi_data <= 24'h000000;
                        4'b0001: O_hdmi_data <= 24'hff0000;
                        4'b0011: O_hdmi_data <= 24'hffff00;
                        4'b0111: O_hdmi_data <= 24'h00ff00;
                        4'b1111: O_hdmi_data <= I_video_rd_data;
                        default: O_hdmi_data <= 24'h0000ff;
                    endcase
                end
                else begin
                    O_hdmi_data <= 24'd0;
                end
            end
            else if(DEBUG_MODE == 3) begin
                if(S_video_de_2d) begin
                    if(S_x < 12'd256)
                        O_hdmi_data <= I_debug_status[0] ? 24'hff8000 : 24'h201000;
                    else if(S_x < 12'd512)
                        O_hdmi_data <= I_debug_status[1] ? 24'hffff00 : 24'h202000;
                    else if(S_x < 12'd768)
                        O_hdmi_data <= I_debug_status[2] ? 24'hff0000 : 24'h200000;
                    else
                        O_hdmi_data <= I_debug_status[3] ? 24'h00ffff : 24'h002020;
                end
                else begin
                    O_hdmi_data <= 24'd0;
                end
            end
            else begin
                if(S_osd_hit)
                    O_hdmi_data <= S_osd_color;
                else
                    O_hdmi_data <= S_video_data_3d;
            end
        end
    end

endmodule
