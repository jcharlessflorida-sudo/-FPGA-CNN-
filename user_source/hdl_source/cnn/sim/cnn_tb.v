// cnn_tb.v — 载入测试图,运行推理,把 class 与 10 个 logits 写入 sim_logits.txt
// 从 sim/tb_images.mem 读取 N*784 字节测试图(需与 quantize_export.py 的 N_TEST 一致)
`timescale 1ns/1ps
module cnn_tb;

  localparam N = 100;   // 必须等于 quantize_export.py 的 N_TEST

  reg         clk = 0;
  reg         rst_n;
  reg         start;
  reg         img_wr_en;
  reg  [9:0]  img_wr_addr;
  reg  [7:0]  img_wr_data;
  wire        done;
  wire [3:0]  cls;
  wire [319:0] logits;

  cnn_top uut (
    .I_clk(clk), .I_rst_n(rst_n), .I_start(start),
    .I_img_wr_en(img_wr_en), .I_img_wr_addr(img_wr_addr), .I_img_wr_data(img_wr_data),
    .O_done(done), .O_class(cls), .O_logits(logits)
  );

  reg [7:0] imgs [0:N*784-1];
  integer fp_out, img_idx, i, j;
  reg signed [31:0] logit_val;

  initial begin
    $readmemh("sim/tb_images.mem", imgs);
  end

  always #5 clk = ~clk;   // 100 MHz

  initial begin
    rst_n = 0; start = 0; img_wr_en = 0; img_wr_addr = 0; img_wr_data = 0;
    fp_out = $fopen("sim/sim_logits.txt", "w");
    if (fp_out == 0) begin
      $display("ERROR: cannot open sim/sim_logits.txt");
      $finish;
    end

    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    for (img_idx = 0; img_idx < N; img_idx = img_idx + 1) begin
      // 写入 784 字节输入图
      for (i = 0; i < 784; i = i + 1) begin
        img_wr_en   <= 1;
        img_wr_addr <= i[9:0];
        img_wr_data <= imgs[img_idx*784 + i];
        @(posedge clk);
      end
      img_wr_en <= 0;
      @(posedge clk);

      // 启动推理
      start <= 1;
      @(posedge clk);
      start <= 0;

      // 等待完成脉冲
      @(posedge done);

      // 输出结果
      $fwrite(fp_out, "%0d %0d", img_idx, cls);
      for (j = 0; j < 10; j = j + 1) begin
        logit_val = $signed(logits[j*32 +: 32]);
        $fwrite(fp_out, " %0d", logit_val);
      end
      $fwrite(fp_out, "\n");
      @(posedge clk);
    end

    $fclose(fp_out);
    $display("TB finished %0d images", N);
    $finish;
  end

endmodule
