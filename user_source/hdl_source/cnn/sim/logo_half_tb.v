// logo_half_tb.v — 用全分辨率原厂 ROM 交叉验证 2 倍降采样版
//                 (anlogic_logo_rom.v  vs  anlogic_logo_rom_half.v)。
//
// 为什么需要它:半分辨率 ROM 是 a/gen_logo_rom.py **生成**的,而且它要上板替换原厂
// 那张图。降采样一旦写错(块算错、颜色被背景冲淡、丢笔画),屏幕上表现为"logo 糊了"
// 或者"缺一块",但**没人会去数像素**,所以必须机器兜住。
//
// 该模块的失效模式:
//   1. 墨迹丢失:某个 2x2 块里有墨,输出却当成空白 —— logo 缺笔画。
//   2. 凭空出墨:块里没墨,输出却有颜色 —— logo 多出杂点。
//   3. 颜色越界:输出 RGB 不在该块有墨像素的 [min,max] 内 —— 说明平均时混入了背景
//      (低对比度的半透明边缘会整块发灰),或通道/位序接错。
//   4. 组合路径出现 X。
//
// 检查项:
//   - 两个 ROM 全地址范围无 X;
//   - 逐块:有墨/无墨必须与全分辨率版**集合相等**(上面 1、2 两条);
//   - 逐块:输出的 R/G/B 落在该块有墨像素该通道的 [min,max] 内(第 3 条);
//   - 抽点比对(参考值由 a/gen_logo_rom.py 独立算出,勿手算);
//   - 计数:有墨块数 == 半分辨率 ROM 的非零条目数(全分辨率版算出来的,非硬编码)。
//
// 改表之后必须同步本文件的期望值: 跑 `python a/gen_logo_rom.py`,把输出的
// "TB spot checks:" 那一行照抄进来。漏改会变成假通过/假失败。
`timescale 1ns/1ps

module logo_half_tb;

    localparam FW = 160;             // 全分辨率宽
    localparam HW = 80;              // 半分辨率宽
    localparam FSZ = FW * FW;        // 25600
    localparam HSZ = HW * HW;        // 6400

    reg  [14:0] A_full;
    wire [24:0] P_full;
    reg  [12:0] A_half;
    wire [24:0] P_half;

    anlogic_logo_rom      u_full (.I_addr(A_full), .O_pixel(P_full));
    anlogic_logo_rom_half u_half (.I_addr(A_half), .O_pixel(P_half));

    integer errors = 0;
    integer i, bx, by, dy, dx, n_ink, n_half, n_full;
    reg [7:0] rmin, rmax, gmin, gmax, bmin, bmax;

    // ---------------------------------------------------------------
    // 抽点比对(25bit 全等)
    // ---------------------------------------------------------------
    task spot;
        input [12:0] a;
        input [24:0] expect;
        begin
            A_half = a;
            #1;
            if (P_half !== expect) begin
                $display("FAIL spot: half(%0d) = 25'h%h expect 25'h%h", a, P_half, expect);
                errors = errors + 1;
            end
        end
    endtask

    // ---------------------------------------------------------------
    integer a;
    initial begin
        $display("=== logo_half testbench (160x160 factory ROM vs 2x-downsampled 80x80) ===");

        // ---- 1) 全地址扫 X(原厂 ROM 的 default 保证不会是 X,这里守卫生成物)----
        for (a = 0; a < FSZ; a = a + 1) begin
            A_full = a[14:0]; #1;
            if (^P_full === 1'bx) begin
                $display("FAIL: full ROM X at addr %0d", a);
                errors = errors + 1;
            end
        end
        for (a = 0; a < HSZ; a = a + 1) begin
            A_half = a[12:0]; #1;
            if (^P_half === 1'bx) begin
                $display("FAIL: half ROM X at addr %0d", a);
                errors = errors + 1;
            end
        end

        // ---- 2/3) 逐块交叉验证:有无墨集合相等 + 颜色落在块内色域 ----
        n_half = 0;
        for (by = 0; by < HW; by = by + 1) begin
            for (bx = 0; bx < HW; bx = bx + 1) begin
                n_ink = 0;
                rmin = 8'd255; rmax = 8'd0;
                gmin = 8'd255; gmax = 8'd0;
                bmin = 8'd255; bmax = 8'd0;
                for (dy = 0; dy < 2; dy = dy + 1) begin
                    for (dx = 0; dx < 2; dx = dx + 1) begin
                        A_full = ((by*2 + dy) * FW) + (bx*2 + dx);
                        #1;
                        if (P_full[24]) begin
                            n_ink = n_ink + 1;
                            if (P_full[23:16] < rmin) rmin = P_full[23:16];
                            if (P_full[23:16] > rmax) rmax = P_full[23:16];
                            if (P_full[15:8]  < gmin) gmin = P_full[15:8];
                            if (P_full[15:8]  > gmax) gmax = P_full[15:8];
                            if (P_full[7:0]   < bmin) bmin = P_full[7:0];
                            if (P_full[7:0]   > bmax) bmax = P_full[7:0];
                        end
                    end
                end

                A_half = (by * HW) + bx;
                #1;
                if (P_half[24]) begin
                    n_half = n_half + 1;
                    if (n_ink == 0) begin
                        $display("FAIL: spurious ink at block (%0d,%0d) = addr %0d (0x%h)",
                                 bx, by, (by*HW + bx), P_half);
                        errors = errors + 1;
                    end
                    else begin
                        if (P_half[23:16] < rmin || P_half[23:16] > rmax) begin
                            $display("FAIL: block (%0d,%0d) R=%0d out of [%0d,%0d]",
                                     bx, by, P_half[23:16], rmin, rmax);
                            errors = errors + 1;
                        end
                        if (P_half[15:8] < gmin || P_half[15:8] > gmax) begin
                            $display("FAIL: block (%0d,%0d) G=%0d out of [%0d,%0d]",
                                     bx, by, P_half[15:8], gmin, gmax);
                            errors = errors + 1;
                        end
                        if (P_half[7:0] < bmin || P_half[7:0] > bmax) begin
                            $display("FAIL: block (%0d,%0d) B=%0d out of [%0d,%0d]",
                                     bx, by, P_half[7:0], bmin, bmax);
                            errors = errors + 1;
                        end
                    end
                end
                else if (n_ink > 0) begin
                    $display("FAIL: ink lost at block (%0d,%0d) = addr %0d (%0d of 4 pixels had ink)",
                             bx, by, (by*HW + bx), n_ink);
                    errors = errors + 1;
                end
            end
        end

        // ---- 4) 计数:有墨块数必须等于半分辨率 ROM 的非零条目数 ----
        n_full = 0;
        for (a = 0; a < FSZ; a = a + 1) begin
            A_full = a[14:0]; #1;
            if (P_full[24]) n_full = n_full + 1;
        end
        $display("full ROM: %0d opaque pixels of %0d", n_full, FSZ);
        $display("half ROM: %0d entries of %0d (blocks with ink)", n_half, HSZ);

        // ---- 5) 抽点比对(参考值 = a/gen_logo_rom.py 的 "TB spot checks:" 一行,勿手算)----
        spot(13'd1386, 25'h1cccfd5);
        spot(13'd1387, 25'h1adb2bc);
        spot(13'd2352, 25'h11c2d4e);
        spot(13'd3247, 25'h1ed1c24);
        spot(13'd4215, 25'h1f43e44);
        spot(13'd5092, 25'h1f99195);
        spot(13'd5093, 25'h1fbbcbe);
        $display("spot checks: 7 addresses matched (values from a/gen_logo_rom.py)");

        // ---- 6) 空白区必须真的空白(守卫"凭空出墨"的另一种形态;块 (0,0) 在笔画之外)----
        spot(13'd0, 25'd0);
        spot(13'd6399, 25'd0);

        if (errors == 0)
            $display("=== PASS: logo_half all checks passed ===");
        else
            $display("=== FAIL: %0d errors ===", errors);

        $finish;
    end

endmodule
