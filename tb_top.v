`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 05.03.2026 01:54:53
// Design Name: 
// Module Name: tb_top
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

  module tb_top;
    parameter N = 1024;

    // 1. Clock and Reset
    reg aclk;
    reg aresetn; // Active-low reset

    // 2. AXI4-Stream SLAVE (Driving the DUT like a DMA would)
    reg  [31:0] s_axis_tdata;
    reg         s_axis_tvalid;
    reg         s_axis_tlast;
    wire        s_axis_tready;

    // 3. AXI4-Stream MASTER (Receiving from the DUT)
    wire [31:0] m_axis_tdata;
    wire        m_axis_tvalid;
    wire        m_axis_tlast;
    reg         m_axis_tready;

    // 4. Instantiate the Wrapper (Device Under Test)
    axi_fft_wrapper #(.N(N)) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast(s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tlast(m_axis_tlast),
        .m_axis_tready(m_axis_tready)
    );

    // 5. Generate a 100 MHz Clock
    initial begin
        aclk = 0;
        forever #5 aclk = ~aclk; // 10ns period
    end

    // File I/O Variables
    reg [31:0] in_mem [0:N-1];
    integer fd, i;

    // ----------------------------------------------------------------
    // INPUT STIMULUS (The "ARM Processor / DMA" Transmitter)
    // ----------------------------------------------------------------
    initial begin
        // Initialize everything to zero
        $readmemh("input_wave.mem", in_mem);
        aresetn = 0;
        s_axis_tdata = 0;
        s_axis_tvalid = 0;
        s_axis_tlast = 0;
        m_axis_tready = 1; // We are always ready to capture outputs

        // Hold reset for a few cycles, then release
        #50;
        aresetn = 1;
        #50;

        // Start pushing data on the clock edges
        @(posedge aclk);
        for (i = 0; i < N; i = i + 1) begin
            s_axis_tvalid <= 1'b1;
            
            // Map memory to AXI format: {Imaginary[15:0], Real[15:0]}
            // (Assumes your input_wave.mem has Real in top 16 bits, Imag in bottom 16 bits)
            s_axis_tdata  <= {in_mem[i][15:0], in_mem[i][31:16]}; 
            
            // Assert TLAST exactly on the final pixel
            if (i == N - 1)
                s_axis_tlast <= 1'b1;
            else
                s_axis_tlast <= 1'b0;
            
            @(posedge aclk);
            
            // Wait if the DUT is not ready (Handshake rule)
            while (!s_axis_tready) @(posedge aclk);
        end

        // Frame complete. Shut off the transmitter.
        s_axis_tvalid <= 1'b0;
        s_axis_tlast  <= 1'b0;
    end

    // ----------------------------------------------------------------
    // OUTPUT CAPTURE (The "ARM Processor / DMA" Receiver)
    // ----------------------------------------------------------------
    initial begin
        fd = $fopen("fft_hardware_out.txt", "w");
        
        // Wait safely until reset clears
        @(posedge aresetn);

        // Infinite loop to constantly monitor the output pins
        forever begin
            @(posedge aclk);
            
            // Data is only captured when both VALID and READY are high
            if (m_axis_tvalid && m_axis_tready) begin
                
                // Unpack the AXI data {Imag, Real} and write to file
                // Applying 16'hFFFF masks it to exactly 4 hex characters for Python
                $fdisplay(fd, "%x %x", m_axis_tdata[15:0] & 16'hFFFF, m_axis_tdata[31:16] & 16'hFFFF);
                
                // If this was the last word of the packet, close up and finish!
                if (m_axis_tlast) begin
                    $display("SUCCESS: Received TLAST boundary! Closing simulation.");
                    $fclose(fd);
                    #50;
                    $finish;
                end
            end
        end
    end

endmodule