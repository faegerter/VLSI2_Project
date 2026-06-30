// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>


#include "util.h"
#include "serial_link.h"
#include "config.h"
#include "sram_monitor.h"
#include "mac_accelerator.h"

// ---------------------------------------------------------------------------
// Compile-time configuration
// ---------------------------------------------------------------------------

#ifndef NUM_NODES
#define NUM_NODES 2
#endif
#ifndef NODE_ID
#error "NODE_ID not defined"
#endif
#ifndef N_TESTS
#define N_TESTS 1
#endif
#ifndef VEC_LEN
#define VEC_LEN  128
#endif
#ifndef NUM_ROWS
#define NUM_ROWS (NUM_NODES * 2)
#endif

#define USE_MAC_ACCEL  // Uncomment to use the hardware MAC accelerator

// ---------------------------------------------------------------------------
// Memory map
// ---------------------------------------------------------------------------

#define Y_RETURN_BASE   0x04000800UL  // Result vector y   (NUM_ROWS × 4 B)
#define X_VEC_BASE      0x04001000UL  // Input vector x
#define W_MATRIX_BASE   0x04001800UL  // Weight matrix W
#define TIMING_ADDRESS  0x04000F00UL  // Cycle-count storage

// MAC accelerator base address and register offsets come from mac_accelerator.h.

// ---------------------------------------------------------------------------
// Serial-link addressing
// ---------------------------------------------------------------------------

#define ADDR_DEST_SHIFT  28U
#define REMOTE_ADDR(dst, base, off) \
    (((uint32_t)(dst) << ADDR_DEST_SHIFT) | ((uint32_t)(base) + (uint32_t)(off)))

// ---------------------------------------------------------------------------
// Node geometry
// ---------------------------------------------------------------------------

#define ROWS_PER_NODE    (NUM_ROWS / NUM_NODES)
#define NODE_ROW_OFFSET  ((NODE_ID - 1) * ROWS_PER_NODE)

// ---------------------------------------------------------------------------
// Serial-link TX clock configuration
// ---------------------------------------------------------------------------

#define STOP_NODE_TX             1
#define START_NODE_TX            0
#define SLINK_TX_CLK_DIV_4_START 1
#define SLINK_TX_CLK_DIV_4_END   3

// IRQ_MAC_DONE / IRQ_MAC_START come from config.h.

// ---------------------------------------------------------------------------
// Verification constant
// W[i][j] = 1, x[i] = i+1  →  every y[r] = sum_{i=1}^{VEC_LEN} i
// ---------------------------------------------------------------------------

#define EXPECTED_Y  ((uint32_t)(VEC_LEN) * ((uint32_t)(VEC_LEN) + 1U) / 2U)

// ---------------------------------------------------------------------------
// Shared ISR state
// ---------------------------------------------------------------------------

#ifdef USE_MAC_ACCEL
static volatile int      irq_fired      = 0;  // MAC_DONE IRQ count within the current burst
static volatile int      all_rows_done  = 0;  // Set when this node finishes all its rows
static volatile uint32_t result_to_send = 0;  // MAC result latched in the last IRQ
static volatile int      row_count      = 0;  // Row index of the last completed result
#endif

static volatile int  y_all_received    = 0;  // Set (Node 1 only) when SRAM monitor fires
static volatile int  mac_start_received = 0; // Set when IRQ_MAC_START fires

// ---------------------------------------------------------------------------
// Interrupt handler
//
// IRQ_MAC_DONE (accelerator mode, all nodes):
//   Node 1   — writes result directly to local Y_RETURN_BASE.
//   Node N>1 — ships result to Node 1 via serial link.
//   Resets irq_fired and sets all_rows_done after the last row in the burst.
//
// IRQ_MAC_START (remote nodes, software mode):
//   Clears the pending IRQ and signals the main loop to begin computation.
//
// IRQ_SRAM_MONITOR (Node 1 only):
//   Fired once all NUM_ROWS entries of y[] have been written (local or
//   remote). Acknowledges the monitor and sets y_all_received.
// ---------------------------------------------------------------------------

void croc_interrupt_handler(uint32_t cause)
{
#ifdef USE_MAC_ACCEL
    if (cause == IRQ_MAC_DONE) {
        result_to_send = mac_get_result();
        row_count      = irq_fired;
        (void)mac_ack_done();  // Read STATUS clears the done IRQ

        if (NODE_ID == 1) {
            volatile uint32_t *y = (volatile uint32_t *)Y_RETURN_BASE;
            y[NODE_ROW_OFFSET + row_count] = result_to_send;
        } else {
            slink_send_data(
                REMOTE_ADDR(1, Y_RETURN_BASE, (uint32_t)(NODE_ROW_OFFSET + row_count) * 4),
                result_to_send);
        }

        if (irq_fired == ROWS_PER_NODE - 1) {
            irq_fired     = 0;
            all_rows_done = 1;
        } else {
            irq_fired++;
        }
    } else
#endif
    if (cause == IRQ_MAC_START) {
        (void)mac_ack_start();  // Reading START clears the start IRQ
        mac_start_received = 1;
    } else if (cause == IRQ_SRAM_MONITOR) {
        sram_monitor_ack();
        y_all_received = 1;
    }
}

void croc_exception_handler(uint32_t cause)
{
    (void)cause;
    while (1)
        asm volatile ("wfi");
}

// ---------------------------------------------------------------------------
// Helper: configure the serial-link TX clock divider
// ---------------------------------------------------------------------------

static void set_tx_clk_div(uint32_t clk_div, uint32_t clk_start, uint32_t clk_end)
{
    slink_set_ctrl_reg(STOP_NODE_TX);
    slink_set_tx_clk_div(clk_div);
    slink_set_tx_clk_start(clk_start);
    slink_set_tx_clk_end(clk_end);
    slink_set_ctrl_reg(START_NODE_TX);
}

// ---------------------------------------------------------------------------
// Helper: re-arm the y[] completion monitor for the next test iteration.
// The window, threshold, and mode are set once in main(); this function only
// clears the running count and any pending IRQ before re-enabling.
// ---------------------------------------------------------------------------

static void arm_y_monitor(void)
{
    sram_monitor_disable();
    sram_monitor_clear();
    sram_monitor_set_threshold(NUM_ROWS);
    sram_monitor_set_mode(SRAM_MONITOR_MODE_WRITE);
    y_all_received = 0;
    sram_monitor_enable();
    fence();
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(void)
{
    slink_set_node_id(NODE_ID);
    if (slink_get_node_id() != NODE_ID)
        return 1;

    set_tx_clk_div(4, SLINK_TX_CLK_DIV_4_START, SLINK_TX_CLK_DIV_4_END);

    // Initialize weight matrix W and input vector x in SRAM.
    // Each node writes only its own ROWS_PER_NODE rows of W; all nodes write x.
    volatile uint32_t *w = (volatile uint32_t *)W_MATRIX_BASE;
    volatile uint32_t *x = (volatile uint32_t *)X_VEC_BASE;

    for (int r = 0; r < ROWS_PER_NODE; r++)
        for (int i = 0; i < VEC_LEN; i++)
            w[r * VEC_LEN + i] = 1;

    for (int i = 0; i < VEC_LEN; i++)
        x[i] = (uint32_t)(i + 1);

    volatile uint32_t *timing = (volatile uint32_t *)TIMING_ADDRESS;
    timing[0] = (uint32_t)get_mcycle();

    // ------------------------------------------------------------------
    // Remote nodes (NODE_ID > 1)
    // ------------------------------------------------------------------

    if (NODE_ID != 1) {
#ifdef USE_MAC_ACCEL
        // Hardware path: the MAC fires IRQ_MAC_DONE per row; the ISR ships
        // each result back to Node 1 via the serial link.
        set_interrupt_enable(1, IRQ_MAC_DONE);
        set_global_irq_enable(1);

        for (int t = 0; t < N_TESTS; t++) {
            for (volatile int i = 0; i < 1000000000 && !all_rows_done; i++)
                asm volatile ("nop");
            all_rows_done = 0;
        }

        set_interrupt_enable(0, IRQ_MAC_DONE);
        set_global_irq_enable(0);
#else
        // Software path: wait for Node 1's start signal, then compute rows
        // locally and write results directly to Node 1's Y_RETURN_BASE via
        // the serial link. The SRAM write monitor on Node 1 detects arrival.
        set_interrupt_enable(1, IRQ_MAC_START);
        set_global_irq_enable(1);

        for (int t = 0; t < N_TESTS; t++) {
            for (volatile int i = 0; i < 1000000000 && !mac_start_received; i++)
                asm volatile ("wfi");
            mac_start_received = 0;

            for (int r = 0; r < ROWS_PER_NODE; r++) {
                uint32_t acc = 0;
                for (int i = 0; i < VEC_LEN; i++)
                    acc += w[r * VEC_LEN + i] * x[i];
                slink_send_data(
                    REMOTE_ADDR(1, Y_RETURN_BASE,
                                (uint32_t)(NODE_ROW_OFFSET + r) * 4),
                    acc);
            }
        }

        set_interrupt_enable(0, IRQ_MAC_START);
        set_global_irq_enable(0);
#endif
        return 0;  // Remote nodes do not verify results
    }

    // ------------------------------------------------------------------
    // Node 1 — orchestrates the distributed matrix-vector product:
    //
    //  1. (Accelerator mode) Pre-configure remote and local MACs.
    //  2. Set up the SRAM write monitor on the y[] result window.
    //  3. For each test iteration:
    //     a. Re-arm the monitor before any y[] writes begin.
    //     b. Broadcast x to all remote nodes via the serial link.
    //     c. Trigger remote computation (start pulse / software signal).
    //     d. Compute local rows (hardware or software).
    //     e. Wait for the monitor to confirm all NUM_ROWS writes.
    //     f. Verify every entry of y against EXPECTED_Y.
    // ------------------------------------------------------------------

    // Monitor the entire y[] window; IRQ_SRAM_MONITOR fires once NUM_ROWS
    // writes have landed, regardless of whether they came from local or
    // remote sources.
    sram_monitor_set_window(Y_RETURN_BASE, Y_RETURN_BASE + (uint32_t)(NUM_ROWS - 1) * 4);
    sram_monitor_set_threshold(NUM_ROWS);
    sram_monitor_set_mode(SRAM_MONITOR_MODE_WRITE);

#ifdef USE_MAC_ACCEL
    // Configure all remote MAC accelerators via broadcast
    slink_send_data(REMOTE_ADDR(0xF, MAC_BASE_ADDR, MAC_MATRIX_BASE_OFFSET), W_MATRIX_BASE);
    slink_send_data(REMOTE_ADDR(0xF, MAC_BASE_ADDR, MAC_VEC_LEN_OFFSET),     VEC_LEN);
    slink_send_data(REMOTE_ADDR(0xF, MAC_BASE_ADDR, MAC_NUM_ROW_OFFSET),     ROWS_PER_NODE);
    slink_send_data(REMOTE_ADDR(0xF, MAC_BASE_ADDR, MAC_X_BASE_OFFSET),      X_VEC_BASE);

    // Configure the local MAC accelerator
    mac_configure(W_MATRIX_BASE, X_VEC_BASE, VEC_LEN, ROWS_PER_NODE);

    set_interrupt_enable(1, IRQ_MAC_DONE);
#endif
    set_interrupt_enable(1, IRQ_SRAM_MONITOR);
    set_global_irq_enable(1);

    for (int t = 0; t < N_TESTS; t++) {

        // Step 3a — Re-arm the monitor before any y[] writes can occur
        arm_y_monitor();

        // Step 3b-c — Broadcast x and trigger computation on remote nodes
#if NUM_NODES > 1
        for (int i = 0; i < VEC_LEN; i++)
            slink_send_data(REMOTE_ADDR(0xF, X_VEC_BASE, (uint32_t)(i) * 4), x[i]);
        slink_send_data(REMOTE_ADDR(0xF, MAC_BASE_ADDR, MAC_START_OFFSET), 1);
#endif

        // Step 3d — Compute local rows
#ifdef USE_MAC_ACCEL
        mac_start();
#else
        volatile uint32_t *y_sw = (volatile uint32_t *)Y_RETURN_BASE;
        for (int r = 0; r < ROWS_PER_NODE; r++) {
            uint32_t acc = 0;
            for (int i = 0; i < VEC_LEN; i++)
                acc += w[r * VEC_LEN + i] * x[i];
            y_sw[NODE_ROW_OFFSET + r] = acc;
        }
#endif

        // Step 3e — Wait for the SRAM monitor to confirm all NUM_ROWS writes
        for (volatile int i = 0; i < 1000000000 && !y_all_received; i++)
            asm volatile ("nop");

        // Step 3f — Verify all NUM_ROWS entries of y
        volatile uint32_t *y = (volatile uint32_t *)Y_RETURN_BASE;
        for (int r = 0; r < NUM_ROWS; r++)
            if (y[r] != EXPECTED_Y) return r + 1;

    } // end N_TESTS loop

#ifdef USE_MAC_ACCEL
    set_interrupt_enable(0, IRQ_MAC_DONE);
#endif
    set_interrupt_enable(0, IRQ_SRAM_MONITOR);
    set_global_irq_enable(0);
    sram_monitor_disable();

    timing[1] = (uint32_t)get_mcycle();
    timing[2] = timing[1] - timing[0];

    return 0;
}