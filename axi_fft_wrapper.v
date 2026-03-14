`timescale 1ns / 1ps

module axi_fft_wrapper #(
    parameter N=1024
)(  
    // AXI Global Signals
    input  wire aclk,
    input  wire aresetn, // AXI uses Active-Low reset

    // AXI4-Stream SLAVE (Input from ARM/DMA)
    input  wire [31:0] s_axis_tdata,  // {Imaginary[15:0], Real[15:0]}
    input  wire        s_axis_tvalid,
    input  wire        s_axis_tlast,  // End of incoming frame flag
    output wire        s_axis_tready,

    // AXI4-Stream MASTER (Output to ARM/DMA)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    output wire        m_axis_tlast,
    input  wire        m_axis_tready
);

   // Unpack AXI data, but FORCE to zero during the flush phase to protect the pipeline
    wire signed [15:0] x_in_r = (s_axis_tvalid) ? s_axis_tdata[15:0]  : 16'd0;
    wire signed [15:0] x_in_i = (s_axis_tvalid) ? s_axis_tdata[31:16] : 16'd0;
    
    wire signed [15:0] y_out_r;
    wire signed [15:0] y_out_i;

    // A simple start trigger: begin FFT when DMA sends the first valid data
    // Because your SDF is a continuous pipeline, it is always ready to accept data
    assign s_axis_tready = 1'b1; 
    
    reg flushing;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            flushing <= 0;
        end else begin
            if (s_axis_tlast)        // When the input frame finishes, start flushing
                flushing <= 1;
            else if (m_axis_tlast)   // When the output frame finishes, stop flushing
                flushing <= 0;
        end
    end

    // The FFT must run if valid data is coming in, OR if it is flushing trapped outputs
    wire start_fft = s_axis_tvalid || flushing;
    
    // Instantiate your exact top module
    top #(.N(N)) fft_core (
        .clk(aclk),
        .reset(aresetn),      // Pass active-low reset directly to top.v
        .start(start_fft),
        .x_in_r(x_in_r),
        .x_in_i(x_in_i),
        .y_out_r(y_out_r),
        .y_out_i(y_out_i)
    );

    // ----------------------------------------------------------------
    // AXI State Machine: Handle Latency, TVALID, and TLAST
    // ----------------------------------------------------------------
    localparam CNT_WIDTH = $clog2(N) + 2;
    localparam STAGES = $clog2(N);
    
    reg [CNT_WIDTH-1:0] delay_cnt;
    reg [CNT_WIDTH-1:0] out_cnt;
    reg out_valid_reg;
    
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            delay_cnt <= 0;
            out_cnt <= 0;
            out_valid_reg <= 0;
        end else begin
            // 1. Wait for pipeline latency (N-1 cycles). 
            // Starts counting on the EXACT SAME CYCLE start_fft goes high
            if ((start_fft || delay_cnt > 0) && delay_cnt < (N + STAGES - 1)) begin
                delay_cnt <= delay_cnt + 1;
            end 
            
            // Trigger valid output when latency is met
            if (delay_cnt == N + STAGES - 2) begin
                out_valid_reg <= 1;
            end

            // 2. Count the 1024 output samples
            if (out_valid_reg) begin
                out_cnt <= out_cnt + 1;
                
                // Shut down writing on the 1024th output
                if (out_cnt == N - 1) begin
                    out_valid_reg <= 0;
                    out_cnt <= 0;
                end
            end

            // 3. Reset for the NEXT frame only when the DMA fully receives the current one
            if (m_axis_tlast && m_axis_tready) begin
                delay_cnt <= 0;
            end
        end
    end

    wire signed [15:0] br_out_r;
    wire signed [15:0] br_out_i;

    bit_reversal #(
        .N(N),
        .STAGES(STAGES),
        .WIDTH(16)
    ) br_inst (
        .clk(aclk),
        .rst(~aresetn),             // AXI is active-low, module is active-high
        .in_valid(out_valid_reg),
        .out_ready(m_axis_tready),   // The wrapper's state machine drives the write enable!
        .x_r(y_out_r),              // Scrambled data from top.v
        .x_i(y_out_i),
        .y_r(br_out_r),             // Sorted data out
        .y_i(br_out_i),
        .out_valid(m_axis_tvalid),  // Directly drives AXI TVALID
        .out_last(m_axis_tlast)     // Directly drives AXI TLAST
    );

    // Pack the sorted outputs back into the AXI format
    assign m_axis_tdata = {br_out_i, br_out_r};

endmodule