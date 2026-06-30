// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>
//
// Driver for the MAC accelerator control registers (mac_ctrl_regs.sv).

#pragma once

#include <stdint.h>
#include "config.h" // USER_BASE_ADDR, IRQ_MAC_DONE, IRQ_MAC_START

// The MAC control registers are the first block of the user domain.
#define MAC_BASE_ADDR USER_BASE_ADDR

// Register offsets (byte offset from MAC_BASE_ADDR); see mac_ctrl_regs.sv.
// Also used to build remote addresses for configuring MACs on other nodes.
#define MAC_MATRIX_BASE_OFFSET 0x00 // R/W base address of W in SRAM
#define MAC_VEC_LEN_OFFSET     0x04 // R/W number of elements per row (<= VecLen)
#define MAC_NUM_ROW_OFFSET     0x08 // R/W number of rows to compute
#define MAC_RESULT_OFFSET      0x0C // R   result of the last completed row
#define MAC_STATUS_OFFSET      0x10 // R   bit0 = done; reading clears the done IRQ
#define MAC_X_BASE_OFFSET      0x1C // R/W base address of x in SRAM
#define MAC_START_OFFSET       0x24 // W   start pulse; reading clears the start IRQ

// Configure the local MAC accelerator (does not start it).
void     mac_configure(uint32_t matrix_base_addr, uint32_t x_base_addr,
                       uint32_t vec_len, uint32_t num_row);
// Issue a one-cycle start pulse to the local MAC.
void     mac_start(void);
// Result of the most recently completed row.
uint32_t mac_get_result(void);
// Read STATUS (bit0 = done). NOTE: reading clears the MAC_DONE IRQ — call this
// from the interrupt handler to acknowledge it.
uint32_t mac_ack_done(void);
// Read the START register (pending start flag). NOTE: reading clears the
// MAC_START IRQ — call this from the interrupt handler to acknowledge it.
uint32_t mac_ack_start(void);
