// Copyright (c) 2011-2026 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#ifndef __FFT_RTL_CFG_000_H__
#define __FFT_RTL_CFG_000_H__

#include "libesp.h"
#include "fft_rtl.h"

typedef uint64_t token_t;

#define FFT_SIZE 4096
#define FFT_BITS 12
#define MAX_FFT_FRAMES 16
#define FFT_HW_FRAMES_PER_RUN 5
#define DEFAULT_FFT_FRAMES 1
#define DEFAULT_TOLERANCE 0.25f

#define BURST_LEN DEFAULT_FFT_FRAMES
#define INDEX 0
#define OUT_INDEX FFT_SIZE
#define WINDOW 0
#define IFFT 0

static const int32_t fft_burst_len = BURST_LEN;
static const int32_t fft_index = INDEX;
static const int32_t fft_out_index = OUT_INDEX;
static const int32_t fft_window = WINDOW;
static const int32_t fft_ifft = IFFT;

#define NACC 1

static struct fft_rtl_access fft_cfg_000[] = {{
    .burst_len    = BURST_LEN,
    .index        = INDEX,
    .out_index    = OUT_INDEX,
    .window       = WINDOW,
    .ifft         = IFFT,
    .src_offset   = 0,
    .dst_offset   = 0,
    .esp.coherence = ACC_COH_NONE,
    .esp.p2p_store = 0,
    .esp.p2p_nsrcs = 0,
    .esp.p2p_srcs  = {"", "", "", ""},
}};

static esp_thread_info_t cfg_000[] = {{
    .run       = true,
    .devname   = "fft_rtl.0",
    .ioctl_req = FFT_RTL_IOC_ACCESS,
    .esp_desc  = &(fft_cfg_000[0].esp),
}};

#endif /* __FFT_RTL_CFG_000_H__ */
