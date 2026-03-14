`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07.03.2026 05:04:27
// Design Name: 
// Module Name: bit_reversal
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


module bit_reversal #(
    parameter N      = 1024,
    parameter STAGES = $clog2(N),
    parameter WIDTH  = 16
)(
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  in_valid,
    input  wire                  out_ready,
    input  wire signed [WIDTH-1:0] x_r, x_i,
    output reg  signed [WIDTH-1:0] y_r, y_i,
    output reg                     out_valid,
    output reg                     out_last 
);

    reg signed [WIDTH-1:0] ram_r [0:N-1];
    reg signed [WIDTH-1:0] ram_i [0:N-1];

    reg [STAGES-1:0] wr_addr;
    reg              wr_done;   
    reg [STAGES-1:0] rd_addr;
    reg              reading;

    function [STAGES-1:0] bit_rev;
        input [STAGES-1:0] in;
        integer j;
        begin
            bit_rev = 0;
            for (j = 0; j < STAGES; j = j + 1)
                bit_rev[j] = in[STAGES-1-j];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            wr_addr   <= 0;
            wr_done   <= 0;
            rd_addr   <= 0;
            reading   <= 0;
            out_valid <= 0;
            out_last  <= 0;
            y_r       <= 0;
            y_i       <= 0;
        end else begin
            // ----------------------------------------------------------------
            // WRITE PHASE (Linear)
            // ----------------------------------------------------------------
            if (in_valid && !wr_done) begin
                ram_r[wr_addr] <= x_r;
                ram_i[wr_addr] <= x_i;
                
                if (wr_addr == N-1) begin
                    wr_done <= 1;   
                    wr_addr <= 0;
                end else begin
                    wr_addr <= wr_addr + 1;
                end
            end

            // ----------------------------------------------------------------
            // READ PHASE (Scrambled)
            // ----------------------------------------------------------------
            if (wr_done && !reading && !out_valid) begin
                reading <= 1;
                rd_addr <= 0;
            end

            if (reading) begin
                if (!out_valid || out_ready) begin
                    y_r <= ram_r[bit_rev(rd_addr)];
                    y_i <= ram_i[bit_rev(rd_addr)];
                    out_valid <= 1;
                    
                // Assert TLAST exactly on the final word
                if (rd_addr == N-1) begin
                    out_last <= 1;
                    reading  <= 0; // Stop reading next cycle
                    rd_addr  <= 0;
                end else begin
                    out_last <= 0;
                    rd_addr  <= rd_addr + 1;
                end
              end
            end else if (out_valid) begin
                // WAIT FOR DMA! Do not drop TVALID or TLAST until TREADY is asserted.
                if (out_ready) begin
                    out_valid <= 0;
                    out_last  <= 0;
                    wr_done   <= 0; // Free the buffer for the next frame
                end
            end else begin
                // Turn pins off when not reading
                out_valid <= 0;
                out_last  <= 0;
            end
        end
    end
endmodule