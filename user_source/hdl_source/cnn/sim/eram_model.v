// eram_model.v — PH1P_LOGIC_ERAM 行为级仿真模型(仅 ModelSim 使用;TD 综合走真实原语)
//
// 关键:与真实原语一致的读时序 —— NOREG 读 = 地址当拍驱动、下一拍输出有效(1 拍延迟)。
//   原型:always @(posedge clk) q <= mem[addr];  即输出寄存 1 拍。
// 本模型只实现 video_to_cnn 用到的子集(DP/ASYNC,8bit,A 口写 B 口读);其余参数接受但忽略。
`timescale 1ns/1ps
module PH1P_LOGIC_ERAM #(
  parameter DATA_WIDTH_A = 8,
  parameter DATA_WIDTH_B = 8,
  parameter ADDR_WIDTH_A = 10,
  parameter ADDR_WIDTH_B = 10,
  parameter DATA_DEPTH_A = 1024,
  parameter DATA_DEPTH_B = 1024,
  parameter BYTE_ENABLE  = 0,
  parameter BYTE_A       = 1,
  parameter BYTE_B       = 1,
  parameter MODE         = "DP",
  parameter REGMODE_A    = "NOREG",
  parameter REGMODE_B    = "NOREG",
  parameter WRITEMODE_A  = "NORMAL",
  parameter WRITEMODE_B  = "NORMAL",
  parameter IMPLEMENT    = "20K",
  parameter ECC_ENCODE   = "DISABLE",
  parameter ECC_DECODE   = "DISABLE",
  parameter CLKMODE      = "SYNC",
  parameter SSROVERCE    = "DISABLE",
  parameter OREGSET_A    = "RESET",
  parameter OREGSET_B    = "RESET",
  parameter RESETMODE_A  = "ASYNC",
  parameter RESETMODE_B  = "ASYNC",
  parameter ASYNC_RESET_RELEASE_A = "SYNC",
  parameter ASYNC_RESET_RELEASE_B = "SYNC",
  parameter DEBUGGABLE   = "NO",
  parameter PACKABLE     = "NO",
  parameter FORCE_KEEP   = "OFF",
  parameter INIT_FILE    = "NONE",
  parameter FILL_ALL     = "NONE"
)(
  output wire                    ecc_sbiterr,
  output wire                    ecc_dbiterr,
  output wire [DATA_WIDTH_A-1:0] doa,
  output wire [DATA_WIDTH_B-1:0] dob,
  input  wire [DATA_WIDTH_A-1:0] dia,
  input  wire [DATA_WIDTH_B-1:0] dib,
  input  wire                    ecc_sbiterrinj,
  input  wire                    ecc_dbiterrinj,
  input  wire                    cea,
  input  wire                    ocea,
  input  wire                    clka,
  input  wire                    wea,
  input  wire                    rsta,
  input  wire                    ceb,
  input  wire                    oceb,
  input  wire                    clkb,
  input  wire                    web,
  input  wire                    rstb,
  input  wire                    bea,
  input  wire                    beb,
  input  wire [ADDR_WIDTH_A-1:0] addra,
  input  wire [ADDR_WIDTH_B-1:0] addrb
);

  reg [DATA_WIDTH_A-1:0] mem [0:DATA_DEPTH_A-1];
  reg [DATA_WIDTH_A-1:0] doa_r;
  reg [DATA_WIDTH_B-1:0] dob_r;

  integer k;
  initial begin
    for (k = 0; k < DATA_DEPTH_A; k = k + 1) mem[k] = {DATA_WIDTH_A{1'b0}};
    doa_r = {DATA_WIDTH_A{1'b0}};
    dob_r = {DATA_WIDTH_B{1'b0}};
  end

  // 端口 A:写(cea 选通,wea 写使能);读输出寄存 1 拍(NOREG 语义)
  always @(posedge clka) begin
    if (cea) begin
      if (wea) mem[addra] <= dia[ DATA_WIDTH_A-1 : 0 ];
      doa_r <= mem[addra];
    end
  end

  // 端口 B:读输出寄存 1 拍
  always @(posedge clkb) begin
    if (ceb) dob_r <= mem[addrb][ DATA_WIDTH_B-1 : 0 ];
  end

  assign doa = doa_r;
  assign dob = dob_r;
  assign ecc_sbiterr = 1'b0;
  assign ecc_dbiterr = 1'b0;

endmodule
