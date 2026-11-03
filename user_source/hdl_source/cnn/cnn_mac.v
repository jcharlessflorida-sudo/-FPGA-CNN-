// cnn_mac.v — 有符号 int8 x int8 乘累加(int32 累加,中间不截位)
// I_w 为二进制补码(int8 有符号);I_a 为 0..127 激活(零扩展等价于有符号正数)。
// 乘积 int8xint8 落在 int16 内,故 32x32 乘法的低 32 位即为精确结果。
`timescale 1ns/1ps
module cnn_mac (
  input  wire               I_clk,
  input  wire               I_rst_n,
  input  wire               I_clear,
  input  wire               I_load_bias,
  input  wire               I_en,
  input  wire signed [7:0]  I_w,
  input  wire signed [7:0]  I_a,
  input  wire signed [31:0] I_bias,
  output reg  signed [31:0] O_acc
);

  wire signed [31:0] S_w_ext = {{24{I_w[7]}}, I_w};  // 权重符号扩展
  wire signed [31:0] S_a_ext = {24'b0, I_a};         // 激活零扩展(0..127)
  wire signed [31:0] S_prod  = S_w_ext * S_a_ext;    // 32x32 -> 取低 32 位(int8xint8 精确)

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)         O_acc <= 32'sd0;
    else if (I_clear)     O_acc <= 32'sd0;
    else if (I_load_bias) O_acc <= I_bias;
    else if (I_en)        O_acc <= O_acc + S_prod;
  end

endmodule
