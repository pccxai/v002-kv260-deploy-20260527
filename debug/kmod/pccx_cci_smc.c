// SPDX-License-Identifier: GPL-2.0
//
// pccx_cci_smc — Enable CCI-400 ACP snoop via ATF SMC (PM_MMIO_WRITE).
//
// Path: Linux kernel module → arm_smccc_smc → ATF EL3 → CCI register write
// vs the failed direct-ioremap path:
//   * EL0 (/dev/mem)            → SIGBUS                    (dbg_step_06)
//   * EL1 (ioremap + ioread32)  → Synchronous External Abort + oops
//   * EL1 (this) via SMC SiP    → ATF handles in EL3        ← we test now
//
// Uses the exported zynqmp_pm_mmio_read / zynqmp_pm_mmio_write helpers in
// drivers/firmware/xilinx/zynqmp.c (Linux 5.15 xilinx-zynqmp).  These wrap
// PM_MMIO_READ (PM API ID 18) / PM_MMIO_WRITE (PM API ID 19) over arm_smccc_smc
// with Xilinx SiP SVC ID 0xC2000000.  The ATF whitelists which physical
// address ranges are accessible — if CCI-400 (0xFD6E0000+) is whitelisted,
// the call returns 0.  If not, it returns a negative errno without trapping.
//
// usage:
//   make
//   sudo insmod pccx_cci_smc.ko             # default: probe S3+S4+S5 read+write
//   sudo insmod pccx_cci_smc.ko probe=1     # read-only probe
//   dmesg | tail -40
//   sudo rmmod pccx_cci_smc

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/moduleparam.h>

// header is provided by linux-headers package; if missing, the declarations
// below are the canonical signatures from drivers/firmware/xilinx/zynqmp.c.
#if __has_include(<linux/firmware/xlnx-zynqmp.h>)
#  include <linux/firmware/xlnx-zynqmp.h>
#else
extern int zynqmp_pm_mmio_read(u32 address, u32 *value);
extern int zynqmp_pm_mmio_write(u32 address, u32 mask, u32 value);
#endif

#define CCI_400_BASE        0xFD6E0000U
#define CCI_CONTROL_OFF     0x0000
#define CCI_STATUS_OFF      0x000C
#define S3_SNOOP_OFF        0x4004
#define S4_SNOOP_OFF        0x5004
#define S5_SNOOP_OFF        0x6004
#define SNOOP_DVM_ENABLE    0x3U

static int probe = 0;
module_param(probe, int, 0444);
MODULE_PARM_DESC(probe, "1 = read only, 0 = read + write + readback (default)");

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PCCX");
MODULE_DESCRIPTION("Enable ZynqMP CCI-400 ACP snoop via ATF SMC PM_MMIO_WRITE");

struct probe_entry {
	const char *label;
	u32 offset;
};

static const struct probe_entry entries[] = {
	{ "CCI Control      ", CCI_CONTROL_OFF },
	{ "CCI Status       ", CCI_STATUS_OFF  },
	{ "S3 SNOOP_CTRL    ", S3_SNOOP_OFF    },
	{ "S4 SNOOP_CTRL    ", S4_SNOOP_OFF    },
	{ "S5 SNOOP_CTRL    ", S5_SNOOP_OFF    },
};

static int smc_read(const char *label, u32 off, u32 *val)
{
	int ret = zynqmp_pm_mmio_read(CCI_400_BASE + off, val);
	if (ret == 0)
		pr_info("pccx-cci-smc: READ  %s @0x%08x = 0x%08x  (ATF OK)\n",
			label, CCI_400_BASE + off, *val);
	else
		pr_warn("pccx-cci-smc: READ  %s @0x%08x DENIED  ret=%d\n",
			label, CCI_400_BASE + off, ret);
	return ret;
}

static int smc_write(const char *label, u32 off, u32 val)
{
	int ret = zynqmp_pm_mmio_write(CCI_400_BASE + off, 0xFFFFFFFFU, val);
	if (ret == 0)
		pr_info("pccx-cci-smc: WRITE %s @0x%08x <- 0x%08x  (ATF OK)\n",
			label, CCI_400_BASE + off, val);
	else
		pr_warn("pccx-cci-smc: WRITE %s @0x%08x <- 0x%08x DENIED  ret=%d\n",
			label, CCI_400_BASE + off, val, ret);
	return ret;
}

static int __init pccx_cci_smc_init(void)
{
	size_t i;
	u32 before[ARRAY_SIZE(entries)] = {0};
	u32 after [ARRAY_SIZE(entries)] = {0};
	int  rread[ARRAY_SIZE(entries)] = {0};
	int  rwrite[ARRAY_SIZE(entries)] = {0};
	int  rreadback[ARRAY_SIZE(entries)] = {0};
	int  any_write_ok = 0;
	int  any_flip = 0;

	pr_info("pccx-cci-smc: init (probe=%d) — ATF SiP PM_MMIO path\n", probe);

	for (i = 0; i < ARRAY_SIZE(entries); i++)
		rread[i] = smc_read(entries[i].label, entries[i].offset, &before[i]);

	if (!probe) {
		// only write the S3..S5 entries (skip control/status)
		for (i = 2; i < ARRAY_SIZE(entries); i++) {
			rwrite[i] = smc_write(entries[i].label,
					      entries[i].offset, SNOOP_DVM_ENABLE);
			if (rwrite[i] == 0)
				any_write_ok = 1;
		}
		for (i = 0; i < ARRAY_SIZE(entries); i++) {
			rreadback[i] = smc_read(entries[i].label,
						entries[i].offset, &after[i]);
			if (rreadback[i] == 0 && after[i] != before[i])
				any_flip = 1;
		}

		pr_info("pccx-cci-smc: VERDICT any_write_accepted=%d any_register_flipped=%d\n",
			any_write_ok, any_flip);
		if (any_write_ok && any_flip)
			pr_info("pccx-cci-smc: ★ SUCCESS — ATF whitelisted CCI-400; snoop bits flipped.\n");
		else if (any_write_ok && !any_flip)
			pr_warn("pccx-cci-smc: write returned OK but registers did NOT change "
				"— silent reject at NoC/SCR layer\n");
		else
			pr_warn("pccx-cci-smc: ATF denied every write — CCI-400 is OUTSIDE the "
				"PM_MMIO whitelist.  Fix path = patch ATF source.\n");
	}

	return 0;
}

static void __exit pccx_cci_smc_exit(void)
{
	pr_info("pccx-cci-smc: exit\n");
}

module_init(pccx_cci_smc_init);
module_exit(pccx_cci_smc_exit);
