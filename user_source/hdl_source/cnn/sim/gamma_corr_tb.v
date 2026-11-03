// gamma_corr_tb.v — 验证显示 gamma 校正模块(纯组合,无时钟)。
//
// 该模块的失效模式(上板都不易察觉,必须仿真兜住):
//   1. 通道错位: R/G/B 的位切片接反(例如 R 查了 B 的表)—— 画面整体偏色。
//   2. 表损坏: 端点被破坏(gam(0)!=0 黑场被抬起;gam(255)!=255 白场被削)。
//   3. 非单调: 曲线回勾 → 图像出现反相/色带。
//   4. 组合路径出现 X(未初始化/多驱动)。
//
// 检查项:
//   - 逐通道全量扫 0..255: 无 X、单调不减;
//   - 端点严格保持: gam(0)=0, gam(255)=255;
//   - 黑电平段(0..BLACK_LEVEL)必须严格为 0 —— 这是第 2 轮修复("偏灰白")的
//     回归守卫: 旧版只有 gamma,gam(16) 高达 72,本该全黑的像素被抬成中灰;
//   - 抽点比对(参考值由 Python 独立算出,见 a/gen_gamma.py 的公式);
//   - 三通道同时给不同值,验证互不串扰。
//
// 改表之后必须同步本文件的期望值: 跑 `python -I gen_gamma.py`,把输出的
// "TB spot checks:" 那一行照抄进来。漏改会变成假通过/假失败。
`timescale 1ns/1ps

module gamma_corr_tb;

    reg  [23:0] I_data;
    wire [23:0] O_data;

    gamma_corr uut (
        .I_data ( I_data ),
        .O_data ( O_data )
    );

    integer errors = 0;
    integer i;
    reg [7:0] prev_v, curr_v;

    // ---------------------------------------------------------------
    // 单通道全量扫描: 0..255,查 X 与单调性
    // ---------------------------------------------------------------
    task scan_channel;
        input [1:0] ch; // 0=R 1=G 2=B
        begin
            prev_v = 8'd0;
            for (i = 0; i < 256; i = i + 1) begin
                case (ch)
                    2'd0:    I_data = { i[7:0], 8'd0, 8'd0 };
                    2'd1:    I_data = { 8'd0, i[7:0], 8'd0 };
                    default: I_data = { 8'd0, 8'd0, i[7:0] };
                endcase
                #1;

                case (ch)
                    2'd0:    curr_v = O_data[23:16];
                    2'd1:    curr_v = O_data[15:8];
                    default: curr_v = O_data[7:0];
                endcase

                if (^curr_v === 1'bx) begin
                    $display("FAIL ch%0d: gam(%0d) = X", ch, i);
                    errors = errors + 1;
                end
                if ((i > 0) && (curr_v < prev_v)) begin
                    $display("FAIL ch%0d: not monotonic gam(%0d)=%0d < gam(%0d)=%0d",
                             ch, i, curr_v, i-1, prev_v);
                    errors = errors + 1;
                end
                prev_v = curr_v;
            end
        end
    endtask

    // ---------------------------------------------------------------
    // 三通道抽点比对
    // ---------------------------------------------------------------
    task spot;
        input [7:0] r,  g,  b;
        input [7:0] er, eg, eb;
        begin
            I_data = { r, g, b };
            #1;
            if (O_data[23:16] !== er) begin
                $display("FAIL R: gam(%0d)=%0d expect %0d", r, O_data[23:16], er);
                errors = errors + 1;
            end
            if (O_data[15:8] !== eg) begin
                $display("FAIL G: gam(%0d)=%0d expect %0d", g, O_data[15:8], eg);
                errors = errors + 1;
            end
            if (O_data[7:0] !== eb) begin
                $display("FAIL B: gam(%0d)=%0d expect %0d", b, O_data[7:0], eb);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $display("=== gamma_corr testbench (black-level 16 + gamma 1/2.2, 256x8 x RGB) ===");

        // 1) 端点必须严格保持
        spot(8'd0,   8'd0,   8'd0,   8'd0,   8'd0,   8'd0);
        spot(8'd255, 8'd255, 8'd255, 8'd255, 8'd255, 8'd255);

        // 2) 抽点(参考值 = gen_gamma.py 的 "TB spot checks:" 一行,勿手算)
        //    复合式: y = max(i-16,0)*255/239; out = round(255*(y/255)^(1/2.2))
        spot(8'd1,   8'd17,  8'd32,  8'd0,   8'd21,  8'd75);
        spot(8'd64,  8'd96,  8'd160, 8'd123, 8'd155, 8'd203);
        spot(8'd128, 8'd192, 8'd224, 8'd181, 8'd222, 8'd239);
        spot(8'd240, 8'd200, 8'd100, 8'd248, 8'd226, 8'd159);

        // 3) 通道串扰: 三个通道给不同值,各查各的
        spot(8'd100, 8'd224, 8'd17,  8'd159, 8'd239, 8'd21);

        // 4) 逐通道全量扫描(无 X + 单调)
        scan_channel(2'd0);
        scan_channel(2'd1);
        scan_channel(2'd2);

        // 5) 黑电平必须被压回去 —— 第 2 轮修复的回归守卫。
        //    旧版(只有 gamma)gam(16)=72, 传感器黑底被抬成中灰 ⇒ "偏灰白"。
        for (i = 0; i <= 16; i = i + 1) begin
            I_data = { i[7:0], i[7:0], i[7:0] }; #1;
            if (O_data !== 24'd0) begin
                $display("FAIL: black level not crushed gam(%0d)=0x%h (expect 0x000000)", i, O_data);
                errors = errors + 1;
            end
        end
        $display("black level: gam(0..16) all zero (old build had gam(16)=72)");

        // 6) 中调仍应被提亮(去黑 + gamma 后 线性 64 -> 123)
        I_data = { 8'd64, 8'd64, 8'd64 }; #1;
        if (O_data[23:16] <= 8'd64) begin
            $display("FAIL: mid-tone not boosted gam(64)=%0d (expect > 64)", O_data[23:16]);
            errors = errors + 1;
        end
        $display("mid-tone: gam(64) = %0d (linear 64)", O_data[23:16]);

        if (errors == 0)
            $display("=== PASS: gamma_corr all checks passed ===");
        else
            $display("=== FAIL: %0d errors ===", errors);

        $finish;
    end

endmodule
