`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02.03.2026 02:10:35
// Design Name: 
// Module Name: twiddle_rom
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

module twiddle_rom #(
    parameter N=16,
    parameter max_N=1024,    
    parameter ADDR_WIDTH = 3    
)(
    input  wire clk,
    input  wire [ADDR_WIDTH-1:0] addr,
    output reg  signed [15:0] w_r, w_i
);
    
    localparam ROM_DEPTH = max_N/2;
    localparam SHIFT = $clog2(max_N / N);
    localparam MASTER_ADDR_WIDTH = $clog2(ROM_DEPTH);
    // Array holding Q1.15 complex twiddle factors
    reg [31:0] rom [0:ROM_DEPTH-1];

    initial begin
        // this hex file containing N/2 lines of 32-bit hex values
       $readmemh("twiddle_factors.mem", rom);
    end
    
    wire [MASTER_ADDR_WIDTH-1:0] safe_addr = addr;
    
    always @(*) begin
        {w_r, w_i} = rom[safe_addr << SHIFT];
    end
endmodule