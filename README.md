# FFT_IN_FPGA
Numerical Transformations on FPGA (1024-Point FFT Pipeline)
Overview

This project implements a hardware-accelerated numerical transformation pipeline on FPGA using a 1024-point Fast Fourier Transform (FFT). The system processes image or signal data by converting it from the spatial/time domain to the frequency domain, enabling efficient signal analysis and transformations.

The design is implemented on a Xilinx Zynq‑7000 SoC FPGA platform, where the Processing System (ARM Cortex-A9) manages data flow and the Programmable Logic (FPGA fabric) performs high-speed FFT computation.

System Architecture

The system follows a PS–PL hardware acceleration architecture.

Input Data (Image / Signal)
        │
        ▼
SD Card / Memory
        │
        ▼
ARM Cortex-A9 (Processing System)
        │
        ▼
DDR Memory
        │
        ▼
AXI DMA
        │
        ▼
FFT Hardware Accelerator (Programmable Logic)
        │
        ▼
AXI DMA
        │
        ▼
DDR Memory
        │
        ▼
ARM Processor
        │
        ▼
Output Data / Reconstructed Signal
Components

Processing System (PS)

Manages program execution using C code in Xilinx SDK

Reads input data and stores it in DDR memory

Controls DMA transfers between memory and FFT hardware

Programmable Logic (PL)

Implements the FFT computation pipeline

Performs high-speed parallel numerical transformation

AXI DMA

Transfers data efficiently between PS memory and PL accelerator

Enables streaming data to the FFT module

FFT Processing Pipeline

The FFT module computes the Discrete Fourier Transform (DFT) efficiently using the Cooley–Tuk FFT algorithm.

For a signal 
𝑥
[
𝑛
]
x[n]:

𝑋
[
𝑘
]
=
∑
𝑛
=
0
𝑁
−
1
𝑥
[
𝑛
]
𝑒
−
𝑗
2
𝜋
𝑘
𝑛
/
𝑁
X[k]=
n=0
∑
N−1
	​

x[n]e
−j2πkn/N

Where:

𝑁
=
1024
N=1024

𝑥
[
𝑛
]
x[n] → input signal

𝑋
[
𝑘
]
X[k] → frequency spectrum

The FFT reduces computational complexity from:

O(N²)  →  O(N log₂ N)

which significantly improves performance for large datasets.

Image Processing Workflow

In this implementation, a 32×32 grayscale image (1024 pixels) is treated as a 1-dimensional signal.

Processing steps

Load the 32×32 grayscale image

Flatten the image into 1024 data samples

Send samples to the FPGA FFT accelerator

Compute the frequency-domain representation

Store FFT output back into memory

Convert results into binary output format

Reconstruct or visualize results as an image

Hardware Design

The FFT accelerator is implemented using Verilog RTL in the FPGA fabric.

Main components include:

Butterfly computation units

Twiddle factor multipliers

Pipeline registers

Control logic for streaming computation

The design supports continuous streaming data processing, allowing high-throughput operation.

Software Implementation

The software component runs on the ARM processor inside the Zynq device and performs:

Memory allocation for input/output buffers

Initialization of the AXI DMA engine

Data transfer between DDR memory and FFT accelerator

Reading/writing binary data files

The program is developed using C in Xilinx SDK/Vitis.

Key Features

Hardware-accelerated 1024-point FFT

FPGA-based numerical transformation

High-speed AXI-DMA data transfer

PS–PL co-design architecture

Image-to-signal conversion for frequency-domain analysis

Applications

This architecture can be extended for:

Image filtering

Edge detection

Signal spectrum analysis

Radar and communication systems

Real-time DSP acceleration

Technologies Used

Verilog HDL

C (Xilinx SDK / Vitis)

AXI DMA

FPGA hardware acceleration

Vivado design suite

Future Improvements

Possible enhancements include:

Implementing 2D FFT for full image processing

Real-time video signal processing

Frequency-domain filtering

Hardware IFFT for signal reconstruction
