// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>
//
// Exercises the SRAM write/read monitor in all three modes via its interrupt.
// Scratch buffer lives in the 3rd 512x32 bank (gen_sram_bank[2]), which is
// outside the linker's SRAM region (banks 0-1), so it is free to use here.

#include "uart.h"
#include "print.h"
#include "util.h"
#include "config.h"
#include "sram_monitor.h"

#define SCRATCH_BASE 0x04001000UL  // bank 2 base
#define WINDOW_WORDS 32

static volatile int      irq_fired = 0;
static volatile uint32_t irq_cause = 0;

// Overrides the weak handler in crt0.S; the bootrom trap handler dispatches
// here on a local interrupt (see test_interrupts.c for the same pattern).
void croc_interrupt_handler(uint32_t cause) {
    irq_cause = cause;
    if (cause == IRQ_SRAM_MONITOR) {
        sram_monitor_ack();   // read STATUS to clear the level-high IRQ
        irq_fired = 1;
    }
}

// Wait (bounded) for the monitor interrupt.
static int wait_irq(void) {
    for (volatile int i = 0; i < 100000 && !irq_fired; i++)
        ;
    return irq_fired;
}

// Arm the monitor for a fresh measurement in the given mode.
static void arm(uint32_t mode, uint32_t threshold) {
    sram_monitor_disable();
    sram_monitor_clear();
    sram_monitor_set_threshold(threshold);
    sram_monitor_set_mode(mode);
    irq_fired = 0;
    irq_cause = 0;
    sram_monitor_enable();
    fence(); // ensure the monitor is armed before the accesses below
}

int main() {
    uart_init();
    volatile uint32_t *buf = (volatile uint32_t *)SCRATCH_BASE;
    volatile uint32_t  sink = 0;

    sram_monitor_set_window(SCRATCH_BASE, SCRATCH_BASE + (WINDOW_WORDS - 1) * 4);

    set_interrupt_enable(1, IRQ_SRAM_MONITOR);
    set_global_irq_enable(1);

    // ---- Test 1: WRITE mode, fire after 8 writes ----
    printf("Test 1: write mode (8 writes)\n");
    arm(SRAM_MONITOR_MODE_WRITE, 8);
    for (int i = 0; i < 8; i++) buf[i] = 0xA5A50000u | i;
    CHECK_ASSERT(1, wait_irq());
    CHECK_ASSERT(2, irq_cause == IRQ_SRAM_MONITOR);
    printf("  ok, irq fired\n");

    // ---- Test 2: READ mode, fire after 4 reads ----
    printf("Test 2: read mode (4 reads)\n");
    arm(SRAM_MONITOR_MODE_READ, 4);
    for (int i = 0; i < 4; i++) sink += buf[i];
    CHECK_ASSERT(3, wait_irq());
    printf("  ok, irq fired\n");

    // ---- Test 3: READ+WRITE mode, fire after 6 mixed accesses ----
    printf("Test 3: read+write mode (3 writes + 3 reads)\n");
    arm(SRAM_MONITOR_MODE_RW, 6);
    for (int i = 0; i < 3; i++) buf[i]  = i;
    for (int i = 0; i < 3; i++) sink   += buf[i];
    CHECK_ASSERT(4, wait_irq());
    printf("  ok, irq fired\n");

    // ---- Test 4: READ mode ignores writes (negative test) ----
    printf("Test 4: read mode ignores writes\n");
    arm(SRAM_MONITOR_MODE_READ, 4);
    for (int i = 0; i < 8; i++) buf[i] = i;  // writes only -> must NOT fire
    for (volatile int i = 0; i < 20000; i++) ;
    CHECK_ASSERT(5, irq_fired == 0);
    printf("  ok, no irq from writes\n");

    (void)sink;
    sram_monitor_disable();
    set_interrupt_enable(0, IRQ_SRAM_MONITOR);
    set_global_irq_enable(0);

    printf("All sram_monitor tests passed\n");
    uart_write_flush();
    return 0;
}
