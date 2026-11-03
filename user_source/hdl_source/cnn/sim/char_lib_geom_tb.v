// char_lib_geom_tb.v - 字模几何自检
// 目的:确认 A / M 的墨迹包围盒与 C / N 完全一致(宽体:行 2..12,列 2..13)。
// 背景:osd_char_lib.v 里曾混了两套字体 —— 数字/C/N/T 是 12 列宽体,A/M 等 23 个
//       字母是 5x8 窄体,导致 "CNN:12 CAM:59" 里 A/M 明显偏小、左偏、底边悬空。
// 位约定:O_row_bits 的 bit 15 = 该行最左像素,bit 0 = 最右像素。
`timescale 1ns/1ps
module char_lib_geom_tb;

  localparam integer WANT_RMIN = 2;
  localparam integer WANT_RMAX = 12;
  localparam integer WANT_CMIN = 2;    // 最低位(最右像素)
  localparam integer WANT_CMAX = 13;   // 最高位(最左像素)

  reg  [7:0]  ch;
  reg  [3:0]  row;
  wire [15:0] bits;

  osd_char_lib dut (
    .I_char     ( ch   ),
    .I_row      ( row  ),
    .O_row_bits ( bits )
  );

  integer r, b;
  integer rmin, rmax, cmin, cmax;
  integer errors;

  // 扫描当前 ch 的 16 行:打印 ASCII 图 + 算墨迹包围盒
  task scan;
    begin
      rmin = 99; rmax = -1; cmin = 99; cmax = -1;
      for (r = 0; r < 16; r = r + 1) begin
        row = r[3:0];
        #1;
        $write("    r%0d: ", r);
        for (b = 15; b >= 0; b = b - 1) begin
          if(bits[b]) $write("#"); else $write(".");
        end
        $write("   16'h%04h\n", bits);
        if(bits != 16'h0000) begin
          if(r < rmin) rmin = r;
          if(r > rmax) rmax = r;
          for (b = 0; b < 16; b = b + 1) begin
            if(bits[b]) begin
              if(b < cmin) cmin = b;
              if(b > cmax) cmax = b;
            end
          end
        end
      end
      $display("    bbox: rows %0d..%0d  cols %0d..%0d  (w=%0d h=%0d)",
               rmin, rmax, cmax, cmin, cmax-cmin+1, rmax-rmin+1);
    end
  endtask

  task expect_wide(input [7:0] c, input [63:0] name);
    begin
      ch = c;
      #1;
      $display("\n=== %0s (8'h%02x) ===", name, c);
      scan;
      if(rmin != WANT_RMIN || rmax != WANT_RMAX ||
         cmin != WANT_CMIN || cmax != WANT_CMAX) begin
        $display("    *** FAIL: %0s 墨迹框 != 宽体标准 (rows %0d..%0d, cols %0d..%0d) ***",
                 name, WANT_RMIN, WANT_RMAX, WANT_CMIN, WANT_CMAX);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    errors = 0;

    // A / M 必须与 C / N 落在同一墨迹框里
    expect_wide(8'h43, "C");
    expect_wide(8'h4e, "N");
    expect_wide(8'h41, "A");
    expect_wide(8'h4d, "M");

    // 顺手打印数字,确认基线也在第 12 行
    ch = 8'h35; #1; $display("\n=== 5 (reference) ==="); scan;
    ch = 8'h39; #1; $display("\n=== 9 (reference) ==="); scan;

    $display("");
    if(errors == 0) $display("CHAR_LIB_GEOM_TB: PASS");
    else            $display("CHAR_LIB_GEOM_TB: FAIL (%0d errors)", errors);
    $finish;
  end

endmodule
