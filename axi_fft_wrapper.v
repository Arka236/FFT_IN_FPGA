`timescale 1ns / 1ps

module axi_fft_wrapper #(
    parameter N=1024
)(  
    // AXI Global Signals
    input  wire aclk,
    input  wire aresetn, // AXI uses Active-Low reset

    // NEW: Mode Control Pin (0 = FFT, 1 = IFFT)
    input  wire ifft_mode, 

    // AXI4-Stream SLAVE (Input from ARM/DMA)
    input  wire [31:0] s_axis_tdata,  
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,  
    output wire        s_axis_tready,

    // AXI4-Stream MASTER (Output to ARM/DMA)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    output wire        m_axis_tlast,
    input  wire        m_axis_tready
);

    // ----------------------------------------------------------------
    // INPUT CONJUGATION (Pre-Processing)
    // ----------------------------------------------------------------
    wire signed [15:0] raw_in_r = s_axis_tdata[15:0];
    wire signed [15:0] raw_in_i = s_axis_tdata[31:16];
    
    // If IFFT mode is active, negate the imaginary part (2's complement)
    wire signed [15:0] proc_in_r = raw_in_r;
    wire signed [15:0] proc_in_i = ifft_mode ? -raw_in_i : raw_in_i;

    // Unpack AXI data, but FORCE to zero during the flush phase
    wire signed [15:0] x_in_r = (s_axis_tvalid) ? proc_in_r : 16'd0;
    wire signed [15:0] x_in_i = (s_axis_tvalid) ? proc_in_i : 16'd0;
    
    wire signed [15:0] y_out_r;
    wire signed [15:0] y_out_i;

    reg flushing;
    assign s_axis_tready = ~flushing; 
    
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            flushing <= 0;
        end else begin
            if (s_axis_tlast)        
                flushing <= 1;
            else if (m_axis_tlast)   
                flushing <= 0;
        end
    end

    wire start_fft = s_axis_tvalid || flushing;
    
    // Instantiate your exact top module
    top #(.N(N)) fft_core (
        .clk(aclk),
        .reset(aresetn),      
        .start(start_fft),
        .x_in_r(x_in_r),
        .x_in_i(x_in_i),
        .y_out_r(y_out_r),
        .y_out_i(y_out_i)
    );

    // Shift Register Pipeline Tracker
    localparam STAGES = $clog2(N);
    localparam LATENCY = N + STAGES - 1; 
    
    reg [LATENCY-1:0] valid_pipe;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            valid_pipe <= 0;
        end else begin
            valid_pipe <= {valid_pipe[LATENCY-2:0], s_axis_tvalid};
        end
    end

    wire out_valid_reg = valid_pipe[LATENCY-1];

    // BIT REVERSAL 
    wire signed [15:0] br_out_r;
    wire signed [15:0] br_out_i;

    bit_reversal #(
        .N(N),
        .STAGES(STAGES),
        .WIDTH(16)
    ) br_inst (
        .clk(aclk),
        .rst(~aresetn),             
        .in_valid(out_valid_reg),
        .out_ready(m_axis_tready),   
        .x_r(y_out_r),              
        .x_i(y_out_i),
        .y_r(br_out_r),             
        .y_i(br_out_i),
        .out_valid(m_axis_tvalid),  
        .out_last(m_axis_tlast)     
    );

    // ----------------------------------------------------------------
    // OUTPUT CONJUGATION (Post-Processing)
    // ----------------------------------------------------------------
    wire signed [15:0] final_out_r = br_out_r;
    // Negate the imaginary part again before sending it back to DMA
    wire signed [15:0] final_out_i = ifft_mode ? -br_out_i : br_out_i;

    assign m_axis_tdata = {final_out_i, final_out_r};

endmodule
