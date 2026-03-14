`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.03.2026 17:54:16
// Design Name: 
// Module Name: Butterfly
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module Butterfly( x0_r,x0_i,x1_r,x1_i,w_r,w_i,y0_r,y0_i,y1_r,y1_i,clk  );
input clk;
input signed [15:0] x0_r;
input signed [15:0] x0_i;
input signed [15:0] x1_r;
input signed [15:0] x1_i;
input signed [15:0] w_r;
input signed [15:0] w_i;
output signed [15:0] y0_r;
output signed [15:0] y0_i;
output signed [15:0] y1_r;
output signed [15:0] y1_i;

wire signed [31:0] mul_r;
wire signed [31:0] mul_i;
wire signed [15:0] diff_r;
wire signed [15:0] diff_i;
wire signed [15:0] sum_r;
wire signed [15:0] sum_i;

assign sum_r = ( $signed({x0_r[15],x0_r}) + $signed({x1_r[15],x1_r})) >>> 1;
assign sum_i = ( $signed({x0_i[15],x0_i}) + $signed({x1_i[15],x1_i})) >>> 1;
assign diff_r = ( $signed({x0_r[15],x0_r}) - $signed({x1_r[15],x1_r})) >>> 1;
assign diff_i = ( $signed({x0_i[15],x0_i}) - $signed({x1_i[15],x1_i})) >>> 1;

reg signed [15:0] sum_r_reg,  sum_i_reg;
reg signed [15:0] diff_r_reg, diff_i_reg;
reg signed [15:0] w_r_reg,    w_i_reg;

always @(posedge clk) 
  begin
sum_r_reg  <= sum_r;
sum_i_reg  <= sum_i;
diff_r_reg <= diff_r;
diff_i_reg <= diff_i;
w_r_reg    <= w_r;
w_i_reg    <= w_i;
  end
    
assign mul_r = diff_r_reg * w_r_reg - diff_i_reg * w_i_reg;
assign mul_i = diff_r_reg * w_i_reg + diff_i_reg * w_r_reg;

assign y0_r = sum_r_reg;
assign y0_i = sum_i_reg;
assign y1_r = mul_r[30:15];
assign y1_i = mul_i[30:15];

endmodule
