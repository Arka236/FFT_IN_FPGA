`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 02.03.2026 03:03:59
// Design Name: 
// Module Name: sdf_stage
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

module sdf_stage #(
    parameter STAGE_ID = 0, 
    parameter N=16, 
    parameter STAGES = 4,     // Total log2(N)
    parameter DELAY = N/(1 << (STAGE_ID+1)),    // N / (2^(STAGE_ID+1))
    parameter max_N=1024
)(
    input  wire clk,
    input  wire reset,
    input  wire sel,           // The specific counter bit for this stage
    input  wire [STAGES-2:0] twiddle_addr, // Pre-calculated address from top
    input  wire signed [15:0] x_in_r, x_in_i,
    output wire signed [15:0] y_out_r, y_out_i
);
    wire signed [15:0] sr_out_r, sr_out_i;
    wire signed [15:0] sr_in_r,  sr_in_i;  
    wire signed [15:0] bf_y0_r,  bf_y0_i;   
    wire signed [15:0] bf_y1_r,  bf_y1_i;   
    wire signed [15:0] w_r, w_i;

    // 1. Twiddle ROM Instance
    twiddle_rom #(
        .N(N),
        .ADDR_WIDTH(STAGES-1),
        .max_N(max_N)
    ) rom_inst (
        .clk(clk),
        .addr(twiddle_addr),
        .w_r(w_r), .w_i(w_i)
    );

    // 2. Delay Line Instance
    delay_line #(.DEPTH(DELAY-1)) dl (
        .clk(clk), .reset(reset),
        .in_r(sr_in_r),   .in_i(sr_in_i),
        .out_r(sr_out_r), .out_i(sr_out_i)
    );
     
    wire signed [15:0] w_r_gated = sel ? w_r : 16'h7FFF; 
    wire signed [15:0] w_i_gated = sel ? w_i : 16'h0000;
    wire signed [15:0] x0_r_gated = sel ? sr_out_r : 16'h0000;
    wire signed [15:0] x0_i_gated = sel ? sr_out_i : 16'h0000;
    wire signed [15:0] x1_r_gated = sel ? x_in_r   : 16'h0000;
    wire signed [15:0] x1_i_gated = sel ? x_in_i   : 16'h0000;
    
    reg signed [15:0] x_in_r_d, x_in_i_d;
    reg signed [15:0] sr_out_r_d, sr_out_i_d;
    reg sel_d;

    always @(posedge clk or negedge reset) begin
        if (!reset) begin
            x_in_r_d <= 0; x_in_i_d <= 0;
            sr_out_r_d <= 0; sr_out_i_d <= 0;
            sel_d <= 0;
        end else begin
            x_in_r_d <= x_in_r;
            x_in_i_d <= x_in_i;
            sr_out_r_d <= sr_out_r;
            sr_out_i_d <= sr_out_i;
            sel_d <= sel;
        end
    end   
    
    // 3. Butterfly Instance
    Butterfly bf (
        .clk(clk),
        .x0_r(x0_r_gated), .x0_i(x0_i_gated), // Data from memory (past)
        .x1_r(x1_r_gated),   .x1_i(x1_i_gated),   // Data from input (present)
        .w_r(w_r_gated), .w_i(w_i_gated),
        .y0_r(bf_y0_r),  .y0_i(bf_y0_i),
        .y1_r(bf_y1_r),  .y1_i(bf_y1_i)
    );

    // 4. SDF MUX Logic: 0 = Load Memory, 1 = Calculate
// MUX Logic: Route using the 1-cycle delayed signals!
    assign sr_in_r = (sel_d == 1'b0) ? x_in_r_d : bf_y1_r;
    assign sr_in_i = (sel_d == 1'b0) ? x_in_i_d : bf_y1_i;
    
    assign y_out_r = (sel_d == 1'b0) ? sr_out_r_d : bf_y0_r;
    assign y_out_i = (sel_d == 1'b0) ? sr_out_i_d : bf_y0_i;
    
endmodule