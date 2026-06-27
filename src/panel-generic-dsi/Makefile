# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2024 ROCKNIX (https://github.com/ROCKNIX)

obj-m += panel-generic-dsi.o

# Kernel build directory (set by parent Makefile)
KERNEL_SRC ?= ../linux-6-16-sprd
PANEL_DSI_SRC ?= $(realpath .)

all:
	$(MAKE) -C $(KERNEL_SRC) M=$(PANEL_DSI_SRC) modules

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(PANEL_DSI_SRC) clean

install:
	$(MAKE) -C $(KERNEL_SRC) M=$(PANEL_DSI_SRC) INSTALL_MOD_PATH=$(INSTALL_MOD_PATH) modules_install

.PHONY: all clean install