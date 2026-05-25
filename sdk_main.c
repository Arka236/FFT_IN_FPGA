/*
 * 2D FFT/IFFT Hardware Image Processing Pipeline (Diagnostic Output Version)
 * Target: ZedBoard (Zynq-7000 / 32-bit)
 * Features: Hardware 2D FFT, Hardware HPF, Hardware 2D IFFT, Multi-stage SD Card Logging
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ff.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xgpio.h"

// --- Configuration ---
#define N 1024
#define DMA_SIZE (N * 4)
#define IMG_SIZE (N * N)
#define BIN_SIZE (N * N * 4)

// --- Absolute DDR Memory Map ---
#define MEM_BASE 0x10000000
#define BUFFER_A ((u32*)(MEM_BASE + 0x0000000))
#define BUFFER_B ((u32*)(MEM_BASE + 0x1000000))

// --- Hardware Instances ---
XAxiDma AxiDma_FFT;
XAxiDma AxiDma_HPF;
XGpio FftModeGpio;
FATFS fatfs;

// --- Fast Inline Unpack/Pack ---
static inline void unpack(u32 word, s16 *re, s16 *im) {
    *re = (s16)(word & 0xFFFF);
    *im = (s16)((word >> 16) & 0xFFFF);
}

static inline u32 pack(s16 re, s16 im) {
    return ((u32)(u16)im << 16) | (u16)re;
}

// --- Software Amplifier ---
void amplify_buffer(u32 *buf, int gain) {
    for(int i=0; i < N*N; i++) {
        s16 re, im;
        unpack(buf[i], &re, &im);

        s32 new_re = (s32)re * gain;
        s32 new_im = (s32)im * gain;

        if (new_re >  32767) new_re =  32767;
        if (new_re < -32768) new_re = -32768;
        if (new_im >  32767) new_im =  32767;
        if (new_im < -32768) new_im = -32768;

        buf[i] = pack((s16)new_re, (s16)new_im);
    }
}

// --- Helper: Save Raw 32-bit Complex Buffer to SD ---
void save_raw_buffer(FIL *fil, const char *filename, u32 *buffer) {
    UINT bw;
    if(f_open(fil, filename, FA_CREATE_ALWAYS | FA_WRITE) == FR_OK) {
        f_write(fil, buffer, BIN_SIZE, &bw);
        f_close(fil);
        xil_printf("        [LOG] Saved 4MB complex data to %s\n\r", filename);
    } else {
        xil_printf("        [ERROR] Could not save %s\n\r", filename);
    }
}

// --- The Silicon Reboot & Peripheral Init ---
void reset_pl_fabric() {
    Xil_Out32(0xF8000008, 0xDF0D);
    Xil_Out32(0xF8000240, 0x1);
    for(volatile int i=0; i<2000; i++);
    Xil_Out32(0xF8000240, 0x0);
    Xil_Out32(0xF8000004, 0x767B);

    XAxiDma_Config *CfgPtr_FFT = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    XAxiDma_CfgInitialize(&AxiDma_FFT, CfgPtr_FFT);
    XAxiDma_IntrDisable(&AxiDma_FFT, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrDisable(&AxiDma_FFT, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    XAxiDma_Config *CfgPtr_HPF = XAxiDma_LookupConfig(XPAR_AXIDMA_1_DEVICE_ID);
    XAxiDma_CfgInitialize(&AxiDma_HPF, CfgPtr_HPF);
    XAxiDma_IntrDisable(&AxiDma_HPF, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrDisable(&AxiDma_HPF, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    XGpio_Initialize(&FftModeGpio, XPAR_AXI_GPIO_0_DEVICE_ID);
    XGpio_SetDataDirection(&FftModeGpio, 1, 0x0);
}

void transpose(u32 *src, u32 *dst) {
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < N; j++) {
            dst[j * N + i] = src[i * N + j];
        }
    }
}

// --- Unified Hardware FFT/IFFT Execution (DMA 0) ---
void run_hw_fft_pipeline(u32 src_addr, u32 dst_addr, int is_ifft) {
    XGpio_DiscreteWrite(&FftModeGpio, 1, is_ifft);
    Xil_DCacheFlushRange((UINTPTR)src_addr, DMA_SIZE);
    XAxiDma_SimpleTransfer(&AxiDma_FFT, (UINTPTR)dst_addr, DMA_SIZE, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_SimpleTransfer(&AxiDma_FFT, (UINTPTR)src_addr, DMA_SIZE, XAXIDMA_DMA_TO_DEVICE);
    while (XAxiDma_Busy(&AxiDma_FFT, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&AxiDma_FFT, XAXIDMA_DEVICE_TO_DMA));
    Xil_DCacheInvalidateRange((UINTPTR)dst_addr, DMA_SIZE);
}

// --- Hardware HPF Execution (DMA 1) ---
void run_hw_hpf_row(u32 src_addr, u32 dst_addr) {
    Xil_DCacheFlushRange((UINTPTR)src_addr, DMA_SIZE);
    XAxiDma_SimpleTransfer(&AxiDma_HPF, (UINTPTR)dst_addr, DMA_SIZE, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_SimpleTransfer(&AxiDma_HPF, (UINTPTR)src_addr, DMA_SIZE, XAXIDMA_DMA_TO_DEVICE);
    while (XAxiDma_Busy(&AxiDma_HPF, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&AxiDma_HPF, XAXIDMA_DEVICE_TO_DMA));
    Xil_DCacheInvalidateRange((UINTPTR)dst_addr, DMA_SIZE);
}

// =================================================================
// MAIN PIPELINE
// =================================================================
int main() {
    FIL fil; UINT br, bw;
    u32 *buf_a = BUFFER_A;
    u32 *buf_b = BUFFER_B;

    xil_printf("\n\r--- Dual-DMA Pure Hardware Pipeline Start ---\n\r");
    reset_pl_fabric();

    if(f_mount(&fatfs, "0:/", 0) != FR_OK) {
        xil_printf("ERROR: SD Mount failed.\n\r");
        return -1;
    }

    // ---------------------------------------------------------
    // 1. Read Image
    // ---------------------------------------------------------
    xil_printf("Step 1: Reading input.bin...\n\r");
    u8 *raw_pixels = (u8*)malloc(IMG_SIZE);
    f_open(&fil, "0:/input.bin", FA_READ);
    f_read(&fil, raw_pixels, IMG_SIZE, &br);
    f_close(&fil);

    u32 sum = 0;
    for(int i=0; i<IMG_SIZE; i++) sum += raw_pixels[i];
    int true_mean = sum / IMG_SIZE;

    for(int i=0; i<IMG_SIZE; i++) {
        int shifted = (int)raw_pixels[i] - true_mean;
        buf_a[i] = pack((s16)(shifted * 128), 0);
    }
    free(raw_pixels);

    // ---------------------------------------------------------
    // 2. Forward 2D FFT
    // ---------------------------------------------------------
    xil_printf("Step 2: Hardware 2D FFT...\n\r");
    for(int i=0; i<N; i++) run_hw_fft_pipeline((u32)&buf_a[i*N], (u32)&buf_b[i*N], 0);
    transpose(buf_b, buf_a);
    for(int i=0; i<N; i++) run_hw_fft_pipeline((u32)&buf_a[i*N], (u32)&buf_b[i*N], 0);
    transpose(buf_b, buf_a);

    // *DIAGNOSTIC SAVE 1: The Raw Frequency Spectrum*
    save_raw_buffer(&fil, "0:/FFT_RAW.BIN", buf_a);

    // ---------------------------------------------------------
    // 3. Hardware HPF
    // ---------------------------------------------------------
    xil_printf("Step 3: Hardware High Pass Filter...\n\r");
    for(int i = 0; i < N; i++) {
        run_hw_hpf_row((u32)&buf_a[i*N], (u32)&buf_b[i*N]);
    }
    memcpy(buf_a, buf_b, BIN_SIZE);

    // *DIAGNOSTIC SAVE 2: The Filtered Spectrum (Corners zeroed out)*
    save_raw_buffer(&fil, "0:/HPF_RAW.BIN", buf_a);

    int GAIN_1 = 64;
    int GAIN_2 = 32;
    amplify_buffer(buf_a, GAIN_1);

    // ---------------------------------------------------------
    // 4. Inverse 2D IFFT
    // ---------------------------------------------------------
    xil_printf("Step 4: RTL-Accelerated 2D IFFT...\n\r");
    for(int i=0; i<N; i++) run_hw_fft_pipeline((u32)&buf_a[i*N], (u32)&buf_b[i*N], 1);
    transpose(buf_b, buf_a);
    amplify_buffer(buf_a, GAIN_2);
    for(int i=0; i<N; i++) run_hw_fft_pipeline((u32)&buf_a[i*N], (u32)&buf_b[i*N], 1);
    transpose(buf_b, buf_a);

    // ---------------------------------------------------------
    // 5. Extract Final Edge Map
    // ---------------------------------------------------------
    xil_printf("Step 5: Extracting 8-bit edge map...\n\r");
    u8 *output_pixels = (u8*)malloc(IMG_SIZE);

    for(int i=0; i<IMG_SIZE; i++) {
        s16 re_ext, im_ext;
        unpack(buf_a[i], &re_ext, &im_ext);

        int raw_val = (((int)re_ext * N) / 128);
        int pixel_val = abs(raw_val);

        if (pixel_val > 255) pixel_val = 255;
        output_pixels[i] = (u8)pixel_val;
    }

    if(f_open(&fil, "0:/IFFT_OUT.BIN", FA_CREATE_ALWAYS | FA_WRITE) == FR_OK) {
        f_write(&fil, output_pixels, IMG_SIZE, &bw);
        f_close(&fil);
        xil_printf("        [LOG] Saved 8-bit Edge Map to IFFT_OUT.BIN\n\r");
    }

    free(output_pixels);
    f_mount(NULL, "0:/", 0);
    xil_printf("--- Done! Safe to remove SD Card. ---\n\r");
    return 0;
}
