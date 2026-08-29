// Copyright (c) 2011-2024 Columbia University, System Level Design Group
// SPDX-License-Identifier: Apache-2.0
#include <linux/of_device.h>
#include <linux/mm.h>

#include <asm/io.h>

#include <esp_accelerator.h>
#include <esp.h>

#include "trees_rtl.h"

#define DRV_NAME "trees_rtl"

/* <<--regs-->> */
#define TREES_BURST_LEN_REG 0x44
#define TREES_LOAD_TREES_REG 0x40

struct trees_rtl_device {
    struct esp_device esp;
};

static struct esp_driver trees_driver;

static struct of_device_id trees_device_ids[] = {
    {
        .name = "SLD_TREES_RTL",
    },
    {
        .name = "eb_88",
    },
    {
        .compatible = "sld,trees_rtl",
    },
    {},
};

static int trees_devs;

static inline struct trees_rtl_device *to_trees(struct esp_device *esp)
{
    return container_of(esp, struct trees_rtl_device, esp);
}

static void trees_prep_xfer(struct esp_device *esp, void *arg)
{
    struct trees_rtl_access *a = arg;

    /* <<--regs-config-->> */
	iowrite32be(a->burst_len, esp->iomem + TREES_BURST_LEN_REG);
	iowrite32be(a->load_trees, esp->iomem + TREES_LOAD_TREES_REG);
    iowrite32be(a->src_offset, esp->iomem + SRC_OFFSET_REG);
    iowrite32be(a->dst_offset, esp->iomem + DST_OFFSET_REG);
}

static bool trees_xfer_input_ok(struct esp_device *esp, void *arg)
{
    /* struct trees_rtl_device *trees = to_trees(esp); */
    /* struct trees_rtl_access *a = arg; */

    return true;
}

static int trees_probe(struct platform_device *pdev)
{
    struct trees_rtl_device *trees;
    struct esp_device *esp;
    int rc;

    trees = kzalloc(sizeof(*trees), GFP_KERNEL);
    if (trees == NULL) return -ENOMEM;
    esp         = &trees->esp;
    esp->module = THIS_MODULE;
    esp->number = trees_devs;
    esp->driver = &trees_driver;
    rc          = esp_device_register(esp, pdev);
    if (rc) goto err;

    trees_devs++;
    return 0;
err:
    kfree(trees);
    return rc;
}

static int __exit trees_remove(struct platform_device *pdev)
{
    struct esp_device *esp                        = platform_get_drvdata(pdev);
    struct trees_rtl_device *trees = to_trees(esp);

    esp_device_unregister(esp);
    kfree(trees);
    return 0;
}

static struct esp_driver trees_driver = {
    .plat =
        {
            .probe  = trees_probe,
            .remove = trees_remove,
            .driver =
                {
                    .name           = DRV_NAME,
                    .owner          = THIS_MODULE,
                    .of_match_table = trees_device_ids,
                },
        },
    .xfer_input_ok = trees_xfer_input_ok,
    .prep_xfer     = trees_prep_xfer,
    .ioctl_cm      = TREES_RTL_IOC_ACCESS,
    .arg_size      = sizeof(struct trees_rtl_access),
};

static int __init trees_init(void)
{
    return esp_driver_register(&trees_driver);
}

static void __exit trees_exit(void) { esp_driver_unregister(&trees_driver); }

module_init(trees_init) module_exit(trees_exit)

    MODULE_DEVICE_TABLE(of, trees_device_ids);

MODULE_AUTHOR("Emilio G. Cota <cota@braap.org>");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("trees_rtl driver");
