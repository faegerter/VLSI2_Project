// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>
//
// Driver for the SRAM write/read monitor (rtl/sram_monitor/sram_monitor.sv).
// Counts accesses to a configurable address window of the 3rd 512x32 SRAM bank
// and raises interrupt IRQ_SRAM_MONITOR after a programmable number of accesses.

#pragma once

#include <stdint.h>
#include "config.h" // SRAM_MONITOR_BASE_ADDR, IRQ_SRAM_MONITOR

// Register offsets
#define SRAM_MONITOR_CTRL_OFFSET      0x00 // bit0 enable, bit1 clear (W1)
#define SRAM_MONITOR_THRESHOLD_OFFSET 0x04
#define SRAM_MONITOR_COUNT_OFFSET     0x08 // RO
#define SRAM_MONITOR_STATUS_OFFSET    0x0C // RO, read clears the IRQ
#define SRAM_MONITOR_START_OFFSET     0x10
#define SRAM_MONITOR_END_OFFSET       0x14
#define SRAM_MONITOR_MODE_OFFSET      0x18

// CTRL bits
#define SRAM_MONITOR_CTRL_ENABLE (1u << 0)
#define SRAM_MONITOR_CTRL_CLEAR  (1u << 1)

// MODE values: which accesses are counted
#define SRAM_MONITOR_MODE_WRITE 0u
#define SRAM_MONITOR_MODE_READ  1u
#define SRAM_MONITOR_MODE_RW    2u

// Track only accesses with start_addr <= addr <= end_addr (inclusive).
void     sram_monitor_set_window(uint32_t start_addr, uint32_t end_addr);
// Number of in-window accesses after which the IRQ fires (0 disables firing).
void     sram_monitor_set_threshold(uint32_t words);
// One of SRAM_MONITOR_MODE_{WRITE,READ,RW}.
void     sram_monitor_set_mode(uint32_t mode);
void     sram_monitor_enable(void);
void     sram_monitor_disable(void);
// Reset COUNT and the pending IRQ (keeps the current enable state).
void     sram_monitor_clear(void);
// Current in-window access count.
uint32_t sram_monitor_count(void);
// Read STATUS: returns 1 if an IRQ was pending. NOTE: reading clears the IRQ,
// so call this from the interrupt handler to acknowledge it.
uint32_t sram_monitor_ack(void);
