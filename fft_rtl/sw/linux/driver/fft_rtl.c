// Copyright (c) 2011-2026 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#include <linux/of_device.h>
#include <linux/mm.h>

#include <asm/io.h>

#include <esp_accelerator.h>
#include <esp.h>

#include "fft_rtl.h"

#define DRV_NAME "fft_rtl"

#define FFT_BURST_LEN_REG 0x40
#define FFT_INDEX_REG     0x44
#define FFT_OUT_INDEX_REG 0x48
#define FFT_WINDOW_REG    0x4c
#define FFT_IFFT_REG      0x50

struct fft_rtl_device {
    struct esp_device esp;
};

static struct esp_driver fft_driver;

static struct of_device_id fft_device_ids[] = {
    {
        .name = "SLD_FFT_RTL",
    },
    {
        .name = "eb_89",
    },
    {
        .compatible = "sld,fft_rtl",
    },
    {},
};

static int fft_devs;

static inline struct fft_rtl_device *to_fft(struct esp_device *esp)
{
    return container_of(esp, struct fft_rtl_device, esp);
}

static void fft_prep_xfer(struct esp_device *esp, void *arg)
{
    struct fft_rtl_access *a = arg;

    iowrite32be(a->burst_len, esp->iomem + FFT_BURST_LEN_REG);
    iowrite32be(a->index, esp->iomem + FFT_INDEX_REG);
    iowrite32be(a->out_index, esp->iomem + FFT_OUT_INDEX_REG);
    iowrite32be(a->window, esp->iomem + FFT_WINDOW_REG);
    iowrite32be(a->ifft, esp->iomem + FFT_IFFT_REG);
    iowrite32be(a->src_offset, esp->iomem + SRC_OFFSET_REG);
    iowrite32be(a->dst_offset, esp->iomem + DST_OFFSET_REG);
}

static bool fft_xfer_input_ok(struct esp_device *esp, void *arg)
{
    return true;
}

static int fft_probe(struct platform_device *pdev)
{
    struct fft_rtl_device *fft;
    struct esp_device *esp;
    int rc;

    fft = kzalloc(sizeof(*fft), GFP_KERNEL);
    if (fft == NULL) return -ENOMEM;
    esp         = &fft->esp;
    esp->module = THIS_MODULE;
    esp->number = fft_devs;
    esp->driver = &fft_driver;
    rc          = esp_device_register(esp, pdev);
    if (rc) goto err;

    fft_devs++;
    return 0;
err:
    kfree(fft);
    return rc;
}

static int __exit fft_remove(struct platform_device *pdev)
{
    struct esp_device *esp      = platform_get_drvdata(pdev);
    struct fft_rtl_device *fft = to_fft(esp);

    esp_device_unregister(esp);
    kfree(fft);
    return 0;
}

static struct esp_driver fft_driver = {
    .plat =
        {
            .probe  = fft_probe,
            .remove = fft_remove,
            .driver =
                {
                    .name           = DRV_NAME,
                    .owner          = THIS_MODULE,
                    .of_match_table = fft_device_ids,
                },
        },
    .xfer_input_ok = fft_xfer_input_ok,
    .prep_xfer     = fft_prep_xfer,
    .ioctl_cm      = FFT_RTL_IOC_ACCESS,
    .arg_size      = sizeof(struct fft_rtl_access),
};

static int __init fft_init(void)
{
    return esp_driver_register(&fft_driver);
}

static void __exit fft_exit(void) { esp_driver_unregister(&fft_driver); }

module_init(fft_init) module_exit(fft_exit)

    MODULE_DEVICE_TABLE(of, fft_device_ids);

MODULE_AUTHOR("Columbia University, System Level Design Group");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("fft_rtl driver");
