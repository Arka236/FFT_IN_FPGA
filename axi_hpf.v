`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 31.03.2026 16:37:02
// Design Name: 
// Module Name: axi_hpf
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


`timescale 1ns / 1ps

module axi_hpf #(
    parameter N = 1024,
    parameter CUTOFF_SQ = 3600 // Default Cutoff Radius 30 (30^2 = 900)
)(
    input  wire        aclk,
    input  wire        aresetn,

    // AXI-Stream Slave (Input from DMA)
    input  wire [31:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,

    // AXI-Stream Master (Output to DMA)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast
);

    // Coordinate Trackers
    reg [15:0] x_cnt;
    reg [15:0] y_cnt;

    wire handshake = s_axis_tvalid & m_axis_tready;

    // Track X and Y coordinates across the 2D image
    always @(posedge aclk) begin
        if (!aresetn) begin
            x_cnt <= 0;
            y_cnt <= 0;
        end else if (handshake) begin
            // The DMA asserts TLAST at the end of every 1024-point row
            if (s_axis_tlast) begin
                x_cnt <= 0; // Reset X for the new row
                if (y_cnt == N - 1)
                    y_cnt <= 0; // Reset Y at the end of the entire image
                else
                    y_cnt <= y_cnt + 1;
            end else begin
                x_cnt <= x_cnt + 1;
            end
        end
    end

    // Distance calculations (Combinational 1-cycle data path)
    // Find shortest distance to the left/right and top/bottom edges
    wire [15:0] dx = (x_cnt < (N/2)) ? x_cnt : (N - x_cnt);
    wire [15:0] dy = (y_cnt < (N/2)) ? y_cnt : (N - y_cnt);
    
    // Calculate distance squared from nearest corner (DC component)
    wire [31:0] dist_sq = (dx * dx) + (dy * dy);

    // If within radius, block the frequency
    wire block_freq = (dist_sq < CUTOFF_SQ);

    // Pass-through AXI control signals directly
    assign s_axis_tready = m_axis_tready;
    assign m_axis_tvalid = s_axis_tvalid;
    assign m_axis_tlast  = s_axis_tlast;

    // Output zero if blocked, otherwise pass the frequency data untouched
    assign m_axis_tdata  = block_freq ? 32'd0 : s_axis_tdata;

endmodule
