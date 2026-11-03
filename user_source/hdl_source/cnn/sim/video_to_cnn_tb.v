// video_to_cnn_tb.v — 验证 video_to_cnn 降采样 + 双时钟 ERAM 读回 + O_start 时序
//
// 策略:把 IMG_W/IMG_H 覆盖成 448x448,使 ROI(28*16=448)刚好铺满整帧,
//       仿真量 ~22 万拍/帧(真实 1280x720 太长)。
// 图案:bin(r,c) 的 256 个像素统一填**二值**图案 ((i%5)<2) ? 0xFF : 0x00,i = r*28+c。
//       为什么不再是原来的 8 位渐变 (i & 0xFF):
//       bin 预处理新增了「极性 -> 量程拉伸 -> 二值化」,输出恒为 0/255,
//       8 位渐变图案会被打成二值,原有期望值不再成立。
//       二值图案经拉伸+阈值后**不变**(见下),所以期望仍是确定的:
//           INVERT=0 => p = raw ∈ {0,255};lo=0, hi=255, rng=255, 中点=127
//           out = (p-0) > 127 ? 255 : 0  =>  0->0, 255->255   (恒等)
//       周期取 5 而不是 2:28 % 5 = 3 ≠ 0,所以「整行错位一格 bin」会改变图案,
//       而周期 2/4/7 会被 28 整除,行错位后图案不变 —— 那样的图案测不出行错位。
//
// 本 TB 覆盖:读写总线对齐、行列顺序、O_start 与最后一次写不同拍(上板时
// 整体错位只表现为识别异常,很难察觉)。**预处理算术本身的正确性**由
// video_to_cnn_frame_tb.v(真实 1280x720 + Python 生成的帧 + 离线逐字节比对)覆盖。
`timescale 1ns/1ps
module video_to_cnn_tb;

    localparam W = 448;
    localparam H = 448;

    reg clk_pix = 0;    // 75MHz
    reg clk_cnn = 0;    // 100MHz
    reg rst_pix_n, rst_cnn_n;

    reg  [23:0] vdata;
    reg         de, user, last;
    wire        img_wr_en;
    wire [9:0]  img_wr_addr;
    wire [7:0]  img_wr_data;
    wire        start;
    wire        prev_we;
    wire [9:0]  prev_addr;
    wire [7:0]  prev_data;
    reg         cnn_done;

    // INVERT 显式写 0:TB 用的是"合成图案"本身已经是 MNIST 极性,不需要反色。
    // (RTL 的默认值已改为 1,是给真实摄像头的白纸黑字用的 —— 所以这里必须显式覆盖,
    //  否则整个 TB 期望值全错。)
    video_to_cnn #(.IMG_W(W), .IMG_H(H), .INVERT(0)) uut (
        .I_clk_pix     (clk_pix),
        .I_rst_pix_n   (rst_pix_n),
        .I_video_de    (de),
        .I_video_user  (user),
        .I_video_last  (last),
        .I_video_data  (vdata),
        .I_clk_cnn     (clk_cnn),
        .I_rst_cnn_n   (rst_cnn_n),
        .I_cnn_done    (cnn_done),
        .O_img_wr_en   (img_wr_en),
        .O_img_wr_addr (img_wr_addr),
        .O_img_wr_data (img_wr_data),
        .O_start       (start),
        .O_prev_we     (prev_we),
        .O_prev_addr   (prev_addr),
        .O_prev_data   (prev_data)
    );

    // 75MHz ≈ 13.333ns 周期;100MHz = 10ns
    always #6.667 clk_pix = ~clk_pix;
    always #5     clk_cnn = ~clk_cnn;

    // 捕获写入的 784 字节(按地址落位)
    reg [7:0] cap [0:783];
    integer   wr_cnt = 0;
    always @(posedge clk_cnn) begin
        if (img_wr_en && wr_cnt < 784) begin
            cap[img_wr_addr] <= img_wr_data;
            wr_cnt = wr_cnt + 1;
        end
    end

    // 屏幕预览口:同一份字节的 75MHz 副本。捕获下来与 CNN 口逐字节比对 ——
    // 预览图显示的必须**就是**喂进 CNN 的那份数据,否则诊断会误导。
    reg [7:0] pcap [0:783];
    integer   pwr_cnt = 0;
    always @(posedge clk_pix) begin
        if (prev_we) begin
            if (pwr_cnt < 784) pcap[prev_addr] <= prev_data;
            pwr_cnt = pwr_cnt + 1;
        end
    end

    // 调试:按时间顺序记录每一次写(定位地址重复/跳变)
    reg [9:0] waddr_log [0:2047];
    reg [7:0] wdata_log [0:2047];
    integer   nwr = 0;
    always @(posedge clk_cnn) begin
        if (img_wr_en) begin
            if (nwr < 2048) begin
                waddr_log[nwr] = img_wr_addr;
                wdata_log[nwr] = img_wr_data;
            end
            nwr = nwr + 1;
        end
    end

    // 模拟 CNN 推理完成:收到 O_start 后延迟若干拍回 I_cnn_done
    always @(posedge clk_cnn) begin
        if (rst_cnn_n && start) begin
            repeat (10) @(posedge clk_cnn);
            cnn_done <= 1'b1;
            @(posedge clk_cnn);
            cnn_done <= 1'b0;
        end
    end

    // 二值图案:周期 5(28 % 5 = 3,行错位会改变图案)
    function [7:0] gray_of;
        input integer x, y;
        integer idx;
        begin
            idx = ((y >> 4) * 28) + (x >> 4);
            gray_of = ((idx % 5) < 2) ? 8'hFF : 8'h00;
        end
    endfunction

    function [7:0] expect_of;      // 预处理后的期望值(见文件头推导:二值图案不变)
        input integer idx;
        begin
            expect_of = ((idx % 5) < 2) ? 8'hFF : 8'h00;
        end
    endfunction

    integer i, x, y, err, perr;
    reg [7:0] expct;

    initial begin
        rst_pix_n = 0; rst_cnn_n = 0;
        de = 0; user = 0; last = 0; vdata = 24'd0; cnn_done = 0;
        for (i = 0; i < 784; i = i + 1) cap[i] = 8'hxx;
        for (i = 0; i < 784; i = i + 1) pcap[i] = 8'hxx;

        repeat (8) @(posedge clk_pix);
        rst_pix_n = 1;
        repeat (8) @(posedge clk_pix);
        rst_cnn_n = 1;
        repeat (20) @(posedge clk_pix);

        // ---- 发一帧 448x448 ----
        user = 1; @(posedge clk_pix); user = 0;
        for (y = 0; y < H; y = y + 1) begin
            for (x = 0; x < W; x = x + 1) begin
                de    = 1;
                vdata = {8'h00, gray_of(x, y), 8'h00};   // G 通道 = 图案
                @(posedge clk_pix);
            end
            de   = 0;
            last = 1; @(posedge clk_pix); last = 0;
            repeat (48) @(posedge clk_pix);              // 行消隐(>flush 28 拍)
        end

        // 等 100MHz 侧读回 + 写完
        repeat (4000) @(posedge clk_cnn);

        // ---- 比对 ----
        err = 0;
        perr = 0;
        for (i = 0; i < 784; i = i + 1) begin
            expct = expect_of(i);
            if (cap[i]  !== expct) err  = err  + 1;
            if (pcap[i] !== expct) perr = perr + 1;
        end

        $display("================ video_to_cnn TB ================");
        $display("  captured writes = %0d   total en pulses = %0d", wr_cnt, nwr);
        $display("  -- write sequence (first 8) --");
        for (i = 0; i < 8; i = i + 1)
            $display("    #%0d addr=%0d data=0x%h", i, waddr_log[i], wdata_log[i]);
        $display("  -- write sequence (last 8) --");
        for (i = nwr-8; i < nwr; i = i + 1)
            $display("    #%0d addr=%0d data=0x%h", i, waddr_log[i], wdata_log[i]);
        if (err == 0) begin
            $display("  PASS: all 784 bytes match expected pattern");
        end else begin
            $display("  FAIL: %0d / 784 bytes mismatched", err);
            for (i = 0; i < 784; i = i + 1) begin
                expct = expect_of(i);
                if (cap[i] !== expct)
                    $display("    idx %0d: got 0x%h  exp 0x%h", i, cap[i], expct);
            end
        end
        if (perr == 0 && pwr_cnt == 784)
            $display("  PASS: preview port carries the same 784 bytes");
        else
            $display("  FAIL: preview port %0d bytes, %0d mismatched", pwr_cnt, perr);
        $display("================================================");
        $finish;
    end

endmodule
