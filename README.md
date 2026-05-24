# FFT Based Edge Detection on FPGA

# 2D FFT Hardware Edge Detection Accelerator (Zynq-7000)

[![Hardware](https://img.shields.io/badge/Hardware-ZedBoard_(Zynq--7000)-blue.svg)]()
[![Language](https://img.shields.io/badge/Language-Verilog%20%7C%20C-orange.svg)]()
[![Toolchain](https://img.shields.io/badge/Toolchain-Xilinx_Vivado%20%7C%20SDK-red.svg)]()

A real-time, hardware-accelerated 2D Fast Fourier Transform (FFT) edge detection pipeline built for the ZedBoard (Xilinx Zynq-7000). This project demonstrates a highly optimized **Hardware/Software Co-design** that offloads heavy DSP frequency-domain mathematics to custom FPGA logic while utilizing the ARM Cortex-A9 for memory management and matrix transposition.

Unlike spatial-domain operators (Sobel, Canny) which suffer from localized noise amplification and limited angular resolution, this accelerator translates $1024 \times 1024$ images into the frequency domain to apply mathematically perfect, circularly symmetric High-Pass Filters (HPF).

---

## 🚀 Key Architectural Features

### 1. Radix-2 Single Delay Feedback (SDF) Pipeline
To process continuous streaming AXI data without consuming massive BRAM arrays, the FFT core utilizes a **Radix-2 SDF** architecture. By intelligently recycling delay lines ($D=4, D=2, D=1$) and multiplexing the butterfly math units, the pipeline achieves $\mathcal{O}(N \log N)$ performance using the absolute minimum physical logic footprint.

### 2. Ping-Pong Bit-Reversal Buffer (Zero Latency)
Radix-2 Decimation-in-Frequency (DIF) FFTs naturally output data in a scrambled, bit-reversed order. Sorting this in software causes massive pipeline stalls. This architecture features a custom hardware **Double-Buffer (Ping-Pong)**:
* While the FFT engine writes scrambled data to Bank 1 (physically unscrambling it on-the-fly via crossed-wire addressing), the processor simultaneously reads the previously sorted row from Bank 0.
* Result: Continuous back-to-back row processing with **zero dropped clock cycles**.

### 3. Distributed Fixed-Point Gain (Solving the Zero-Floor)
16-bit hardware arithmetic requires right-shifting (`>>> 1`) at every butterfly stage to prevent register overflow. This creates a "zero-floor death" for tiny, high-frequency edge bins. This project solves this using a **Distributed Gain Architecture**:
* Applies a safe $32\times$ amplifier strictly *between* the Row and Column IFFT passes.
* Protects the high-frequency structural edges from quantization death without overflowing the massive DC/Low-frequency bins.

---

## 📊 Post-Implementation Resource Utilization

Target Device: **XC7Z020 (ZedBoard)** | Operating Frequency: **70 MHz**

| Resource | Used | Available | Utilization |
| :--- | :--- | :--- | :--- |
| **Slice LUTs** | 11,171 | 53,200 | **21.0%** |
| **Slice Registers** | 12,020 | 106,400 | **11.3%** |
| **DSP48E1** | 42 | 220 | **19.1%** |
| **Block RAM Tile** | 5 | 140 | **3.6%** |

*Note: By leveraging the ARM CPU's DDR memory for the $1024 \times 1024$ transpose, the FPGA PL only requires 3.6% of onboard BRAM for the Ping-Pong buffers, leaving massive area overhead for future IP integration.*

---

## 📁 Repository Structure

```text
├── src/
│   ├── hdl/                 # Verilog RTL source files
│   │   ├── Butterfly.v      # Radix-2 compute unit with Q1.15 rounding
│   │   ├── bit_reversal.v   # Ping-pong FSM buffer
│   │   └── axi_fft_wrap.v   # AXI4-Stream Slave/Master wrapper
│   └── c/                   # Bare-metal ARM application
│       ├── main.c           # Pipeline controller & Transpose logic
│       └── ff.c / ff.h      # FatFs library for SD Card I/O
├── python/
│   └── convert_fpga.py      # Output visualization & Spectrum analyzer
├── img/                     # Benchmark and architecture images
└── README.md
# 1.Overview

This project implements a hardware-accelerated numerical transformation pipeline on FPGA using a 1024-point Fast Fourier Transform (FFT). The system processes image or signal data by converting it from the spatial/time domain to the frequency domain, enabling efficient signal analysis and transformations.

The design is implemented on a Xilinx Zynq‑7000 SoC FPGA platform, where the Processing System (ARM Cortex-A9) manages data flow and the Programmable Logic (FPGA fabric) performs high-speed FFT computation.

# 2.System Architecture

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
# 3.Components

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

# 4.FFT Processing Pipeline

The FFT module computes the Discrete Fourier Transform (DFT) efficiently using the Cooley–Tuk FFT algorithm.

$$
X[k] = \sum_{n=0}^{N-1} x[n]e^{-j2\pi kn/N}
$$

Where:
* $X[k]$ is the frequency-domain representation.
* $x[n]$ is the discrete-time domain signal.
* $N$ is the number of points (1024 in this implementation).
The FFT reduces computational complexity from:

O(N²)  →  O(N log₂ N)

which significantly improves performance for large datasets.

# 5.Image Processing Workflow

In this implementation, a 32×32 grayscale image (1024 pixels) is treated as a 1-dimensional signal.

# 5.1.Processing steps

							Load the 32×32 grayscale image
							Flatten the image into 1024 data samples
							Send samples to the FPGA FFT accelerator
							Compute the frequency-domain representation
							Store FFT output back into memory
							Convert results into binary output format
							Reconstruct or visualize results as an image

# 6.Hardware Design
The FFT accelerator is implemented using Verilog RTL in the FPGA fabric.
Main components include:
							Butterfly computation units,
							Twiddle factor multipliers,
							Pipeline registers,
							Control logic for streaming computation,
The design supports continuous streaming data processing, allowing high-throughput operation.

# 7.Software Implementation
The software component runs on the ARM processor inside the Zynq device and performs:
							Memory allocation for input/output buffers
							Initialization of the AXI DMA engine
							Data transfer between DDR memory and FFT accelerator
							Reading/writing binary data files
							The program is developed using C in Xilinx SDK/Vitis.

# 8.Key Features
							Hardware-accelerated 1024-point FFT
							FPGA-based numerical transformation
							High-speed AXI-DMA data transfer
							PS–PL co-design architecture
							Image-to-signal conversion for frequency-domain analysis

# 9.Applications
This architecture can be extended for:
							Image filtering
							Edge detection
							Signal spectrum analysis
							Radar and communication systems
							Real-time DSP acceleration

# 10.Technologies Used
							Verilog HDL
							C (Xilinx SDK / Vitis)
							AXI DMA
							FPGA hardware acceleration
							Vivado design suite

# 11.Future Improvements
Possible enhancements include:
							Implementing 2D FFT for full image processing.
							Real-time video signal processing,
							Frequency-domain filtering,
							Hardware IFFT for signal reconstruction.
