# Copyright (c) 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Paul Scheffler <paulsc@iis.ee.ethz.ch>
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Toolchain
RISCV_XLEN    ?= 32
RISCV_MARCH   ?= rv$(RISCV_XLEN)im_zicsr
RISCV_MABI    ?= ilp32
RISCV_PREFIX  ?= riscv64-unknown-elf-
RISCV_CC      ?= $(RISCV_PREFIX)gcc
RISCV_CXX     ?= $(RISCV_PREFIX)g++
RISCV_OBJDUMP ?= $(RISCV_PREFIX)objdump
RISCV_OBJCOPY ?= $(RISCV_PREFIX)objcopy
RISCV_AS      ?= $(RISCV_PREFIX)as
RISCV_AR      ?= $(RISCV_PREFIX)ar
RISCV_LD      ?= $(RISCV_PREFIX)ld
RISCV_STRIP   ?= $(RISCV_PREFIX)strip

# Compiler and linker flags
RISCV_FLAGS ?= -march=$(RISCV_MARCH) -mabi=$(RISCV_MABI) -mcmodel=medany \
    -static -std=gnu99 -Os -nostdlib -fno-builtin -ffreestanding \
    -fno-tree-loop-distribute-patterns


VEC_LEN   ?= 128
NUM_ROWS  ?= 0

EXTRA_DEFINES :=
EXTRA_DEFINES += -DVEC_LEN=$(VEC_LEN)
ifneq ($(NUM_ROWS),0)
  EXTRA_DEFINES += -DNUM_ROWS=$(NUM_ROWS)
endif

RISCV_CCFLAGS ?= $(RISCV_FLAGS) -Iinclude -I$(INCDIR) -I$(CURDIR) $(EXTRA_DEFINES)
RISCV_LDFLAGS ?= -static -nostartfiles -lm -lgcc $(RISCV_FLAGS)


# Directory defaults
BINDIR   ?= bin
BUILDDIR ?= build
CRT0     ?= crt0.S
LINK     ?= link.ld
SRCDIR   ?= lib/src
INCDIR   ?= lib/inc

# Serial link / MAC test configuration  ← move these UP, before MAC_NODE_RULES
NUM_NODES  ?= 3
N_TESTS    ?= 5
NODE_IDS   = $(shell seq 1 $(NUM_NODES))

# MAC accelerator test configuration
MAC_TEST_SRC ?= test/test_mac_accel.c

MAC_TEST_LIB_SOURCES := $(SRCDIR)/serial_link.c $(SRCDIR)/sram_monitor.c $(SRCDIR)/mac_accelerator.c
MAC_TEST_LIB_OBJS    := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
                         $(basename $(MAC_TEST_LIB_SOURCES))))

MAC_NODE_TARGETS :=

define MAC_NODE_RULES
$(BUILDDIR)/mac_accel_test_node$(1).o: $(MAC_TEST_SRC)
	mkdir -p $$(dir $$@)
	$(RISCV_CC) $(RISCV_CCFLAGS) \
	    -DNODE_ID=$(1) -DNUM_NODES=$(NUM_NODES) -DN_TESTS=$(N_TESTS) \
	    -MMD -MP -c $$< -o $$@

$(BINDIR)/test/mac_accel_test_node$(1).elf: \
    $(BUILDDIR)/mac_accel_test_node$(1).o $(BUILDDIR)/crt0.o $(MAC_TEST_LIB_OBJS) $(LINK)
	mkdir -p $$(dir $$@)
	$(RISCV_CC) -o $$@ $$(filter-out $(LINK), $$^) $(RISCV_LDFLAGS) -T$(LINK)

$(BINDIR)/test/mac_accel_test_node$(1).dump: $(BINDIR)/test/mac_accel_test_node$(1).elf
	mkdir -p $$(dir $$@)
	$(RISCV_OBJDUMP) -D -s $$< > $$@

$(BINDIR)/test/mac_accel_test_node$(1).hex: $(BINDIR)/test/mac_accel_test_node$(1).elf
	mkdir -p $$(dir $$@)
	$(RISCV_OBJCOPY) -O verilog $$< $$@

MAC_NODE_TARGETS += \
    $(BINDIR)/test/mac_accel_test_node$(1).elf \
    $(BINDIR)/test/mac_accel_test_node$(1).dump \
    $(BINDIR)/test/mac_accel_test_node$(1).hex
endef

$(foreach id,$(NODE_IDS),$(eval $(call MAC_NODE_RULES,$(id))))

# Serial link ring test configuration
# NUM_NODES: total nodes in the system (default 3)
NUM_NODES  ?= 3
N_TESTS    ?= 5
NODE_IDS   = $(shell seq 1 $(NUM_NODES))

# Source file that contains the node-specific main()
SLINK_TEST_SRC ?= test/test_serial_link.c

SLINK_TEST_LIB_SOURCES := $(SRCDIR)/serial_link.c 
SLINK_TEST_LIB_OBJS    := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
                           $(basename $(SLINK_TEST_LIB_SOURCES))))


# Collecting source files
LIB_SOURCES  := $(wildcard $(SRCDIR)/*.[cS])
TOP_SOURCES  := $(filter-out $(CRT0), $(wildcard *.[cS]))
TEST_SOURCES := $(filter-out $(SLINK_TEST_SRC) $(MAC_TEST_SRC), $(wildcard test/*.[cS]))
PROG_SOURCES := $(TOP_SOURCES) $(TEST_SOURCES)

PROG_NAMES   := $(basename $(PROG_SOURCES))

# Creating object fiel list from source files
CRT0_OBJ  := $(BUILDDIR)/$(basename $(CRT0)).o
LIB_OBJS  := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
	         $(basename $(LIB_SOURCES))))
PROG_OBJS := $(addsuffix .o, $(addprefix $(BUILDDIR)/, \
	         $(basename $(PROG_SOURCES))))

# # Per-node object: compile the shared source with node-specific defines
define NODE_RULES
$(BUILDDIR)/serial_link_test_node$(1).o: $(SLINK_TEST_SRC)
	mkdir -p $$(dir $$@)
	$(RISCV_CC) $(RISCV_CCFLAGS) \
	    -DNODE_ID=$(1) -DNUM_NODES=$(NUM_NODES) -DN_TESTS=$(N_TESTS) \
	    -MMD -MP -c $$< -o $$@
 
# Link node ELF
$(BINDIR)/test/serial_link_test_node$(1).elf: \
    $(BUILDDIR)/serial_link_test_node$(1).o $(CRT0_OBJ) $(SLINK_TEST_LIB_OBJS) $(LINK)
	mkdir -p $$(dir $$@)
	$(RISCV_CC) -o $$@ $$(filter-out $(LINK), $$^) $(RISCV_LDFLAGS) -T$(LINK)

# Disassembly dump
$(BINDIR)/test/serial_link_test_node$(1).dump: $(BINDIR)/test/serial_link_test_node$(1).elf
	mkdir -p $$(dir $$@)
	$(RISCV_OBJDUMP) -D -s $$< > $$@

# Verilog hex
$(BINDIR)/test/serial_link_test_node$(1).hex: $(BINDIR)/test/serial_link_test_node$(1).elf
	mkdir -p $$(dir $$@)
	$(RISCV_OBJCOPY) -O verilog $$< $$@

# Collect into aggregate lists (appended each iteration)
NODE_TARGETS += \
    $(BINDIR)/test/serial_link_test_node$(1).elf \
    $(BINDIR)/test/serial_link_test_node$(1).dump \
    $(BINDIR)/test/serial_link_test_node$(1).hex
endef
 
# Instantiate rules for every node ID
$(foreach id,$(NODE_IDS),$(eval $(call NODE_RULES,$(id))))
 
# Everything to be built
ALL_TARGETS := $(PROG_NAMES:%=$(BINDIR)/%.elf) \
	           $(PROG_NAMES:%=$(BINDIR)/%.dump) \
	           $(PROG_NAMES:%=$(BINDIR)/%.hex)


# Dependency files for automatic rebuilds
DEPFILES := $(CRT0_OBJ:.o=.d) $(LIB_OBJS:.o=.d) $(PROG_OBJS:.o=.d) \
            $(foreach id,$(NODE_IDS),$(BUILDDIR)/serial_link_test_node$(id).d) \
            $(foreach id,$(NODE_IDS),$(BUILDDIR)/mac_accel_test_node$(id).d)
 
# Ensure intermediate object files are not deleted after linking
.SECONDARY: $(CRT0_OBJ) $(LIB_OBJS) $(PROG_OBJS) \
			$(foreach id,$(NODE_IDS),$(BUILDDIR)/serial_link_test_node$(id).o) \
			$(foreach id,$(NODE_IDS),$(BUILDDIR)/mac_accel_test_node$(id).o)


# Phonies
.PHONY: all compile test_serial_link test_mac_accel clean
test_mac_accel: $(BINDIR) $(BUILDDIR) $(MAC_NODE_TARGETS)
all: compile test_serial_link

# Build every non-node program (original behaviour)
compile: $(BINDIR) $(BUILDDIR) $(ALL_TARGETS)
 
# Build every node binary
test_serial_link: $(BINDIR) $(BUILDDIR) $(NODE_TARGETS)
 

$(BINDIR):
	mkdir -p $(BINDIR)

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Assembly to object compilation
$(BUILDDIR)/%.o: %.S
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

# C to object compilation
$(BUILDDIR)/%.o: %.c
	mkdir -p $(dir $@)
	$(RISCV_CC) $(RISCV_CCFLAGS) -MMD -MP -c $< -o $@

# Linking
$(BINDIR)/%.elf: $(BUILDDIR)/%.o $(CRT0_OBJ) $(LIB_OBJS) $(LINK)
	mkdir -p $(dir $@)
	$(RISCV_CC) -o $@ $(filter-out $(LINK), $^) $(RISCV_LDFLAGS) -T$(LINK)

# Dump ELF data and disassembly
$(BINDIR)/%.dump: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJDUMP) -D -s $< >$@

# Convert ELF to hex format for easy loading into simulators or hardware
$(BINDIR)/%.hex: $(BINDIR)/%.elf
	mkdir -p $(dir $@)
	$(RISCV_OBJCOPY) -O verilog $< $@


clean:
	rm -rf $(BINDIR) $(BUILDDIR)

-include $(DEPFILES)
