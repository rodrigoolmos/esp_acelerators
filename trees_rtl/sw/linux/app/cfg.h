// Copyright (c) 2011-2024 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#ifndef __ESP_CFG_000_H__
#define __ESP_CFG_000_H__

#include "libesp.h"
#include "trees_rtl.h"

typedef int64_t token_t;

/* <<--params-def-->> */
#define BURST_LEN 128
#define LOAD_TREES 0

/* <<--params-->> */
const int32_t burst_len = BURST_LEN;
const int32_t load_trees = LOAD_TREES;

#define NACC 1

struct trees_rtl_access trees_cfg_000[] = {{
    /* <<--descriptor-->> */
		.burst_len = BURST_LEN,
		.load_trees = LOAD_TREES,
    .src_offset    = 0,
    .dst_offset    = 0,
    .esp.coherence = ACC_COH_NONE,
    .esp.p2p_store = 0,
    .esp.p2p_nsrcs = 0,
    .esp.p2p_srcs  = {"", "", "", ""},
}};

esp_thread_info_t cfg_000[] = {{
    .run       = true,
    .devname   = "trees_rtl.0",
    .ioctl_req = TREES_RTL_IOC_ACCESS,
    .esp_desc  = &(trees_cfg_000[0].esp),
}};

#endif /* __ESP_CFG_000_H__ */
