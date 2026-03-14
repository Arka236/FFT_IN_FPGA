`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 01.03.2026 20:55:01
// Design Name: 
// Module Name: top
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

module top #(
    parameter N=1024,
    parameter STAGES = $clog2(N), 
    parameter max_N=1024
)(
    input  wire clk,
    input  wire reset,
    input  wire start,
    input  wire signed [15:0] x_in_r, x_in_i,
    output wire signed [15:0] y_out_r, y_out_i
);
 

    // 1. The Global Counter
    reg [STAGES-1:0] master_cnt;
    always @(posedge clk or negedge reset) begin
        if (!reset) master_cnt <= 0;
        else if (start) begin 
          if (master_cnt == N-1)
             master_cnt <= 0;
          else
             master_cnt <= master_cnt + 1;
       end
    end

    // 2. Data Pipeline Rails (Arrays of wires connecting the stages)
    wire signed [15:0] pipe_r [0:STAGES];
    wire signed [15:0] pipe_i [0:STAGES];

    assign pipe_r[0] = x_in_r;
    assign pipe_i[0] = x_in_i;
    assign y_out_r   = pipe_r[STAGES];
    assign y_out_i   = pipe_i[STAGES];

    // 3. Hardware Generation Loop
    genvar k;
    generate
        for (k = 0; k < STAGES; k = k + 1) begin : sdf_pipeline
            
            localparam STAGE_DELAY = N >> (k + 1);
            wire [STAGES-1:0] local_cnt = master_cnt -  k;
            // the address increments based on the global counter shifted by the stage index.
            wire [STAGES-2:0] current_twiddle_addr;
            assign current_twiddle_addr = (local_cnt << k) & ((N/2) - 1);

            sdf_stage #(
                .STAGE_ID(k),
                .STAGES(STAGES),
                .DELAY(STAGE_DELAY),
                .N(N),
                .max_N(max_N)
            ) stage_inst (
                .clk(clk),
                .reset(reset),
                // The MUX control bit: slices from MSB down to LSB
                .sel(local_cnt[STAGES - 1 - k]),
                .twiddle_addr(current_twiddle_addr),
                .x_in_r(pipe_r[k]),      
                .x_in_i(pipe_i[k]),
                .y_out_r(pipe_r[k+1]),    
                .y_out_i(pipe_i[k+1])
            );
        end
    endgenerate

endmodule
