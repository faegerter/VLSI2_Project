// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`define TRACE_WAVE

// --------------------------------------------------------------------
//  tb_croc_soc_ring
//
//  Instantiates NumNodes croc_soc instances connected in a serial-link
//  ring.  Each node loads its own pre-compiled, per-node hex binary named
//  "<test_name><NODE_ID>.hex", e.g. for the default test_name:
//
//    bin/serial_link_test_node1.hex  (NODE_ID=1)
//    bin/serial_link_test_node2.hex  (NODE_ID=2)
//    ...
//
//  Override the binary directory and/or the test program at runtime:
//    +bin_dir=../sw/bin
//    +test_name=mac_accel_test_node
//
//  so any program providing one per-node binary can replace the default
//  serial_link_test_node.
//
//  Ring wiring (same convention as tb_obi_slink):
//    node i  →  drives slink wires at index NEXT = (i+1) % NumNodes
//    node i  ←  receives slink wires at index i   (driven by node i-1)
// --------------------------------------------------------------------

module tb_croc_soc_ring #(
  parameter int unsigned NumNodes         = 4,
  parameter int unsigned GpioCount        = 12,
  parameter int unsigned SlinkNumChannels = 1,
  parameter int unsigned SlinkNumLanes    = 10
);

  import tb_croc_pkg::*;

  // ================================================================
  //  Per-node signal arrays
  // ================================================================
  logic rst_n      [NumNodes];
  logic sys_clk    [NumNodes];
  logic ref_clk    [NumNodes];

  logic jtag_tck   [NumNodes];
  logic jtag_trst_n[NumNodes];
  logic jtag_tms   [NumNodes];
  logic jtag_tdi   [NumNodes];
  logic jtag_tdo   [NumNodes];

  logic uart_rx    [NumNodes];
  logic uart_tx    [NumNodes];

  logic [GpioCount-1:0] gpio_in     [NumNodes];
  logic [GpioCount-1:0] gpio_out    [NumNodes];
  logic [GpioCount-1:0] gpio_out_en [NumNodes];

  // ================================================================
  //  Serial-link ring wires
  //
  //  Node i drives index NEXT; node i reads index i.
  //  Using plain logic arrays — each element is driven by exactly
  //  one node's output port, which is fine in simulation.
  // ================================================================
  logic [SlinkNumChannels-1:0]                    slink_ddr_rcv_clk [NumNodes];
  logic [SlinkNumChannels-1:0][SlinkNumLanes-1:0] slink_ddr          [NumNodes];
  logic                                           slink_credit_clk   [NumNodes];

  // ================================================================
  //  EOC tracking
  // ================================================================
  logic [NumNodes-1:0] node_done = '0;   // set by proc_test[i] on completion
  int   unsigned       node_result[NumNodes];  // tb_data from jtag_wait_for_eoc

  // Power-analysis capture window (in ns), emitted at the end as [PWR_WINDOW].
  // pwr_t_start = first core resume (compute begins), pwr_t_stop = all nodes
  // done (compute ends). A probe run reads these to size the VCD dump window.
  int   unsigned       pwr_woke    = 0;     // number of cores resumed so far
  realtime             pwr_t_start = -1.0;  // first core resume  (compute start)
  realtime             pwr_t_stop  = -1.0;  // all nodes done     (compute stop)

  // Armed by the top-level dump block at the start of the capture window; each
  // node then dumps ONLY its own chip (see the per-node dump block in the
  // generate). Dumping just the gate-level chips - not the whole testbench -
  // keeps the per-node clock generators / JTAG VIP (which carry real/time
  // variables that OpenROAD's read_vcd cannot parse) out of the VCD.
  bit                  pwr_dump_arm = 1'b0;

  // ================================================================
  //  Binary directory (override with +bin_dir=<path>)
  // ================================================================
  string bin_dir;
  string test_name;
  initial begin
    if (!$value$plusargs("bin_dir=%s", bin_dir))
      bin_dir = "../sw/bin";
    if (!$value$plusargs("test_name=%s", test_name))
      test_name = "serial_link_test_node";
    $display("[TB] Binary directory: %s", bin_dir);
    $display("[TB] Test program:     %s", test_name);
  end

  // ================================================================
  //  Generate: one VIP + one croc_soc per node
  // ================================================================
  generate
    for (genvar i = 0; i < NumNodes; i++) begin : gen_nodes

      localparam int unsigned NEXT = (i + 1) % NumNodes;

      // ------------------------------------------------------------
      //  Verification IP — drives clocks, reset and JTAG for node i
      // ------------------------------------------------------------
      croc_vip #(
        .GpioCount ( GpioCount )
      ) i_vip (
        .rst_no        ( rst_n      [i] ),
        .sys_clk_o     ( sys_clk    [i] ),
        .ref_clk_o     ( ref_clk    [i] ),
        .jtag_tck_o    ( jtag_tck   [i] ),
        .jtag_trst_no  ( jtag_trst_n[i] ),
        .jtag_tms_o    ( jtag_tms   [i] ),
        .jtag_tdi_o    ( jtag_tdi   [i] ),
        .jtag_tdo_i    ( jtag_tdo   [i] ),
        .uart_rx_o     ( uart_rx    [i] ),
        .uart_tx_i     ( uart_tx    [i] ),
        .gpio_out_en_i ( gpio_out_en[i] ),
        .gpio_out_i    ( gpio_out   [i] ),
        .gpio_in_o     ( gpio_in    [i] )
      );

      // ------------------------------------------------------------
      //  DUT — croc_soc instance
      //
      //  Ring connections:
      //    output ports → drive wire at index NEXT
      //    input  ports ← read  wire at index i (driven by node i-1)
      // ------------------------------------------------------------
      `ifdef TARGET_NETLIST_PNR
      // ------------------------------------------------------------
      //  Post-layout (OpenROAD) netlist: a single flat croc_chip with
      //  IO pads. The ring is wired through the chip-level slink pads
      //  (channel 0, 10 lanes). The serial-link test does not use GPIO,
      //  so the gpio pads are left open and the VIP gpio inputs tied off.
      // ------------------------------------------------------------
      croc_chip i_croc_chip (
        .clk_i        ( sys_clk    [i] ),
        .rst_ni       ( rst_n      [i] ),
        .ref_clk_i    ( ref_clk    [i] ),
        .testmode_i   ( 1'b0           ),
        .status_o     (                ),
        .jtag_tck_i   ( jtag_tck   [i] ),
        .jtag_trst_ni ( jtag_trst_n[i] ),
        .jtag_tms_i   ( jtag_tms   [i] ),
        .jtag_tdi_i   ( jtag_tdi   [i] ),
        .jtag_tdo_o   ( jtag_tdo   [i] ),
        .uart_rx_i    ( uart_rx    [i] ),
        .uart_tx_o    ( uart_tx    [i] ),
        // --- ring inputs: read this node's wires (driven by node i-1) ---
        .slink_ddr_rcv_clk_i     ( slink_ddr_rcv_clk[i][0] ),
        .slink_ddr0_i ( slink_ddr[i][0][0] ),
        .slink_ddr1_i ( slink_ddr[i][0][1] ),
        .slink_ddr2_i ( slink_ddr[i][0][2] ),
        .slink_ddr3_i ( slink_ddr[i][0][3] ),
        .slink_ddr4_i ( slink_ddr[i][0][4] ),
        .slink_ddr5_i ( slink_ddr[i][0][5] ),
        .slink_ddr6_i ( slink_ddr[i][0][6] ),
        .slink_ddr7_i ( slink_ddr[i][0][7] ),
        .slink_ddr8_i ( slink_ddr[i][0][8] ),
        .slink_ddr9_i ( slink_ddr[i][0][9] ),
        .slink_credit_recv_clk_i ( slink_credit_clk[NEXT] ),
        // --- ring outputs: drive NEXT node's input wires ---
        .slink_ddr_rcv_clk_o     ( slink_ddr_rcv_clk[NEXT][0] ),
        .slink_ddr0_o ( slink_ddr[NEXT][0][0] ),
        .slink_ddr1_o ( slink_ddr[NEXT][0][1] ),
        .slink_ddr2_o ( slink_ddr[NEXT][0][2] ),
        .slink_ddr3_o ( slink_ddr[NEXT][0][3] ),
        .slink_ddr4_o ( slink_ddr[NEXT][0][4] ),
        .slink_ddr5_o ( slink_ddr[NEXT][0][5] ),
        .slink_ddr6_o ( slink_ddr[NEXT][0][6] ),
        .slink_ddr7_o ( slink_ddr[NEXT][0][7] ),
        .slink_ddr8_o ( slink_ddr[NEXT][0][8] ),
        .slink_ddr9_o ( slink_ddr[NEXT][0][9] ),
        .slink_credit_rtrn_clk_o ( slink_credit_clk[i] ),
        // --- gpio pads unused in the ring test ---
        .gpio0_io ( ), .gpio1_io ( ), .gpio2_io  ( ), .gpio3_io  ( ),
        .gpio4_io ( ), .gpio5_io ( ), .gpio6_io  ( ), .gpio7_io  ( ),
        .gpio8_io ( ), .gpio9_io ( ), .gpio10_io ( ), .gpio11_io ( )
        // NOTE: the post-layout netlist has no VDD/VSS/VDDIO/VSSIO ports;
        // power is delivered through the PG network, not Verilog ports.
      );
      // VIP gpio is not wired to the chip pads in netlist mode: tie its inputs
      assign gpio_out   [i] = '0;
      assign gpio_out_en[i] = '0;

      `else
      `ifdef TARGET_NETLIST_YOSYS
      \croc_soc$croc_chip.i_croc_soc i_croc_soc (
      `else
      croc_soc #(
        .GpioCount        ( GpioCount        ),
        .SlinkNumChannels ( SlinkNumChannels ),
        .SlinkNumLanes    ( SlinkNumLanes    )
      ) i_croc_soc (
      `endif
        .clk_i                   ( sys_clk    [i] ),
        .rst_ni                  ( rst_n      [i] ),
        .ref_clk_i               ( ref_clk    [i] ),
        .testmode_i              ( 1'b0            ),
        .status_o                (                 ),
        .jtag_tck_i              ( jtag_tck   [i] ),
        .jtag_tdi_i              ( jtag_tdi   [i] ),
        .jtag_tdo_o              ( jtag_tdo   [i] ),
        .jtag_tms_i              ( jtag_tms   [i] ),
        .jtag_trst_ni            ( jtag_trst_n[i] ),
        .uart_rx_i               ( uart_rx    [i] ),
        .uart_tx_o               ( uart_tx    [i] ),
        .gpio_i                  ( gpio_in    [i] ),
        .gpio_o                  ( gpio_out   [i] ),
        .gpio_out_en_o           ( gpio_out_en[i] ),
        // --- ring outputs: drive NEXT node's input wires ---
        .slink_ddr_rcv_clk_o     ( slink_ddr_rcv_clk[NEXT] ),
        .slink_ddr_o             ( slink_ddr        [NEXT] ),
        .slink_credit_rtrn_clk_o ( slink_credit_clk [i] ),
        // --- ring inputs: read this node's wire (driven by node i-1) ---
        .slink_ddr_rcv_clk_i     ( slink_ddr_rcv_clk[i]    ),
        .slink_ddr_i             ( slink_ddr        [i]     ),
        .slink_credit_recv_clk_i ( slink_credit_clk [NEXT]     )
      );
      `endif

      // ------------------------------------------------------------
      //  Per-node test process
      //
      //  1. Wait for reset
      //  2. Init JTAG
      //  3. Load node-specific binary  (1-indexed NODE_ID = i+1)
      //  4. Wake core via CLINT msip
      //  5. Wait for EOC
      //  6. Signal completion via node_done[i]
      // ------------------------------------------------------------
      initial begin : proc_test
        automatic string hex_path;
        automatic logic [31:0] tb_data;

        // Derive path: NODE_IDs are 1-indexed in the C code.
        // test_name selects the program (default serial_link_test_node);
        // override at runtime with +test_name=<program>.
        $sformat(hex_path, "%s/%s%0d.hex", bin_dir, test_name, i + 1);
        
        $display("@%t | [Node %0d] Binary: %s", $time, i, hex_path);

        #ClkPeriodSys;

        gen_nodes[i].i_vip.jtag_init();

        $display("@%t | [Node %0d] Loading binary...", $time, i);
        gen_nodes[i].i_vip.jtag_load_hex(hex_path);

        $display("@%t | [Node %0d] Waking core via CLINT msip", $time, i);
        gen_nodes[i].i_vip.jtag_write_reg32(ClintBaseAddr, 32'h1);

        gen_nodes[i].i_vip.jtag_halt();
        gen_nodes[i].i_vip.jtag_resume();

        // Record the start of the active compute phase (first core to resume).
        if (pwr_woke == 0) pwr_t_start = $realtime;
        pwr_woke = pwr_woke + 1;

        // Poll corestatus manually instead of calling jtag_wait_for_eoc,
        // which calls $finish() internally and would kill all other nodes.
        $display("@%t | [Node %0d] Waiting for EOC...", $time, i);
        begin
          automatic dm::sbcs_t sbcs = dm::sbcs_t'{sbreadonaddr: 1'b1, sbaccess: 2, default: '0};
          tb_data = 0;
          gen_nodes[i].i_vip.jtag_write(dm::SBCS, sbcs, 0, 1);
          gen_nodes[i].i_vip.jtag_write(dm::SBAddress1, '0);
          do begin
            gen_nodes[i].i_vip.jtag_write(dm::SBAddress0, CoreStatusAddr);
            gen_nodes[i].i_vip.jtag_dbg.wait_idle(20);
            gen_nodes[i].i_vip.jtag_dbg.read_dmi_exp_backoff(dm::SBData0, tb_data);
          end while (tb_data == 0);
        end

        node_result[i] = tb_data >> 1;
        node_done[i]   = 1'b1;

        $display("@%t | [Node %0d] EOC received, return value = 0x%08X (%s)",
          $time, i, node_result[i], (node_result[i] == 0) ? "PASS" : "FAIL");

      end : proc_test

      // ------------------------------------------------------------
      //  Per-node power dump: when armed by the top-level dump block,
      //  dump ONLY this node's gate-level chip into the shared VCD.
      // ------------------------------------------------------------
      initial begin : proc_dump
        if ($test$plusargs("dump")) begin
          wait (pwr_dump_arm);
          `ifdef TARGET_NETLIST_PNR
            $dumpvars(0, i_croc_chip);
          `else
            $dumpvars(0, i_croc_soc);
          `endif
        end
      end : proc_dump

    end // for genvar i
  endgenerate

  // ================================================================
  //  Main control: wait for all nodes, print summary, finish
  // ================================================================
  initial begin : proc_main
    automatic int unsigned passed = 0;
    automatic int unsigned failed = 0;

    $timeformat(-9, 0, "ns", 12);

    // Wait for every node to reach EOC
    wait (node_done == '1);
    pwr_t_stop = $realtime;   // active compute phase ends here
    repeat (50) @(posedge sys_clk[0]);

    // Emit the capture window in ns for the power-sweep probe pass to parse.
    $display("[PWR_WINDOW] start_ns=%0d stop_ns=%0d",
             (pwr_t_start >= 0) ? $rtoi(pwr_t_start / 1ns) : 0,
             (pwr_t_stop  >= 0) ? $rtoi(pwr_t_stop  / 1ns) : 0);

    $display("==========================================================");
    $display("[TB] Simulation complete at %0t", $time);
    $display("[TB] Nodes: %0d", NumNodes);
    for (int n = 0; n < NumNodes; n++) begin
      if (node_result[n] == 0) passed++;
      else                      failed++;
      $display("[TB]   Node %0d (NODE_ID=%0d): %s (ret=0x%08X)",
        n, n+1, (node_result[n] == 0) ? "PASS" : "FAIL", node_result[n]);
    end
    $display("[TB] Passed: %0d / %0d", passed, NumNodes);
    if (failed == 0)
      $display("[TB] *** ALL NODES PASSED ***");
    else
      $display("[TB] *** %0d NODE(S) FAILED ***", failed);
    $display("==========================================================");

//begin
//      logic [31:0] cyc_start, cyc_end, cyc_diff;
//      
//      // FIX: Hierarchically reference Node 0's VIP to use the JTAG tasks
//      gen_nodes[0].i_vip.jtag_read_reg32(32'h04000F00, cyc_start);
//      gen_nodes[0].i_vip.jtag_read_reg32(32'h04000F04, cyc_end);
//      gen_nodes[0].i_vip.jtag_read_reg32(32'h04000F08, cyc_diff);
// 
//      $display("@%t | [TIMING] Node 0: start=%0d cycles, end=%0d cycles, difference=%0d",
//               $time, cyc_start, cyc_end, cyc_diff);
//    end

    $finish();
  end : proc_main

  // ================================================================
  //  Waveform dump
  // ================================================================
  initial begin
    // Waveform dump for (post-layout) power analysis.
    //   * Enable at runtime with +dump  (no recompile needed).
    //   * QuestaSim must be launched with -voptargs=+acc so internal nets are
    //     preserved, otherwise the VCD only holds top-level ports.
    //   * Optional capture window in nanoseconds:
    //         +vcd_start=<ns>   delay before dumping  (0 = from t=0)
    //         +vcd_dur=<ns>     dump duration         (0 = until $finish)
    //     Pick the active compute window to keep the VCD small and the dynamic
    //     power representative (exclude the JTAG upload / idle phases).
    //   * Dumps the FULL hierarchy, so every node's chip is captured. Select a
    //     single node in OpenROAD with:
    //         read_vcd -scope tb_croc_soc_ring/gen_nodes[<n>]/i_croc_chip ...
    if ($test$plusargs("dump")) begin
      longint unsigned vcd_start_ns, vcd_dur_ns;
      if (!$value$plusargs("vcd_start=%d", vcd_start_ns)) vcd_start_ns = 0;
      if (!$value$plusargs("vcd_dur=%d",   vcd_dur_ns))   vcd_dur_ns   = 0;
      `ifdef VERILATOR
        $dumpfile("croc_ring.fst");
      `else
        $dumpfile("croc_ring.vcd");
      `endif
      if (vcd_start_ns > 0) #(vcd_start_ns * 1ns);
      $display("@%t | [VCD] start dump (chips only)", $time);
      // Arm the per-node dump blocks: each node dumps its own i_croc_chip into
      // this same VCD. (We do NOT dump all of tb_croc_soc_ring - that pulls in
      // real/time variables from the VIP/clock-gens that read_vcd chokes on.)
      pwr_dump_arm = 1'b1;
      if (vcd_dur_ns > 0) begin
        #(vcd_dur_ns * 1ns);
        $display("@%t | [VCD] stop dump", $time);
        $dumpoff;
        $dumpflush;  // ensure the VCD is fully written before we $finish
        // The power VCD is complete; no need to simulate (with +acc) all the
        // way to EOC. Stop here so the measurement run ends shortly after the
        // captured window instead of running the full workload to completion.
        $finish;
      end
    end
  end

  final begin
    `ifdef TRACE_WAVE
      $dumpflush;
    `endif
  end

endmodule : tb_croc_soc_ring