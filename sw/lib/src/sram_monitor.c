// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>

#include "sram_monitor.h"
#include "util.h"

#define BASE SRAM_MONITOR_BASE_ADDR

void sram_monitor_set_window(uint32_t start_addr, uint32_t end_addr) {
    *reg32(BASE, SRAM_MONITOR_START_OFFSET) = start_addr;
    *reg32(BASE, SRAM_MONITOR_END_OFFSET)   = end_addr;
}

void sram_monitor_set_threshold(uint32_t words) {
    *reg32(BASE, SRAM_MONITOR_THRESHOLD_OFFSET) = words;
}

void sram_monitor_set_mode(uint32_t mode) {
    *reg32(BASE, SRAM_MONITOR_MODE_OFFSET) = mode;
}

void sram_monitor_enable(void) {
    *reg32(BASE, SRAM_MONITOR_CTRL_OFFSET) = SRAM_MONITOR_CTRL_ENABLE;
}

void sram_monitor_disable(void) {
    *reg32(BASE, SRAM_MONITOR_CTRL_OFFSET) = 0u;
}

void sram_monitor_clear(void) {
    // CTRL reads back the current enable bit (clear bit reads 0); OR in the
    // self-clearing CLEAR bit so the counter/IRQ reset without changing enable.
    uint32_t ctrl = *reg32(BASE, SRAM_MONITOR_CTRL_OFFSET);
    *reg32(BASE, SRAM_MONITOR_CTRL_OFFSET) = ctrl | SRAM_MONITOR_CTRL_CLEAR;
}

uint32_t sram_monitor_count(void) {
    return *reg32(BASE, SRAM_MONITOR_COUNT_OFFSET);
}

uint32_t sram_monitor_ack(void) {
    return *reg32(BASE, SRAM_MONITOR_STATUS_OFFSET) & 1u;
}
