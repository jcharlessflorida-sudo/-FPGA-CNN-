`timescale 1ns/1ps
// logo_eram_tb.v - 验证 cnn/weights/logo_80x80.dat 与 anlogic_logo_rom_half 逐字相同。
//
// 为什么不直接仿 ERAM 本身:sim/eram_model.v 收下 INIT_FILE 但**忽略它**(初始块把
// 存储清零),所以 ERAM 的**内容**根本没法规那个模型验证。于是分层:
//     logo_half_tb.v : anlogic_logo_rom_half == 全分辨率原厂 ROM 的正确降采样  [已 PASS]
//     本 TB          : logo_80x80.dat        == anlogic_logo_rom_half (逐字)
// 两条合起来 => TD 真正吃进去的那个 .dat 就是正确的表。
//
// 只需在 cnn/ 目录下跑 run_logo_eram.do(cwd = cnn/,故 .dat 用相对路径 weights/...)。
//
// ModelSim 的 $display 会打乱 UTF-8 => 本文件所有 $display 只用 ASCII。
module logo_eram_tb;
    localparam DEPTH = 8192;      // ERAM 深度(2^13)
    localparam HW    = 6400;      // 80x80 有效区
    localparam NINK  = 1769;      // 有效区非零条目数,由 a/gen_logo_rom.py 算出

    reg  [24:0] mem [0:DEPTH-1];
    reg  [12:0] a;
    wire [24:0] half_pix;
    integer     i, errs, nz;

    anlogic_logo_rom_half u_half (
        .I_addr  ( a        ),
        .O_pixel ( half_pix )
    );

    task chk(input [12:0] addr, input [24:0] got, input [24:0] want);
        begin
            if (got !== want) begin
                errs = errs + 1;
                if (errs <= 10)
                    $display("FAIL addr=%0d got=0x%07x want=0x%07x", addr, got, want);
            end
        end
    endtask

    initial begin
        errs = 0;
        nz   = 0;
        a    = 13'd0;

        $readmemb("weights/logo_80x80.dat", mem);

        // 1) 逐字比对:.dat == anlogic_logo_rom_half(半分辨率组合表)
        for (i = 0; i < DEPTH; i = i + 1) begin
            a = i;                    // 截断到 13bit;i < 8192 所以无损
            #1;                       // 组合 case 无延迟,但赋值到求值跨 delta,等一拍
            if (^mem[i] === 1'bx) begin
                errs = errs + 1;
                if (errs <= 10) $display("FAIL addr=%0d .dat is X (readmemb ok?)", i);
            end
            chk(a, mem[i], half_pix);
        end

        // 2) 有效区非零条目数
        for (i = 0; i < HW; i = i + 1)
            if (mem[i] !== 25'd0) nz = nz + 1;
        if (nz !== NINK) begin
            errs = errs + 1;
            $display("FAIL ink count: %0d != %0d", nz, NINK);
        end

        // 3) 抽点(与 logo_half_tb.v 同一批,期望值来自 gen_logo_rom.py 的 TB spot checks)
        chk(13'd1386, mem[1386], 25'h1cccfd5);
        chk(13'd1387, mem[1387], 25'h1adb2bc);
        chk(13'd2352, mem[2352], 25'h11c2d4e);
        chk(13'd3247, mem[3247], 25'h1ed1c24);
        chk(13'd4215, mem[4215], 25'h1f43e44);
        chk(13'd5092, mem[5092], 25'h1f99195);
        chk(13'd5093, mem[5093], 25'h1fbbcbe);

        // 4) 边界 + 6400 之后的补零区必须全 0(25'd0 = 透明)
        chk(13'd0,    mem[0],    25'd0);
        chk(13'd6399, mem[6399], 25'd0);
        for (i = HW; i < DEPTH; i = i + 1)
            if (mem[i] !== 25'd0) begin
                errs = errs + 1;
                if (errs <= 10) $display("FAIL pad addr=%0d = 0x%07x", i, mem[i]);
            end

        if (errs == 0)
            $display("PASS: logo_80x80.dat == anlogic_logo_rom_half, %0d/%0d entries ink", nz, HW);
        else
            $display("FAILED: %0d error(s)", errs);
        $finish;
    end
endmodule
