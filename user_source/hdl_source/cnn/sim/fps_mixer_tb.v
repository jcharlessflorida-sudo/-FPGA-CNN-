// fps_mixer_tb.v - FPS 显示逻辑的仿真验证(只测 hdmi_mixer 内部,不测顶层 CDC)
//
// 覆盖:
//   1) 1 秒门控 + 脉冲累加 + 二进制转 BCD(把 FPS_GATE_MAX 调成 1000 快速跑)
//      期望:窗口内 12 个 cam / 7 个 cnn -> "12"/"07";99/99 -> "99"/"99";
//            120/120 -> 钳位成 "99"/"99"。
//   2) FPS 框渲染:笔画像素 = COLOR_FPS(24'hff8800);
//      框内非笔画 = 视频>>1(24'h808080>>1 = 24'h404040);框外 = 原视频 24'h808080。
//
// 说明:跨时钟域的"脉冲->翻转->3级同步->异或边沿检测"位于 design_top_wrapper,
//       跑它需要整颗 SoC(含 MIPI/DDR/ISP),ModelSim 里不现实。这里直接喂已同步好的
//       单周期脉冲,只验证 mixer 侧的门控/计数/BCD/渲染。CDC 那段是 video_to_cnn.v
//       里已验证过的同款写法。
`timescale 1ns/1ps
module fps_mixer_tb;

  // 与 hdmi_mixer.v 里的 FPS_BOX_* 保持一致(改动时同步)
  localparam [11:0] BOX_X = 12'd32;
  localparam [11:0] BOX_Y = 12'd640;
  localparam [11:0] BOX_W = 12'd448;
  localparam [11:0] BOX_H = 12'd48;
  localparam [23:0] C_FPS  = 24'hff8800;
  localparam [23:0] C_RAW  = 24'h808080;

  localparam integer GATE = 1000;          // 小门控便于仿真

  reg         clk = 0;
  reg         rst_n;
  reg         v_user, v_de, v_last, v_vs, v_hs;
  reg  [23:0] v_data;
  reg         cam_p, cnn_p;
  wire        rd_en;
  wire        o_vs, o_hs, o_de;
  wire [23:0] o_data;

  hdmi_mixer #(
    .DEBUG_MODE   ( 0    ),
    .FPS_GATE_MAX ( GATE )
  ) dut (
    .I_clk           ( clk     ),
    .I_rst_n         ( rst_n   ),
    .I_video_vsync   ( v_vs    ),
    .I_video_hsync   ( v_hs    ),
    .I_video_de      ( v_de    ),
    .I_video_user    ( v_user  ),
    .I_video_last    ( v_last  ),
    .I_debug_status  ( 4'd0    ),
    .I_fps_cam_pulse ( cam_p   ),
    .I_fps_cnn_pulse ( cnn_p   ),
    .I_thumb_we      ( 1'b0    ),
    .I_thumb_addr    ( 10'd0   ),
    .I_thumb_data    ( 8'd0    ),
    .O_video_rd_en   ( rd_en   ),
    .I_video_rd_data ( v_data  ),
    .O_hdmi_vsync    ( o_vs    ),
    .O_hdmi_hsync    ( o_hs    ),
    .O_hdmi_de       ( o_de    ),
    .O_hdmi_data     ( o_data  )
  );

  always #5 clk = ~clk;

  // ---- 全局拍计数(复位释放后从 0 起)----
  integer cyc;
  always @(posedge clk) begin
    if(!rst_n) cyc <= 0;
    else       cyc <= cyc + 1;
  end

  // ---- 脉冲注入(与门控窗口对齐;窗口 = 1000 拍)----
  // 窗口1: cyc 100..122 偶数 -> 12 个 cam;cyc 200..212 偶数 -> 7 个 cnn
  // 窗口2: cyc 1200..1298 连续高 -> 99 个 cam;1300..1398 -> 99 个 cnn
  // 窗口3: cyc 2200..2319 连续高 -> 120 个 cam;2400..2519 -> 120 个 cnn(应钳成 99)
  always @(posedge clk) begin
    cam_p <= 1'b0;
    cnn_p <= 1'b0;
    if(rst_n) begin
      if(cyc >= 100 && cyc < 124 && ((cyc-100) % 2 == 0)) cam_p <= 1'b1;
      if(cyc >= 200 && cyc < 214 && ((cyc-200) % 2 == 0)) cnn_p <= 1'b1;
      if(cyc >= 1200 && cyc < 1299) cam_p <= 1'b1;
      if(cyc >= 1300 && cyc < 1399) cnn_p <= 1'b1;
      if(cyc >= 2200 && cyc < 2320) cam_p <= 1'b1;
      if(cyc >= 2400 && cyc < 2520) cnn_p <= 1'b1;
    end
  end

  // ---- TB 侧复刻 S_x/S_y(与 DUT 同递推),再延迟 4 拍对齐 O_hdmi_data ----
  reg [11:0] tbx, tby;
  always @(posedge clk) begin
    if(!rst_n)      begin tbx <= 12'd0; tby <= 12'd0; end
    else if(v_user) begin tbx <= 12'd0; tby <= 12'd0; end
    else if(v_de) begin
      if(v_last) begin tbx <= 12'd0; tby <= tby + 12'd1; end
      else       begin tbx <= tbx + 12'd1; end
    end
  end

  reg [11:0] qx0,qx1,qx2,qx3, qy0,qy1,qy2,qy3;
  always @(posedge clk) begin
    qx0 <= tbx; qx1 <= qx0; qx2 <= qx1; qx3 <= qx2;
    qy0 <= tby; qy1 <= qy0; qy2 <= qy1; qy3 <= qy2;
  end

  // ---- 输出颜色统计 ----
  // 无背景版:框内每个像素要么是橙色笔画(COLOR_FPS),要么是原样透传的视频(C_RAW);
  // 不应出现第三种颜色。按 4 拍延迟对齐后的坐标判定"是否落在 FPS 框内"。
  integer n_fps, n_raw, n_box_total, n_box_fps, n_box_raw, n_box_other;
  always @(posedge clk) begin
    if(o_de) begin
      if(o_data == C_FPS) n_fps <= n_fps + 1;
      if(o_data == C_RAW) n_raw <= n_raw + 1;
      if((qx3 >= BOX_X) && (qx3 < (BOX_X + BOX_W)) &&
         (qy3 >= BOX_Y) && (qy3 < (BOX_Y + BOX_H))) begin
        n_box_total <= n_box_total + 1;
        if(o_data == C_FPS)      n_box_fps   <= n_box_fps + 1;
        else if(o_data == C_RAW) n_box_raw   <= n_box_raw + 1;
        else                     n_box_other <= n_box_other + 1;
      end
    end
  end

  integer errors;
  integer yy, xx;

  task check_bcd(input [8*24-1:0] tag, input [3:0] et1, input [3:0] et0,
                 input [3:0] ec1, input [3:0] ec0);
    begin
      $display("[%0s] cam=%0d%0d (exp %0d%0d)  cnn=%0d%0d (exp %0d%0d)",
               tag, dut.S_fps_cam_d1, dut.S_fps_cam_d0, et1, et0,
               dut.S_fps_cnn_d1, dut.S_fps_cnn_d0, ec1, ec0);
      if(dut.S_fps_cam_d1 !== et1 || dut.S_fps_cam_d0 !== et0 ||
         dut.S_fps_cnn_d1 !== ec1 || dut.S_fps_cnn_d0 !== ec0) begin
        $display("  *** FAIL: BCD mismatch ***");
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    errors = 0;
    n_fps = 0; n_raw = 0; n_box_total = 0; n_box_fps = 0; n_box_raw = 0; n_box_other = 0;
    rst_n = 0; v_user = 0; v_de = 0; v_last = 0; v_vs = 0; v_hs = 0;
    v_data = C_RAW; cam_p = 0; cnn_p = 0;

    repeat(5) @(posedge clk);
    rst_n = 1;

    // ---------- 阶段 A:门控/计数/BCD ----------
    wait(cyc >= 1050);
    check_bcd("win1", 4'd1, 4'd2, 4'd0, 4'd7);

    wait(cyc >= 2050);
    check_bcd("win2", 4'd9, 4'd9, 4'd9, 4'd9);

    wait(cyc >= 3050);
    check_bcd("win3", 4'd9, 4'd9, 4'd9, 4'd9);   // 120 钳到 99

    // ---------- 阶段 B:渲染 ----------
    wait(cyc >= 3200);
    // 帧起始
    @(posedge clk); v_user <= 1'b1;
    @(posedge clk); v_user <= 1'b0;
    // y = 0..639:每行 1 拍(只为快速推进 S_y),之后 S_y 落在 640
    for(yy = 0; yy < 640; yy = yy + 1) begin
      v_de <= 1'b1; v_last <= 1'b1;
      @(posedge clk);
    end
    // y = 640..687:FPS 框所在行,逐像素扫过
    for(yy = 0; yy < 48; yy = yy + 1) begin
      for(xx = 0; xx < 1280; xx = xx + 1) begin
        v_de   <= 1'b1;
        v_last <= (xx == 1279);
        @(posedge clk);
      end
    end
    v_de <= 1'b0; v_last <= 1'b0;
    repeat(8) @(posedge clk);

    // ---------- 汇总 ----------
    // 无背景版:框内只应有"橙色笔画"和"透传视频"两种像素。
    $display("");
    $display("render: n_fps=%0d n_box_total=%0d n_box_fps=%0d n_box_raw=%0d n_box_other=%0d n_raw=%0d",
             n_fps, n_box_total, n_box_fps, n_box_raw, n_box_other, n_raw);
    if(n_fps == 0) begin $display("  *** FAIL: 没画到任何笔画像素 ***"); errors = errors + 1; end
    if(n_box_fps == 0) begin $display("  *** FAIL: 框内没有笔画 ***"); errors = errors + 1; end
    if(n_box_other != 0) begin
      $display("  *** FAIL: 框内有 %0d 个像素既不是笔画也不是透传视频 ***", n_box_other);
      errors = errors + 1;
    end
    // 448x48 = 21504;坐标按 4 拍对齐,允许少量边缘误差
    if(n_box_total < (448*48 - 64) || n_box_total > (448*48 + 64)) begin
      $display("  *** FAIL: 框内统计像素 %0d,与框面积 21504 差太多 ***", n_box_total);
      errors = errors + 1;
    end
    if(n_raw == 0) begin $display("  *** FAIL: 框外视频没有被透传 ***"); errors = errors + 1; end

    $display("");
    if(errors == 0) $display("FPS_MIXER_TB: PASS");
    else            $display("FPS_MIXER_TB: FAIL (%0d errors)", errors);
    $finish;
  end

endmodule
