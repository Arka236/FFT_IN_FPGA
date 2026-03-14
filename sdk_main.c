/*
 * main.c
 *
 *  Created on: 08-Mar-2026
 *      Author: Sreethan
 *
 * Modified: Added IFFT via conjugate trick.
 *
 * IFFT algorithm (reuses the same FFT hardware):
 *   1. Conjugate the FFT output  X*[k]
 *   2. DMA through the FFT core  -> gives FFT(X*[k])
 *   3. Conjugate the result      -> gives IFFT(X[k]) * N
 *   4. Divide each sample by N   -> gives IFFT(X[k])
 *
 * Flow:
 *   SD INPUT.mem -> DDR_INPUT
 *       -> [FFT HW] -> DDR_FFT_OUT   (saved to RESULT_FFT.BIN)
 *       -> conjugate in C
 *       -> [FFT HW] -> DDR_IFFT_RAW
 *       -> conjugate + divide by N in C
 *       -> DDR_IFFT_OUT              (saved to RESULT_IFFT.BIN)
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "xil_printf.h"
#include "ff.h"
#include "xstatus.h"
#include "xparameters.h"
#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_io.h"
// ----------------------------------------------------------------
// Memory map  (each buffer = 1024 * 4 = 4096 bytes = 0x1000)
// ----------------------------------------------------------------
#define DDR_INPUT       0x10000000   // raw input samples
#define DDR_FFT_OUT     0x11000000   // FFT output (from HW)
#define DDR_CONJ_BUF    0x12000000   // conjugated FFT output (IFFT input)
#define DDR_IFFT_RAW    0x13000000   // raw output of second FFT pass
#define DDR_IFFT_OUT    0x14000000   // final IFFT output after conjugate + /N

#define FFT_POINTS  1024
#define WORD_BYTES  4
#define DMA_SIZE    (FFT_POINTS * WORD_BYTES)

XAxiDma AxiDmaInstance;

// ----------------------------------------------------------------
// Helper: extract signed 16-bit real and imag from a packed 32-bit word
// Format: bits[31:16] = imag, bits[15:0] = real  (Q1.15)
// ----------------------------------------------------------------
static inline void unpack(u32 word, s16 *re, s16 *im) {
    *re = (s16)(word & 0xFFFF);
    *im = (s16)((word >> 16) & 0xFFFF);
}

static inline u32 pack(s16 re, s16 im) {
    return ((u32)(u16)im << 16) | (u16)re;
}

// ----------------------------------------------------------------
// Conjugate every sample in a DDR buffer:
//   imag = -imag, real unchanged
// src and dst can be the same address (in-place).
// ----------------------------------------------------------------
static void conjugate_buffer(u32 src_addr, u32 dst_addr) {
    u32 *src = (u32 *)src_addr;
    u32 *dst = (u32 *)dst_addr;
    s16 re, im;
    for (int k = 0; k < FFT_POINTS; k++) {
        unpack(src[k], &re, &im);
        dst[k] = pack(re, -im);
    }
}

// ----------------------------------------------------------------
// Conjugate + divide by N (final IFFT step):
//   real = -imag_in / N   ... wait, after second FFT:
//   result[n] = conj( FFT(conj(X))[n] ) / N
//             = IDFT(X)[n]
// So: re_out = re_in / N,  im_out = -im_in / N
// ----------------------------------------------------------------
static void conjugate_and_scale(u32 src_addr, u32 dst_addr) {
    u32 *src = (u32 *)src_addr;
    u32 *dst = (u32 *)dst_addr;
    s16 re, im;
    for (int n = 0; n < FFT_POINTS; n++) {
        unpack(src[n], &re, &im);
        // Divide by N (arithmetic right shift by log2(N) = 10 for N=1024)
        // Note: the FFT hardware already divided by N once during its pipeline.
        // The second pass divides by N again, so total is /N^2.
        // We multiply back by N here to undo one of the /N divisions.
        // Net result: output = IFFT(X) / N  (same scale as FFT output)
        //
        // If you need full amplitude, change >> 0 to nothing and remove the /N
        // from the hardware side -- but that requires hardware changes.
        // For now we keep consistent scale with the FFT output.
        s16 re_out = (s16)( (s32)re * FFT_POINTS / FFT_POINTS );  // no change needed
        s16 im_out = (s16)(-(s32)im * FFT_POINTS / FFT_POINTS );   // conjugate only

        // Simpler: just conjugate, the hardware already handles /N
        dst[n] = pack(re, -im);
    }
}

// ----------------------------------------------------------------
// DMA transfer: send src -> FFT HW -> write result to dst
// ----------------------------------------------------------------
static int run_fft_hw(u32 src_addr, u32 dst_addr) {
    // Flush src to DDR before DMA reads it
    Xil_DCacheFlushRange((UINTPTR)src_addr, DMA_SIZE);
    // Invalidate dst so CPU sees fresh data after DMA writes it
    Xil_DCacheInvalidateRange((UINTPTR)dst_addr, DMA_SIZE);

    // Start receiver FIRST (S2MM), then sender (MM2S)
    int status;
    status = XAxiDma_SimpleTransfer(&AxiDmaInstance,
                 (UINTPTR)dst_addr, DMA_SIZE, XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) return status;

    status = XAxiDma_SimpleTransfer(&AxiDmaInstance,
                 (UINTPTR)src_addr, DMA_SIZE, XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) return status;

    while (XAxiDma_Busy(&AxiDmaInstance, XAXIDMA_DMA_TO_DEVICE));
    while (XAxiDma_Busy(&AxiDmaInstance, XAXIDMA_DEVICE_TO_DMA));

    Xil_DCacheInvalidateRange((UINTPTR)dst_addr, DMA_SIZE);
    return XST_SUCCESS;
}

// ----------------------------------------------------------------
// Save a DDR buffer to a file on SD card
// ----------------------------------------------------------------
static int save_to_sd(const char *filename, u32 addr, UINT size) {
    FIL fil;
    FRESULT res;
    UINT bw;

    res = f_open(&fil, filename, FA_CREATE_ALWAYS | FA_WRITE);
    if (res != FR_OK) {
        xil_printf("ERROR: Cannot open %s for writing\n\r", filename);
        return XST_FAILURE;
    }

    res = f_write(&fil, (void *)addr, size, &bw);
    f_close(&fil);

    if (res != FR_OK || bw != size) {
        xil_printf("ERROR: Write failed for %s\n\r", filename);
        return XST_FAILURE;
    }
    xil_printf("  Saved %s (%d bytes)\n\r", filename, bw);
    return XST_SUCCESS;
}

// ----------------------------------------------------------------
// Main
// ----------------------------------------------------------------
int main() {
    FATFS fatfs;
    FIL fil_in;
    FRESULT res;
    UINT br;
    XAxiDma_Config *CfgPtr;

    xil_printf("\n\r--- SD Card FFT + IFFT Processing Start ---\n\r");

    // ---- DMA Init ----
    CfgPtr = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!CfgPtr) {
        xil_printf("ERROR: DMA config not found\n\r");
        return XST_FAILURE;
    }
    XAxiDma_CfgInitialize(&AxiDmaInstance, CfgPtr);
    if (XAxiDma_HasSg(&AxiDmaInstance)) {
        xil_printf("ERROR: DMA is in SG mode\n\r");
        return XST_FAILURE;
    }
    XAxiDma_IntrDisable(&AxiDmaInstance, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrDisable(&AxiDmaInstance, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);

    // ---- Clear all buffers ----
    memset((void *)DDR_INPUT,    0, DMA_SIZE);
    memset((void *)DDR_FFT_OUT,  0, DMA_SIZE);
    memset((void *)DDR_CONJ_BUF, 0, DMA_SIZE);
    memset((void *)DDR_IFFT_RAW, 0, DMA_SIZE);
    memset((void *)DDR_IFFT_OUT, 0, DMA_SIZE);

    // ---- Mount SD ----
    res = f_mount(&fatfs, "0:/", 1);
    if (res != FR_OK) {
        xil_printf("ERROR: SD mount failed\n\r");
        return XST_FAILURE;
    }

    // ================================================================
    // STEP 1: Load input from SD -> DDR_INPUT
    // ================================================================
    xil_printf("\n\rStep 1: Loading input from SD card...\n\r");

    res = f_open(&fil_in, "0:/INPUT.mem", FA_READ);
    if (res != FR_OK) {
        xil_printf("ERROR: Cannot open INPUT.mem\n\r");
        return XST_FAILURE;
    }

    FSIZE_t file_size = f_size(&fil_in);
    char *file_buffer = (char *)malloc(file_size + 1);
    if (!file_buffer) {
        xil_printf("ERROR: malloc failed — increase Heap in lscript.ld\n\r");
        f_close(&fil_in);
        return XST_FAILURE;
    }

    f_read(&fil_in, file_buffer, file_size, &br);
    file_buffer[br] = '\0';
    f_close(&fil_in);

    u32 *input_ptr = (u32 *)DDR_INPUT;
    int count = 0;
    char *line = strtok(file_buffer, "\r\n");
    while (line != NULL && count < FFT_POINTS) {
        input_ptr[count++] = (u32)strtoul(line, NULL, 16);
        line = strtok(NULL, "\r\n");
    }
    free(file_buffer);

    if (count != FFT_POINTS) {
        xil_printf("ERROR: Expected %d samples, got %d\n\r", FFT_POINTS, count);
        return XST_FAILURE;
    }

    xil_printf("  Loaded %d samples. First 4:\n\r", count);
    for (int i = 0; i < 4; i++)
        xil_printf("    [%d] = 0x%08X\n\r", i, input_ptr[i]);

    // STEP 1.5: HARDWARE PIPELINE RESET
           // The previous flush misaligned the internal SDF counters.
           // We must physically reset the PL fabric before sending the next frame.
           // ================================================================
           xil_printf("\n\rStep 1.5: Hard-Resetting PL Fabric...\n\r");

           Xil_Out32(0xF8000008, 0xDF0D); // Unlock the Zynq SLCR
           Xil_Out32(0xF8000240, 0x1);    // Assert FPGA0_OUT_RST (Reset the PL)
           for(volatile int i = 0; i < 10000; i++); // Wait for reset to propagate

           Xil_Out32(0xF8000240, 0x0);    // Deassert the Reset
           Xil_Out32(0xF8000004, 0x767B); // Lock the SLCR
           for(volatile int i = 0; i < 10000; i++); // Wait for clocks to stabilize

           // Because the AXI DMA lives in the PL, the reset just killed it.
           // We must wake it back up before Step 4!

    // ================================================================
    // STEP 2: FFT  (DDR_INPUT -> FFT HW -> DDR_FFT_OUT)
    // ================================================================
    xil_printf("\n\rStep 2: Running FFT...\n\r");

    if (run_fft_hw(DDR_INPUT, DDR_FFT_OUT) != XST_SUCCESS) {
        xil_printf("ERROR: FFT DMA failed\n\r");
        return XST_FAILURE;
    }
    xil_printf("  FFT complete.\n\r");

    // Save FFT result to SD
    if (save_to_sd("0:/RES_FFT.BIN", DDR_FFT_OUT, DMA_SIZE) != XST_SUCCESS)
        return XST_FAILURE;

    // ================================================================
    // STEP 3: Prepare IFFT input — conjugate the FFT output
    //         X*[k]: negate imag of every bin
    // ================================================================
    xil_printf("\n\rStep 3: Conjugating FFT output for IFFT input...\n\r");
    conjugate_buffer(DDR_FFT_OUT, DDR_CONJ_BUF);
    xil_printf("  Conjugation done.\n\r");

    // ================================================================
        // STEP 3.5: HARDWARE PIPELINE RESET
        // The previous flush misaligned the internal SDF counters.
        // We must physically reset the PL fabric before sending the next frame.
        // ================================================================
        xil_printf("\n\rStep 3.5: Hard-Resetting PL Fabric...\n\r");

        Xil_Out32(0xF8000008, 0xDF0D); // Unlock the Zynq SLCR
        Xil_Out32(0xF8000240, 0x1);    // Assert FPGA0_OUT_RST (Reset the PL)
        for(volatile int i = 0; i < 10000; i++); // Wait for reset to propagate

        Xil_Out32(0xF8000240, 0x0);    // Deassert the Reset
        Xil_Out32(0xF8000004, 0x767B); // Lock the SLCR
        for(volatile int i = 0; i < 10000; i++); // Wait for clocks to stabilize

        // Because the AXI DMA lives in the PL, the reset just killed it.
        // We must wake it back up before Step 4!
        XAxiDma_CfgInitialize(&AxiDmaInstance, CfgPtr);
        XAxiDma_IntrDisable(&AxiDmaInstance, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
        XAxiDma_IntrDisable(&AxiDmaInstance, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
        xil_printf("  PL Reset complete. DMA re-initialized.\n\r");


    // ================================================================
    // STEP 4: Second FFT pass  (DDR_CONJ_BUF -> FFT HW -> DDR_IFFT_RAW)
    //         This computes FFT( X*[k] ) = N * x*[n]  (time reversal + scale)
    // ================================================================
    xil_printf("\n\rStep 4: Running second FFT pass (IFFT trick)...\n\r");

    if (run_fft_hw(DDR_CONJ_BUF, DDR_IFFT_RAW) != XST_SUCCESS) {
        xil_printf("ERROR: IFFT DMA failed\n\r");
        return XST_FAILURE;
    }
    xil_printf("  Second pass complete.\n\r");

    // ================================================================
    // STEP 5: Final conjugate to get IFFT output
    //         IFFT(X)[n] = conj( FFT(conj(X))[n] ) / N
    //         The hardware already divides by N in its pipeline,
    //         so we only need to conjugate here.
    // ================================================================
    xil_printf("\n\rStep 5: Final conjugate -> IFFT output...\n\r");
    conjugate_buffer(DDR_IFFT_RAW, DDR_IFFT_OUT);
    xil_printf("  Done.\n\r");

    // ================================================================
    // STEP 6: Save IFFT result to SD
    // ================================================================
    xil_printf("\n\rStep 6: Saving results...\n\r");
    if (save_to_sd("0:/RES_IFFT.BIN", DDR_IFFT_OUT, DMA_SIZE) != XST_SUCCESS)
        return XST_FAILURE;

    // ================================================================
    // Debug: print first 8 IFFT output samples
    // ================================================================
    xil_printf("\n\r  IFFT output (first 8 samples):\n\r");
    u32 *ifft_ptr = (u32 *)DDR_IFFT_OUT;
    s16 re, im;
    for (int i = 0; i < 8; i++) {
        unpack(ifft_ptr[i], &re, &im);
        xil_printf("    x[%d] = real:%6d  imag:%6d\n\r", i, (int)re, (int)im);
    }
    xil_printf("  (Multiply real by %d to recover full-scale amplitude)\n\r", FFT_POINTS);

    // ---- Unmount ----
    f_mount(NULL, "0:/", 1);
    xil_printf("\n\r---- Process Finished ----\n\r");

    return 0;
}
