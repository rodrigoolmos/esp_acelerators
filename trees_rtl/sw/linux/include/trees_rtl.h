// Copyright (c) 2011-2024 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#ifndef _TREES_RTL_H_
#define _TREES_RTL_H_

#ifdef __KERNEL__
    #include <linux/ioctl.h>
    #include <linux/types.h>
#else
    #include <sys/ioctl.h>
    #include <stdint.h>
    #ifndef __user
        #define __user
    #endif
#endif /* __KERNEL__ */

#include <esp.h>
#include <esp_accelerator.h>

struct trees_rtl_access {
    struct esp_access esp;
    /* <<--regs-->> */
	unsigned burst_len;
	unsigned load_trees;
    unsigned src_offset;
    unsigned dst_offset;
};

#define TREES_RTL_IOC_ACCESS _IOW('S', 0, struct trees_rtl_access)

#endif /* _TREES_RTL_H_ */
