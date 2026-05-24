# FPGA-Based FFT Engine for Edge Detection 

[![Hardware](https://img.shields.io/badge/Hardware-ZedBoard_(XC7Z020)-blue.svg)]()
[![Architecture](https://img.shields.io/badge/Architecture-SDF_Radix--2_DIF-orange.svg)]()
[![Toolchain](https://img.shields.io/badge/Toolchain-Xilinx_Vivado_2018.3-red.svg)]()

[cite_start]A comprehensive hardware-accelerated 2-D Fast Fourier Transform (FFT) pipeline for real-time image edge detection[cite: 1, 8]. [cite_start]This system utilizes a memory-efficient Single-Path Delay-Feedback (SDF) architecture on the Xilinx Zynq-7000 SoC to overcome the $O(N \log_{2}N)$ computational burden of spectral transforms[cite: 2, 10]. 

---

## 1. System Overview & Mathematical Foundation

[cite_start]Conventional spatial-domain edge detectors (e.g., Sobel, Canny) suffer from high-frequency noise amplification, restricted angular resolution, and fixed kernel locality[cite: 27, 28, 29, 31, 33]. [cite_start]This architecture shifts processing to the frequency domain[cite: 34]:
1. [cite_start]Decomposes the input image spectrally via a 2-D FFT[cite: 8].
2. [cite_start]Isolates high-frequency boundary content using a dynamically configurable circular high-pass filter (HPF)[cite: 8].
3. [cite_start]Reconstructs the spatial edge map via a 2-D Inverse FFT (IFFT)[cite: 8].

### Arithmetic Framework: Q1.15 Fixed-Point
[cite_start]To eliminate the massive resource overhead of floating-point units, the entire datapath operates on 16-bit **Q1.15 fixed-point** representation[cite: 121].
* **Range & Precision:** 1 sign bit, 15 fractional bits. [cite_start]Represents values from $-1.0$ to $\approx +0.99997$ with a step size of $\approx 0.0000305$[cite: 121, 125].
* **Scaling Strategy (Overflow Prevention):** A radix-2 butterfly addition can double the magnitude. [cite_start]To prevent register overflow, the hardware enforces a strict divide-by-2 (arithmetic right-shift `>>> 1`) at every butterfly stage[cite: 95].
* [cite_start]**Convergent Rounding (Bias Elimination):** Standard truncation introduces a $-0.5 \text{ LSB}$ bias[cite: 128]. [cite_start]The hardware implements round-half-up during addition and round-half-away-from-zero (adding $2^{14}$ before extracting bits `[30:15]`) during multiplication[cite: 207, 212].

---

## 2. Hardware Architecture (Verilog PL)

[cite_start]The custom accelerator is composed of fully-pipelined modules written in synthesizable Verilog, integrated via AXI4-Stream[cite: 10, 11].

### `Butterfly.v` (Computation Core)
[cite_start]Implements a two-stage registered pipeline for radix-2 Decimation-In-Frequency (DIF) computation[cite: 204].
* [cite_start]**Stage 1 (Addition):** Utilizes a 17-bit signed adder to compute $x_0 \pm x_1$[cite: 206]. [cite_start]Adds $1$ before shifting to execute round-half-up scaling[cite: 207, 210].
* [cite_start]**Stage 2 (Multiplication):** Multiplies the difference $(x_0 - x_1)$ by the twiddle factor $W_N^k$[cite: 94]. [cite_start]Applies Q1.15 convergent rounding[cite: 212, 231].

### `delay_line.v` (Memory Saver)
The core of the Single-Path Delay-Feedback memory savings. 
* [cite_start]**Depth:** At stage $k$, the delay line depth is $\Delta_k = N/2^{k+1}$[cite: 105]. [cite_start]For $N=1024$, total storage across all 10 stages is exactly $N-1 = 1023$ words[cite: 110].
* [cite_start]**Inference:** A `generate` block synthesizes a direct wire if `DEPTH == 0`[cite: 295]. [cite_start]For depths $\ge 32$, `ram_style="block"` explicitly infers Block RAM[cite: 293].

### `sdf_stage.v` (Routing Logic)
[cite_start]Chains the twiddle ROM, delay line, and butterfly unit[cite: 251].
* [cite_start]**Synchronization:** Because the butterfly has a 1-cycle delay, multiplexer control uses a delayed signal (`sel_d`) to ensure data and control arrive simultaneously at the feedback path[cite: 252].
* [cite_start]**Identity Gating:** During the load phase (`sel = 0`), $W = 1 + 0j$ is gated to the butterfly, preventing corruption of delay-line contents[cite: 271].

### `twiddle_rom.v` (Cosine/Sine Lookup)
* [cite_start]Stores Python pre-computed twiddle factors initialized via `$readmemh`[cite: 244].
* [cite_start]Uses a compile-time `SHIFT` parameter ($SHIFT = \log_2(N_{max}/N)$) to stride through a master 512-entry ROM, enabling smaller sub-transforms deep in the pipeline to reuse the same ROM block[cite: 245, 278].

### `bit_reversal.v` (Zero-Latency Sorter)
[cite_start]DIF FFT pipelines output data in a scrambled, bit-reversed order[cite: 334].
* [cite_start]**Ping-Pong Buffer:** Uses two $N$-word memory banks and a 4-state FSM (`RD_IDLE`, `RD_PREFETCH`, `RD_OUTPUT`, `RD_OUTPUT_ACK`)[cite: 335, 337, 341, 352, 353].
* [cite_start]**Concurrent Execution:** While one bank drains using a crossed-wire bit-reversed address (`ram[bit_rev(rd_addr)]`), the other bank fills sequentially[cite: 348, 355]. [cite_start]This sorts the data on-the-fly with zero added latency[cite: 335].

### `axi_hpf.v` (Spectral Mask)
[cite_start]A fully pipelined AXI4-Stream pass-through module that zeroes low frequencies[cite: 388].
* [cite_start]Computes wrapped distances: $d_x = \min(x\_cnt, N-x\_cnt)$ and $d_y = \min(y\_cnt, N-y\_cnt)$[cite: 394, 395].
* [cite_start]Bins satisfying $d_x^2 + d_y^2 < R^2$ (default $R=30$, $R^2=900$) are zeroed[cite: 395, 396].

### `axi_fft_wrapper.v` (SoC Interface)
* [cite_start]**IFFT Conjugation:** Applies the identity $IFFT\{X\} = \frac{1}{N} \overline{FFT\{\overline{X}\}}$[cite: 118]. [cite_start]If `ifft_mode == 1`, the imaginary component is hardware-negated on input and output[cite: 418].
* [cite_start]**Latency Tracking:** A shift register of depth $1033$ ($N + \log_2 N - 1$) ensures downstream modules wait until the pipeline is fully primed[cite: 419, 423].
* [cite_start]**Frame Flush:** Injects $N$ zero-valued words after `TLAST` to drain delay lines and prevent inter-row spectral leakage[cite: 420].

---

## 3. Software Pipeline (ARM Cortex-A9)

[cite_start]The bare-metal C application coordinates AXI4-Stream DMA transfers to maintain continuous back-to-back row processing[cite: 437, 438].

1. [cite_start]**DC-Shift & Packing:** Reads the 8-bit image via FatFs[cite: 440, 444]. [cite_start]Subtracts the true image mean from every pixel to prevent the DC frequency bin from overflowing the 16-bit limits, packing the result into Q1.15[cite: 447, 449, 450].
2. [cite_start]**Matrix Transpose:** Between row and column passes, the CPU performs an in-place $1024 \times 1024$ complex transpose[cite: 474]. [cite_start]Utilizes `Xil_DCacheFlushRange` and `Xil_DCacheInvalidateRange` to maintain cache coherency with the DMA[cite: 480, 509].
3. [cite_start]**Rescaling:** After the 2-D IFFT, the software compensates for the hardware's accumulated $2^{-10}$ attenuation by applying a left-shift, extracting the 8-bit edge map, and clipping out-of-bounds values[cite: 514, 519, 520].

---

## 4. Performance & Resource Verification

[cite_start]**Target Device:** Xilinx ZedBoard (XC7Z020-1CLG484C) [cite: 558]
[cite_start]**Clock Frequency:** 70 MHz [cite: 594]

### Post-Implementation Resource Utilization
[cite_start]The SDF architecture yields extreme memory efficiency compared to parallel (MDC) alternatives[cite: 560].

| Resource | Used | Available | Utilization |
| :--- | :--- | :--- | :--- |
| **Slice LUTs** | 11,171 | 53,200 | [cite_start]**21.0%** [cite: 484] |
| **Slice Registers** | 12,020 | 106,400 | [cite_start]**11.3%** [cite: 484] |
| **DSP48E1** | 42 | 220 | [cite_start]**19.1%** [cite: 484] |
| **Block RAM Tile** | 5 | 140 | [cite_start]**3.6%** [cite: 484] |
| **BUFGCTRL** | 1 | 32 | [cite_start]**3.1%** [cite: 484] |

### Timing & Accuracy Metrics
* [cite_start]**Timing Closure:** Met 100% of constraints across 40,248 endpoints[cite: 581, 583]. [cite_start]Worst Negative Slack (WNS) = $5.089 \text{ ns}$ [cite: 583][cite_start], indicating a maximum theoretical frequency ($F_{max}$) of $\approx 109 \text{ MHz}$[cite: 594].
* [cite_start]**Throughput:** A full $1024 \times 1024$ edge map completes in under $10 \text{ ms}$, comfortably satisfying the $33 \text{ ms}$ budget for 30 fps video[cite: 633].
* [cite_start]**Accuracy:** Verified against a bit-accurate Python NumPy float64 model[cite: 523, 596]. [cite_start]Achieved a Mean Absolute Pixel Error (MAPE) of **7.26 intensity levels out of 255 (2.85%)** [cite: 597][cite_start], with no visible artifacts[cite: 598].
