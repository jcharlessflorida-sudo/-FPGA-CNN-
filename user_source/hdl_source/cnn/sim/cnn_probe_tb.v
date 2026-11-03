// cnn_probe_tb.v - 临时探针:只跑一张图,把 ST_ARGMAX 的扫描过程逐拍打出来。
// 目的:判定 sim_logits.txt 里第 18 张图 cls=3(而 logits 与 Python 参考逐位相同、
// 真实 argmax 是 8)到底是 RTL 的 argmax 有问题,还是 cnn_tb.v 在 done 沿采样出竞态。
`timescale 1ns/1ps
module cnn_probe_tb;

  localparam IMG_FIRST = 15;
  localparam IMG_LAST  = 21;

  reg          clk = 0;
  reg          rst_n, start, img_wr_en;
  reg  [9:0]   img_wr_addr;
  reg  [7:0]   img_wr_data;
  wire         done;
  wire [3:0]   cls;
  wire [319:0] logits;

  cnn_top uut (
    .I_clk(clk), .I_rst_n(rst_n), .I_start(start),
    .I_img_wr_en(img_wr_en), .I_img_wr_addr(img_wr_addr), .I_img_wr_data(img_wr_data),
    .O_done(done), .O_class(cls), .O_logits(logits)
  );

  reg [7:0] imgs [0:100*784-1];
  integer i, j, img_idx;
  reg     watch;
  reg signed [31:0] lv;

  initial $readmemh("sim/tb_images.mem", imgs);

  always #5 clk = ~clk;

  // ST_ARGMAX 逐拍监视(只在目标图那几轮打,免得刷屏)
  always @(posedge clk) begin
    if (rst_n && uut.state == 3'd5 && watch) begin
      lv = $signed(uut.logit_mem[uut.c_am[3:0]]);
      $display("    SCAN c_am=%0d logit=%0d  max_val=%0d max_idx=%0d  win=%0d",
               uut.c_am, lv, $signed(uut.max_val), uut.max_idx,
               (lv > $signed(uut.max_val)));
    end
  end

  initial begin
    watch = 0;
    rst_n = 0; start = 0; img_wr_en = 0; img_wr_addr = 0; img_wr_data = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    for (img_idx = IMG_FIRST; img_idx <= IMG_LAST; img_idx = img_idx + 1) begin
      // 与 cnn_tb.v 完全相同的写入/启动/等待时序
      for (i = 0; i < 784; i = i + 1) begin
        img_wr_en   <= 1;
        img_wr_addr <= i[9:0];
        img_wr_data <= imgs[img_idx*784 + i];
        @(posedge clk);
      end
      img_wr_en <= 0;
      @(posedge clk);

      start <= 1;
      @(posedge clk);
      start <= 0;

      watch = (img_idx == 18);
      @(posedge done);
      $display("img %0d : 采样到的 cls=%0d   RTL max_idx=%0d max_val=%0d",
               img_idx, cls, uut.max_idx, $signed(uut.max_val));
      if (img_idx == 18) begin
        $display("  logit_mem: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                 $signed(uut.logit_mem[0]), $signed(uut.logit_mem[1]),
                 $signed(uut.logit_mem[2]), $signed(uut.logit_mem[3]),
                 $signed(uut.logit_mem[4]), $signed(uut.logit_mem[5]),
                 $signed(uut.logit_mem[6]), $signed(uut.logit_mem[7]),
                 $signed(uut.logit_mem[8]), $signed(uut.logit_mem[9]));
      end
      watch = 0;
      @(posedge clk);
    end

    $display("probe done");
    $finish;
  end

endmodule
