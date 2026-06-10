// SPDX-License-Identifier: GPL-2.0
//
// pccx_cci_snoop — EL1-level CCI-400 snoop register probe + write.
//
// Purpose: discriminate whether the KV260's CCI-400 register space is
//   (a) non-secure but blocked from /dev/mem → EL1 (this module) can read/write
//       and we'll see snoop bits flip → ACP path should unblock → simplest fix
//   (b) TrustZone-secure → ioread32 / iowrite32 will trigger a synchronous
//       external abort visible in dmesg → confirms baremetal/ATF is required
//
// Inputs:  none (params optional below)
// Outputs: all evidence to dmesg with the "pccx-cci:" prefix.
//
// CCI-400 register offsets per UG1085 ZynqMP TRM + Xilinx CCI-400 PG:
//   base                         = 0xFD6E0000
//   Control / status (early)     = 0x0000, 0x000C
//   Slave interface N SNOOP_CTRL = 0x1004 + 0x1000 * N   for N = 1..6
//     S3 SNOOP_CTRL = 0x4004   (ACP candidate)
//     S4 SNOOP_CTRL = 0x5004
//     S5 SNOOP_CTRL = 0x6004
//   bit[0] = snoop enable, bit[1] = DVM enable
//
// usage:
//   make -C /lib/modules/$(uname -r)/build M=$(pwd) modules
//   sudo insmod pccx_cci_snoop.ko             # read snoop bits, then write 0x3
//   sudo insmod pccx_cci_snoop.ko write=0     # read-only probe (safer first)
//   dmesg | tail
//   sudo rmmod pccx_cci_snoop

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/moduleparam.h>

#define CCI_400_BASE        0xFD6E0000
#define CCI_400_SIZE        0x10000
#define CCI_CONTROL_OFF     0x0000
#define CCI_STATUS_OFF      0x000C
#define S3_SNOOP_CTRL_OFF   0x4004
#define S4_SNOOP_CTRL_OFF   0x5004
#define S5_SNOOP_CTRL_OFF   0x6004
#define SNOOP_DVM_ENABLE    0x3

static int write = 1;    // default: probe then write. set write=0 to read-only.
module_param(write, int, 0444);
MODULE_PARM_DESC(write, "1 = write snoop+DVM after read (default), 0 = read only");

MODULE_LICENSE("GPL");
MODULE_AUTHOR("PCCX");
MODULE_DESCRIPTION("ZynqMP CCI-400 snoop probe — discriminate EL0 SIGBUS vs EL1 access");

static void __iomem *cci;

static u32 safe_read(const char *label, unsigned int off)
{
	u32 v = ioread32(cci + off);
	pr_info("pccx-cci: READ  %-20s @0x%08x = 0x%08x\n",
		label, CCI_400_BASE + off, v);
	return v;
}

static void safe_write(const char *label, unsigned int off, u32 val)
{
	pr_info("pccx-cci: WRITE %-20s @0x%08x <- 0x%08x\n",
		label, CCI_400_BASE + off, val);
	iowrite32(val, cci + off);
	wmb();
}

static int __init pccx_cci_init(void)
{
	u32 ctrl, sts;
	u32 s3_before, s4_before, s5_before;
	u32 s3_after = 0, s4_after = 0, s5_after = 0;

	pr_info("pccx-cci: init (write=%d) — ioremap 0x%08x len 0x%x\n",
		write, CCI_400_BASE, CCI_400_SIZE);

	cci = ioremap(CCI_400_BASE, CCI_400_SIZE);
	if (!cci) {
		pr_err("pccx-cci: ioremap failed — kernel may have reserved this region\n");
		return -ENOMEM;
	}
	pr_info("pccx-cci: ioremap OK at kva=%px\n", cci);

	/* If the next four reads trigger a Synchronous External Abort in dmesg
	 * (look for "SError", "synchronous external abort", "Internal error: Oops"),
	 * the CCI-400 register window is TrustZone-secure and EL1 cannot touch it
	 * → baremetal / ATF is required.  No SError = non-secure (EL1 OK).
	 */
	ctrl       = safe_read("CCI Control",     CCI_CONTROL_OFF);
	sts        = safe_read("CCI Status",      CCI_STATUS_OFF);
	s3_before  = safe_read("S3 SNOOP_CTRL",   S3_SNOOP_CTRL_OFF);
	s4_before  = safe_read("S4 SNOOP_CTRL",   S4_SNOOP_CTRL_OFF);
	s5_before  = safe_read("S5 SNOOP_CTRL",   S5_SNOOP_CTRL_OFF);

	if (write) {
		safe_write("S3 SNOOP_CTRL",   S3_SNOOP_CTRL_OFF, SNOOP_DVM_ENABLE);
		safe_write("S4 SNOOP_CTRL",   S4_SNOOP_CTRL_OFF, SNOOP_DVM_ENABLE);
		safe_write("S5 SNOOP_CTRL",   S5_SNOOP_CTRL_OFF, SNOOP_DVM_ENABLE);

		s3_after = safe_read("S3 SNOOP_CTRL",  S3_SNOOP_CTRL_OFF);
		s4_after = safe_read("S4 SNOOP_CTRL",  S4_SNOOP_CTRL_OFF);
		s5_after = safe_read("S5 SNOOP_CTRL",  S5_SNOOP_CTRL_OFF);

		pr_info("pccx-cci: VERDICT S3 %s (0x%x -> 0x%x)\n",
			s3_after != s3_before ? "FLIPPED" : "unchanged",
			s3_before, s3_after);
		pr_info("pccx-cci: VERDICT S4 %s (0x%x -> 0x%x)\n",
			s4_after != s4_before ? "FLIPPED" : "unchanged",
			s4_before, s4_after);
		pr_info("pccx-cci: VERDICT S5 %s (0x%x -> 0x%x)\n",
			s5_after != s5_before ? "FLIPPED" : "unchanged",
			s5_before, s5_after);
	}

	pr_info("pccx-cci: init complete — leave module loaded while running "
		"dbg_step_03_cmdsts_single_acp.py to test if ACP path unblocks\n");

	return 0;
}

static void __exit pccx_cci_exit(void)
{
	if (cci) {
		iounmap(cci);
		cci = NULL;
	}
	pr_info("pccx-cci: exit\n");
}

module_init(pccx_cci_init);
module_exit(pccx_cci_exit);
