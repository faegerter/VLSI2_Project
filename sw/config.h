// Copyright 2022 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Nils Wistoff <nwistoff@iis.ee.ethz.ch>
// Paul Scheffler <paulsc@iis.ee.ethz.ch>

#pragma once

// Address map
#define DEBUG_BASE_ADDR       0x00000000
#define BOOTROM_BASE_ADDR     0x02000000
#define CLINT_BASE_ADDR       0x02040000
#define SOCCTRL_BASE_ADDR     0x03000000
#define UART_BASE_ADDR        0x03002000
#define GPIO_BASE_ADDR        0x03005000
#define SRAM_MONITOR_BASE_ADDR 0x03006000
#define OBI_TIMER_BASE_ADDR   0x0300A000
#define IDMA_BASE_ADDR        0x0300B000
#define SRAM_BANK_0_BASE_ADDR 0x04000000
#define SRAM_BANK_1_BASE_ADDR 0x04000800
#define SRAM_BANK_2_BASE_ADDR 0x04001000
#define SRAM_BANK_3_BASE_ADDR 0x04001800
#define USER_BASE_ADDR        0x0FFFE000
#define SLINK_CFG_BASE_ADDR   0X0FFFF000
#define SLINK_RING_BASE_ADDR  0x10000000
#define USER_ROM_BASE_ADDR    0x0FFFE200


// Frequencies
#define TB_FREQUENCY        80000000
#define TB_BAUDRATE         115200

// Peripheral configs
// UART
#define UART_BYTE_ALIGN     4
#define UART_FREQ           TB_FREQUENCY
#define UART_BAUD           TB_BAUDRATE

// Interrupts
#define IRQ_SOFTWARE        3
#define IRQ_TIMER           7
#define IRQ_EXTERNAL        11
#define IRQ_OBI_TIMER       16
#define IRQ_UART            17
#define IRQ_GPIO            18
#define IRQ_IDMA            19
#define IRQ_MAC_DONE        20  // MAC accelerator: per-row completion
#define IRQ_MAC_START       22  // MAC accelerator: start signal (remote nodes)
// External IRQs occupy lines 20..(20+NumExternalIrqs-1); SRAM monitor follows.
#define IRQ_SRAM_MONITOR    24
