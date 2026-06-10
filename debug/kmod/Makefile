obj-m := pccx_cci_snoop.o pccx_cci_smc.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	@echo "Use: sudo insmod pccx_cci_snoop.ko       # default: read + write"
	@echo "  or sudo insmod pccx_cci_snoop.ko write=0   # read-only probe"
	@echo "Then: dmesg | tail -30"
	@echo "Unload: sudo rmmod pccx_cci_snoop"
