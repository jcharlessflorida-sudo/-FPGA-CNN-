// video_to_cnn_frame_tb.v — 用**真实 1280x720 帧 + 默认参数**验证 bin 预处理算术
//
// 与 video_to_cnn_tb.v 的分工:
//   video_to_cnn_tb.v      : 覆盖 IMG 尺寸,用合成二值图案测**地址/行列/时序**。
//   本 TB                   : **不覆盖任何参数**(IMPORTANT:INVERT/IMG_W/IMG_H/ROI_SZ/
//                            BIN_TH/MIN_RANGE 全部走默认值,即上板实际配置),
//                            喂 a/frame_gen.py 生成的真实帧,把 RTL 输出的 784 字节
//                            写到 sim/v2c_out.mem,由 a/check_v2c_frame.py 与 Python
//                            参考模型逐字节比对。
//
// 关键点:预处理里的对比度拉伸用的是**上一帧**的 lo/hi。所以本 TB 连发**两帧相同内容**,
//   只捕获第 2 帧 —— 此时 S_prev_lo/hi == 本帧自己的 min/max,与 Python 参考模型的
//   单帧语义完全一致。只发一帧的话,第 1 帧走的是复位初值(lo=0,hi=255,不拉伸),
//   两边必然对不上,那是**假失败**。
//
// 复位后的捕获:第 1 帧的读回(img_wr_en 的 784 个脉冲)必须丢弃,用 cap_en 门控。
`timescale 1ns/1ps
module video_to_cnn_frame_tb;

    localparam W = 1280;
    localparam H = 720;
    localparam BLANK = 64;          // 行消隐拍数(> flush 需要的 29 拍)

    reg clk_pix = 0;                // 75MHz
    reg clk_cnn = 0;                // 100MHz
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

    // 不传任何参数:测的就是上板实际配置
    video_to_cnn uut (
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

    always #6.667 clk_pix = ~clk_pix;
    always #5     clk_cnn = ~clk_cnn;

    // ---- 真实帧 ----
    reg [7:0] frame [0:W*H-1];
    initial $readmemh("sim/frame720p.mem", frame);

    // ---- 捕获 CNN 口的 784 字节 ----
    reg        cap_en = 0;
    reg [7:0]  cap [0:783];
    reg        seen [0:783];
    integer    wr_cnt = 0;
    always @(posedge clk_cnn) begin
        if (cap_en && img_wr_en && wr_cnt < 784) begin
            cap[img_wr_addr]  <= img_wr_data;
            seen[img_wr_addr] <= 1'b1;
            wr_cnt = wr_cnt + 1;
        end
    end

    // ---- 捕获预览口(75MHz 域)的同 784 字节 ----
    reg [7:0] pcap [0:783];
    integer   pwr_cnt = 0;
    always @(posedge clk_pix) begin
        if (cap_en && prev_we && pwr_cnt < 784) begin
            pcap[prev_addr] <= prev_data;
            pwr_cnt = pwr_cnt + 1;
        end
    end

    // 模拟 CNN:收到 O_start 后延迟若干拍回 I_cnn_done
    always @(posedge clk_cnn) begin
        if (rst_cnn_n && start) begin
            repeat (10) @(posedge clk_cnn);
            cnn_done <= 1'b1;
            @(posedge clk_cnn);
            cnn_done <= 1'b0;
        end
    end

    integer i, x, y, pmis, mis, dmp;
    integer wr_at_start = -1;

    task send_frame;
        begin
            user = 1; @(posedge clk_pix); user = 0;
            for (y = 0; y < H; y = y + 1) begin
                for (x = 0; x < W; x = x + 1) begin
                    de    = 1;
                    // 灰度放 G 通道 —— video_to_cnn 取 I_video_data[15:8]
                    vdata = {8'h00, frame[y*W + x], 8'h00};
                    @(posedge clk_pix);
                end
                de   = 0;
                last = 1; @(posedge clk_pix); last = 0;
                repeat (BLANK) @(posedge clk_pix);
            end
        end
    endtask

    initial begin
        rst_pix_n = 0; rst_cnn_n = 0;
        de = 0; user = 0; last = 0; vdata = 24'd0; cnn_done = 0;
        for (i = 0; i < 784; i = i + 1) begin
            cap[i]  = 8'hxx;
            pcap[i] = 8'hxx;
            seen[i] = 1'b0;
        end

        repeat (8) @(posedge clk_pix);
        rst_pix_n = 1;
        repeat (8) @(posedge clk_pix);
        rst_cnn_n = 1;
        repeat (20) @(posedge clk_pix);

        // ---- 第 1 帧:只用来建立 S_prev_lo/hi,不捕获 ----
        send_frame();
        repeat (4000) @(posedge clk_cnn);

        // ---- 第 2 帧:内容相同 -> 拉伸量程 == 本帧自身 min/max,捕获 ----
        cap_en = 1;
        send_frame();

        // 等读回 + O_start + I_cnn_done
        repeat (8000) @(posedge clk_cnn);
        cap_en = 0;
        repeat (200) @(posedge clk_cnn);

        // ---- 写出给 Python 比对 ----
        begin : dump
            integer fd;
            fd = $fopen("sim/v2c_out.mem", "w");
            if (fd == 0) begin
                $display("  ERROR: cannot open sim/v2c_out.mem");
            end else begin
                for (i = 0; i < 784; i = i + 1)
                    $fwrite(fd, "%02X\n", cap[i]);
                $fclose(fd);
                $display("  wrote sim/v2c_out.mem (784 bytes)");
            end
        end

        // ---- 自检:地址覆盖 / 预览一致 ----
        pmis = 0; mis = 0;
        for (i = 0; i < 784; i = i + 1) begin
            if (seen[i] !== 1'b1)   mis  = mis  + 1;
            if (pcap[i] !== cap[i]) pmis = pmis + 1;
        end

        // ModelSim 的 $display 对 UTF-8 支持很差(中文全变问号),这里一律用 ASCII。
        $display("============== video_to_cnn FRAME TB ==============");
        $display("  captured writes   = %0d   (expect 784)", wr_cnt);
        $display("  preview pulses    = %0d   (expect 784)", pwr_cnt);
        $display("  unwritten addrs   = %0d   (expect 0)", mis);
        $display("  preview != cnn    = %0d   (expect 0)", pmis);
        $display("  wr_cnt @ O_start  = %0d   (expect 784)", wr_at_start);
        if (pmis != 0) begin
            $display("  -- first preview mismatches --");
            i = 0; dmp = 0;
            while (i < 784 && dmp < 8) begin
                if (pcap[i] !== cap[i]) begin
                    $display("    addr %0d: cnn=0x%h preview=0x%h", i, cap[i], pcap[i]);
                    dmp = dmp + 1;
                end
                i = i + 1;
            end
        end
        if (wr_cnt == 784 && mis == 0 && pmis == 0 && wr_at_start == 784)
            $display("  PASS: capture / address-coverage / preview port / O_start timing");
        else
            $display("  FAIL: see counts above");
        $display("  note: byte VALUES are checked by a/check_v2c_frame.py on sim/v2c_out.mem");
        $display("==================================================");
        $finish;
    end

    // O_start 每帧都发一次,必须同样用 cap_en 门控,否则会记到第 1 帧那次(wr_cnt 还是 0)
    always @(posedge clk_cnn) if (cap_en && start && wr_at_start < 0) wr_at_start = wr_cnt;

endmodule
