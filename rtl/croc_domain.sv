// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>
// - Fabian Aegerter   <faegerter@ethz.ch>
// - Maximilian Kocher <mkocher@ethz.ch>

`include "slink_obi/typedef.svh"


module croc_domain import croc_pkg::*; import slink_pkg::*; #(
  parameter int unsigned GpioCount = 12,
  parameter int unsigned NumExternalIrqs = 4,
  parameter int unsigned SlinkNumChannels = 1,
  parameter int unsigned SlinkNumLanes = 10
) (
  input  logic      clk_i,
  input  logic      rst_ni,
  input  logic      ref_clk_i,
  input  logic      testmode_i,

  input  logic      jtag_tck_i,
  input  logic      jtag_tdi_i,
  output logic      jtag_tdo_o,
  input  logic      jtag_tms_i,
  input  logic      jtag_trst_ni,

  input  logic      uart_rx_i,
  output logic      uart_tx_o,

  input  logic [GpioCount-1:0] gpio_i,        // Input from GPIO pins
  output logic [GpioCount-1:0] gpio_o,        // Output to GPIO pins
  output logic [GpioCount-1:0] gpio_out_en_o, // Output enable signal; 0 -> input, 1 -> output

  output logic [GpioCount-1:0] gpio_in_sync_o, // synchronized GPIO inputs

  /// User OBI interface
  /// User as subordinate (from core to user module)
  /// Address space 0x2000_0000 - 0x8000_0000
  output sbr_obi_req_t user_sbr_obi_req_o,
  input  sbr_obi_rsp_t user_sbr_obi_rsp_i,

  /// User as manager (from user module to SRAM/peripherals)
  /// [0] = port 1 (W matrix reads), [1] = port 2 (x vector reads)
  input  mgr_obi_req_t [NumUserManagers-1:0] user_mgr_obi_req_i,
  output mgr_obi_rsp_t [NumUserManagers-1:0] user_mgr_obi_rsp_o,

  input  logic [NumExternalIrqs-1:0] interrupts_i,
  output logic core_busy_o, 

  input   logic  [SlinkNumChannels-1:0]                    slink_ddr_rcv_clk_i,    
  output  logic  [SlinkNumChannels-1:0]                    slink_ddr_rcv_clk_o,    
  input   logic  [SlinkNumChannels-1:0][SlinkNumLanes-1:0] slink_ddr_i,            
  output  logic  [SlinkNumChannels-1:0][SlinkNumLanes-1:0] slink_ddr_o,            
  input   logic                                            slink_credit_recv_clk_i,
  output  logic                                            slink_credit_rtrn_clk_o
);

  // -----------------
  // Control Signals
  // -----------------
  logic sram_impl; // soc_ctrl -> SRAM config signals
  logic debug_req;
  logic fetch_enable;

  // interrupts (irqs)
  logic clint_timer_irq;
  logic clint_software_irq;
  logic obi_timer_irq;
  logic uart_irq;
  logic gpio_irq;
  logic idma_irq;
  logic sram_mon_irq;
  logic [15:0] interrupts;
  always_comb begin
    interrupts    = '0;
    interrupts[0] = obi_timer_irq;
    interrupts[1] = uart_irq;
    interrupts[2] = gpio_irq;
    interrupts[3] = idma_irq;
    interrupts[4+:NumExternalIrqs] = interrupts_i;
    interrupts[4+NumExternalIrqs]  = sram_mon_irq;
  end

  // ----------------------------
  // Manager buses into crossbar
  // ----------------------------

  // Core instr bus
  mgr_obi_req_t core_instr_obi_req;
  mgr_obi_rsp_t core_instr_obi_rsp;
  assign core_instr_obi_req.a.aid = '0;
  assign core_instr_obi_req.a.we = '0;
  assign core_instr_obi_req.a.be = '1;
  assign core_instr_obi_req.a.wdata = '0;
  assign core_instr_obi_req.a.a_optional = '0;

  // Core data bus
  mgr_obi_req_t core_data_obi_req;
  mgr_obi_rsp_t core_data_obi_rsp;
  assign core_data_obi_req.a.aid = '0;
  assign core_data_obi_req.a.a_optional = '0;

  // dbg req bus
  mgr_obi_req_t dbg_req_obi_req;
  mgr_obi_rsp_t dbg_req_obi_rsp;
  assign dbg_req_obi_req.a.aid = '0;
  assign dbg_req_obi_req.a.a_optional = '0;

  mgr_obi_req_t idma_obi_read_req;
  mgr_obi_rsp_t idma_obi_read_rsp;
  mgr_obi_req_t idma_obi_write_req;
  mgr_obi_rsp_t idma_obi_write_rsp;

  // Slink bus
  mgr_obi_req_t slink_obi_req_o;
  mgr_obi_rsp_t slink_obi_rsp_i;


  // xbar manager buses
  mgr_obi_req_t [NumXbarManagers-1:0] xbar_mgr_obi_req;
  mgr_obi_rsp_t [NumXbarManagers-1:0] xbar_mgr_obi_rsp;

  // split out to individual manager buses
  assign xbar_mgr_obi_req[0]   = user_mgr_obi_req_i[0];
  assign user_mgr_obi_rsp_o[0] = xbar_mgr_obi_rsp[0];

  assign xbar_mgr_obi_req[1] = dbg_req_obi_req;
  assign dbg_req_obi_rsp     = xbar_mgr_obi_rsp[1];

  assign xbar_mgr_obi_req[2] = core_data_obi_req;
  assign core_data_obi_rsp   = xbar_mgr_obi_rsp[2];

  assign xbar_mgr_obi_req[3] = core_instr_obi_req;
  assign core_instr_obi_rsp  = xbar_mgr_obi_rsp[3];

  // Pipeline cut on the serial link manager port (slink -> crossbar).
  // Breaks the combinational ready/grant path between the slink flow-control
  // (credit-return clock gate enable) and the main crossbar arbitration.
  obi_cut #(
    .ObiCfg       ( MgrObiCfg        ),
    .obi_a_chan_t ( mgr_obi_a_chan_t ),
    .obi_r_chan_t ( mgr_obi_r_chan_t ),
    .obi_req_t    ( mgr_obi_req_t    ),
    .obi_rsp_t    ( mgr_obi_rsp_t    )
  ) i_slink_mgr_obi_cut (
    .clk_i,
    .rst_ni,
    .sbr_port_req_i ( slink_obi_req_o      ),
    .sbr_port_rsp_o ( slink_obi_rsp_i      ),
    .mgr_port_req_o ( xbar_mgr_obi_req[4]  ),
    .mgr_port_rsp_i ( xbar_mgr_obi_rsp[4]  )
  );

  assign xbar_mgr_obi_req[5]   = user_mgr_obi_req_i[1];  // index 5, after slink at [4]
  assign user_mgr_obi_rsp_o[1] = xbar_mgr_obi_rsp[5];

  // ----------------------------------
  // Subordinate buses out of crossbar
  // ----------------------------------
  // Main xbar subordinate buses, must align with addr map indices!
  sbr_obi_req_t [NumXbarSubordinates-1:0] all_sbr_obi_req;
  sbr_obi_rsp_t [NumXbarSubordinates-1:0] all_sbr_obi_rsp;

  // user bus defined in module port

  // mem bank buses
  sbr_obi_req_t [NumSramBanks-1:0] xbar_mem_bank_obi_req;
  sbr_obi_rsp_t [NumSramBanks-1:0] xbar_mem_bank_obi_rsp;

  // periph bus
  sbr_obi_req_t xbar_periph_obi_req;
  sbr_obi_rsp_t xbar_periph_obi_rsp;

  // serial link bus
  sbr_obi_req_t xbar_slink_obi_req;
  sbr_obi_rsp_t xbar_slink_obi_rsp;

  // error (connected to bus error slave)
  sbr_obi_req_t xbar_error_obi_req;
  sbr_obi_rsp_t xbar_error_obi_rsp;

  assign xbar_error_obi_req          = all_sbr_obi_req[XbarError];
  assign all_sbr_obi_rsp[XbarError]  = xbar_error_obi_rsp;

  assign xbar_periph_obi_req         = all_sbr_obi_req[XbarPeriph];
  assign all_sbr_obi_rsp[XbarPeriph] = xbar_periph_obi_rsp;

  for (genvar i = 0; i < NumSramBanks; i++) begin : gen_xbar_sbr_connect
    assign xbar_mem_bank_obi_req[i]     = all_sbr_obi_req[XbarBank0+i];
    assign all_sbr_obi_rsp[XbarBank0+i] = xbar_mem_bank_obi_rsp[i];
  end

  assign xbar_slink_obi_req          = all_sbr_obi_req[XbarSlink];
  assign all_sbr_obi_rsp[XbarSlink]  = xbar_slink_obi_rsp;

  assign user_sbr_obi_req_o          = all_sbr_obi_req[XbarUser];
  assign all_sbr_obi_rsp[XbarUser]   = user_sbr_obi_rsp_i;


  // -----------------
  // Peripheral buses
  // -----------------
  // array of subordinate buses from peripheral demultiplexer
  sbr_obi_req_t [NumPeriphs-1:0] all_periph_obi_req;
  sbr_obi_rsp_t [NumPeriphs-1:0] all_periph_obi_rsp;

  // Error bus
  sbr_obi_req_t error_obi_req;
  sbr_obi_rsp_t error_obi_rsp;

  // Debug mem bus
  sbr_obi_req_t dbg_mem_obi_req;
  sbr_obi_rsp_t dbg_mem_obi_rsp;

  // SoC control bus
  sbr_obi_req_t soc_ctrl_obi_req;
  sbr_obi_rsp_t soc_ctrl_obi_rsp;

  // UART periph bus
  sbr_obi_req_t uart_obi_req;
  sbr_obi_rsp_t uart_obi_rsp;

  // GPIO periph bus
  sbr_obi_req_t gpio_obi_req;
  sbr_obi_rsp_t gpio_obi_rsp;

  // Timer periph bus
  sbr_obi_req_t timer_obi_req;
  sbr_obi_rsp_t timer_obi_rsp;

  // iDMA periph bus
  sbr_obi_req_t idma_obi_cfg_req;
  sbr_obi_rsp_t idma_obi_cfg_rsp;

  // CLINT bus
  sbr_obi_req_t clint_obi_req;
  sbr_obi_rsp_t clint_obi_rsp;

  // Bootrom bus
  sbr_obi_req_t bootrom_obi_req;
  sbr_obi_rsp_t bootrom_obi_rsp;

  // SRAM access-monitor config bus
  sbr_obi_req_t sram_mon_obi_req;
  sbr_obi_rsp_t sram_mon_obi_rsp;

  // Fanout to individual peripherals
  assign error_obi_req                     = all_periph_obi_req[PeriphError];
  assign all_periph_obi_rsp[PeriphError]   = error_obi_rsp;
  assign dbg_mem_obi_req                   = all_periph_obi_req[PeriphDebug];
  assign all_periph_obi_rsp[PeriphDebug]   = dbg_mem_obi_rsp;
  assign soc_ctrl_obi_req                  = all_periph_obi_req[PeriphSocCtrl];
  assign all_periph_obi_rsp[PeriphSocCtrl] = soc_ctrl_obi_rsp;
  assign uart_obi_req                      = all_periph_obi_req[PeriphUart];
  assign all_periph_obi_rsp[PeriphUart]    = uart_obi_rsp;
  assign gpio_obi_req                      = all_periph_obi_req[PeriphGpio];
  assign all_periph_obi_rsp[PeriphGpio]    = gpio_obi_rsp;
  assign timer_obi_req                     = all_periph_obi_req[PeriphTimer];
  assign all_periph_obi_rsp[PeriphTimer]   = timer_obi_rsp;
  assign idma_obi_cfg_req                  = all_periph_obi_req[PeriphiDMA];
  assign all_periph_obi_rsp[PeriphiDMA]    = idma_obi_cfg_rsp;
  assign clint_obi_req                     = all_periph_obi_req[PeriphClint];
  assign all_periph_obi_rsp[PeriphClint]   = clint_obi_rsp;
  assign bootrom_obi_req                   = all_periph_obi_req[PeriphBootrom];
  assign all_periph_obi_rsp[PeriphBootrom] = bootrom_obi_rsp;
  assign sram_mon_obi_req                  = all_periph_obi_req[PeriphSramMon];
  assign all_periph_obi_rsp[PeriphSramMon] = sram_mon_obi_rsp;


  // -----------------
  // Serial link buses
  // -----------------

  sbr_obi_req_t [NumSlinkSbr-1:0] all_slink_obi_req;
  sbr_obi_rsp_t [NumSlinkSbr-1:0] all_slink_obi_rsp;


  // Error Bus
  sbr_obi_req_t slink_error_obi_req;
  sbr_obi_rsp_t slink_error_obi_rsp;

  // OBI bus Serial link
  sbr_obi_req_t slink_obi_req_i;
  sbr_obi_rsp_t slink_obi_rsp_o;

  // OBI bus Serial link config
  sbr_obi_req_t slink_cfg_obi_req_i;
  sbr_obi_rsp_t slink_cfg_obi_rsp_o;

  // Fanout into more readable signals
  assign slink_error_obi_req              = all_slink_obi_req[SlinkError];
  assign all_slink_obi_rsp[SlinkError]    = slink_error_obi_rsp;
  assign slink_cfg_obi_req_i              = all_slink_obi_req[SlinkCfgRegs];
  assign all_slink_obi_rsp[SlinkCfgRegs]  = slink_cfg_obi_rsp_o;
  assign slink_obi_req_i                  = all_slink_obi_req[SlinkRing];
  assign all_slink_obi_rsp[SlinkRing]     = slink_obi_rsp_o;

  // -----------------
  // Core
  // -----------------
  core_wrap #(
  ) i_core_wrap (
    .clk_i,
    .rst_ni,
    .test_enable_i  ( testmode_i  ),

    .irqs_i         ( interrupts         ),
    .timer_irq_i    ( clint_timer_irq    ),
    .software_irq_i ( clint_software_irq ),

    .boot_addr_i    ( BootromAddr ),

    .instr_req_o    ( core_instr_obi_req.req     ),
    .instr_gnt_i    ( core_instr_obi_rsp.gnt     ),
    .instr_rvalid_i ( core_instr_obi_rsp.rvalid  ),
    .instr_addr_o   ( core_instr_obi_req.a.addr  ),
    .instr_rdata_i  ( core_instr_obi_rsp.r.rdata ),
    .instr_err_i    ( core_instr_obi_rsp.r.err   ),

    .data_req_o     ( core_data_obi_req.req      ),
    .data_gnt_i     ( core_data_obi_rsp.gnt      ),
    .data_rvalid_i  ( core_data_obi_rsp.rvalid   ),
    .data_we_o      ( core_data_obi_req.a.we     ),
    .data_be_o      ( core_data_obi_req.a.be     ),
    .data_addr_o    ( core_data_obi_req.a.addr   ),
    .data_wdata_o   ( core_data_obi_req.a.wdata  ),
    .data_rdata_i   ( core_data_obi_rsp.r.rdata  ),
    .data_err_i     ( core_data_obi_rsp.r.err    ),

    .debug_req_i    ( debug_req    ),
    .fetch_enable_i ( fetch_enable ),
    .core_busy_o    ( core_busy_o  )
  );

  // -----------------
  // iDMA
  // -----------------
  if (iDMAEnable) begin : gen_dma

    // iDMA
    croc_idma #(
      .ObiMrgCfg        ( MgrObiCfg           ),
      .ObiSbrCfg        ( SbrObiCfg           ),
      .TFLenWidth       ( MgrObiCfg.AddrWidth ),
      .obi_mrg_a_chan_t ( mgr_obi_a_chan_t    ),
      .obi_mrg_r_chan_t ( mgr_obi_r_chan_t    ),
      .obi_mrg_req_t    ( mgr_obi_req_t       ),
      .obi_mrg_rsp_t    ( mgr_obi_rsp_t       ),
      .obi_sbr_req_t    ( sbr_obi_req_t       ),
      .obi_sbr_rsp_t    ( sbr_obi_rsp_t       )
    ) i_croc_idma (
      .clk_i,
      .rst_ni,
      .obi_cfg_req_i    ( idma_obi_cfg_req    ),
      .obi_cfg_rsp_o    ( idma_obi_cfg_rsp    ),
      .obi_read_req_o   ( idma_obi_read_req   ),
      .obi_read_rsp_i   ( idma_obi_read_rsp   ),
      .obi_write_req_o  ( idma_obi_write_req  ),
      .obi_write_rsp_i  ( idma_obi_write_rsp  ),
      .irq_o            ( idma_irq            ),
      .busy_o           ()
    );

    // IDMA managers going into crossbar
    assign xbar_mgr_obi_req[5] = idma_obi_write_req;
    assign idma_obi_write_rsp  = xbar_mgr_obi_rsp[5];

    assign xbar_mgr_obi_req[6] = idma_obi_read_req;
    assign idma_obi_read_rsp   = xbar_mgr_obi_rsp[6];

  end else begin : gen_no_dma

    // tie-off unused signals
    assign idma_irq = 1'b0;

    // error for config
    obi_err_sbr #(
      .ObiCfg      ( SbrObiCfg     ),
      .obi_req_t   ( sbr_obi_req_t ),
      .obi_rsp_t   ( sbr_obi_rsp_t ),
      .NumMaxTrans ( 1             ),
      .RspData     ( 32'hBADCAB1E  )
    ) i_obi_err_sbr_idma_cfg (
      .clk_i,
      .rst_ni,
      .testmode_i,
      .obi_req_i  ( idma_obi_cfg_req ),
      .obi_rsp_o  ( idma_obi_cfg_rsp )
    );
  end


  // -----------------
  // Debug Module
  // -----------------

  localparam dm::hartinfo_t HARTINFO = '{
    zero1: '0,
    nscratch: 2,
    zero0: '0,
    dataaccess: 1'b1,
    datasize: dm::DataCount,
    dataaddr: dm::DataAddr
  };
  dm::hartinfo_t [0:0] hartinfo;
  assign hartinfo[0] = HARTINFO;

  logic dmi_rst_n, dmi_req_valid, dmi_req_ready, dmi_resp_valid, dmi_resp_ready;
  dm::dmi_req_t dmi_req;
  dm::dmi_resp_t dmi_resp;

  dmi_jtag #(
    .IdcodeValue ( PulpJtagIdCode )
  ) i_dmi_jtag (
    .clk_i,
    .rst_ni,
    .testmode_i,

    .dmi_rst_no       ( dmi_rst_n      ),
    .dmi_req_o        ( dmi_req        ),
    .dmi_req_valid_o  ( dmi_req_valid  ),
    .dmi_req_ready_i  ( dmi_req_ready  ),

    .dmi_resp_i       ( dmi_resp       ),
    .dmi_resp_ready_o ( dmi_resp_ready ),
    .dmi_resp_valid_i ( dmi_resp_valid ),

    .tck_i            ( jtag_tck_i     ),
    .tms_i            ( jtag_tms_i     ),
    .trst_ni          ( jtag_trst_ni   ),
    .td_i             ( jtag_tdi_i     ),
    .td_o             ( jtag_tdo_o     ),
    .tdo_oe_o         ()
  );

  dm_obi_top #(
    .BusWidth   ( SbrObiCfg.DataWidth ),
    .IdWidth    ( SbrObiCfg.IdWidth   )
  ) i_dm_top (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .ndmreset_o         (),
    .dmactive_o         (),
    .debug_req_o        ( debug_req  ),
    .unavailable_i      ( 1'b0       ),
    .hartinfo_i         ( hartinfo   ),

    .slave_req_i        ( dbg_mem_obi_req.req     ),
    .slave_we_i         ( dbg_mem_obi_req.a.we    ),
    .slave_addr_i       ( dbg_mem_obi_req.a.addr  ),
    .slave_be_i         ( dbg_mem_obi_req.a.be    ),
    .slave_wdata_i      ( dbg_mem_obi_req.a.wdata ),
    .slave_aid_i        ( dbg_mem_obi_req.a.aid   ),
    .slave_gnt_o        ( dbg_mem_obi_rsp.gnt     ),
    .slave_rvalid_o     ( dbg_mem_obi_rsp.rvalid  ),
    .slave_rdata_o      ( dbg_mem_obi_rsp.r.rdata ),
    .slave_rid_o        ( dbg_mem_obi_rsp.r.rid   ),

    .master_req_o       ( dbg_req_obi_req.req     ),
    .master_addr_o      ( dbg_req_obi_req.a.addr  ),
    .master_we_o        ( dbg_req_obi_req.a.we    ),
    .master_wdata_o     ( dbg_req_obi_req.a.wdata ),
    .master_be_o        ( dbg_req_obi_req.a.be    ),
    .master_gnt_i       ( dbg_req_obi_rsp.gnt     ),
    .master_rvalid_i    ( dbg_req_obi_rsp.rvalid  ),
    .master_rdata_i     ( dbg_req_obi_rsp.r.rdata ),
    .master_err_i       ( dbg_req_obi_rsp.r.err   ),
    .master_other_err_i ( 1'b0                    ),

    .dmi_rst_ni         ( dmi_rst_n      ),
    .dmi_req_valid_i    ( dmi_req_valid  ),
    .dmi_req_ready_o    ( dmi_req_ready  ),
    .dmi_req_i          ( dmi_req        ),

    .dmi_resp_valid_o   ( dmi_resp_valid ),
    .dmi_resp_ready_i   ( dmi_resp_ready ),
    .dmi_resp_o         ( dmi_resp       )
  );
  // unused
  assign dbg_mem_obi_rsp.r.r_optional = 1'b0;
  assign dbg_mem_obi_rsp.r.err        = 1'b0;

  // -----------------
  // Main Interconnect
  // -----------------

  obi_xbar #(
    .SbrPortObiCfg      ( MgrObiCfg            ),
    .MgrPortObiCfg      ( SbrObiCfg            ),
    .sbr_port_obi_req_t ( mgr_obi_req_t        ),
    .sbr_port_a_chan_t  ( mgr_obi_a_chan_t     ),
    .sbr_port_obi_rsp_t ( mgr_obi_rsp_t        ),
    .sbr_port_r_chan_t  ( mgr_obi_r_chan_t     ),
    .mgr_port_obi_req_t ( sbr_obi_req_t        ),
    .mgr_port_obi_rsp_t ( sbr_obi_rsp_t        ),
    .NumSbrPorts        ( NumXbarManagers      ),
    .NumMgrPorts        ( NumXbarSubordinates  ),
    .NumMaxTrans        ( 2                    ), //TODO check what we want (Default was 2)
    .NumAddrRules       ( $size(CrocAddrMap)   ),
    .addr_map_rule_t    ( addr_map_rule_t      ),
    .UseIdForRouting    ( 1'b0                 ),
    .Connectivity       ( XbarConnectivity     )
  ) i_main_xbar (
    .clk_i,
    .rst_ni,
    .testmode_i,

    // connections between managers and crossbar
    .sbr_ports_req_i  ( xbar_mgr_obi_req ),
    .sbr_ports_rsp_o  ( xbar_mgr_obi_rsp ),
    // connections between crossbar and subordinates
    .mgr_ports_req_o  ( all_sbr_obi_req ),
    .mgr_ports_rsp_i  ( all_sbr_obi_rsp ),

    .addr_map_i       ( CrocAddrMap ),
    .en_default_idx_i ( '1 ),
    .default_idx_i    ( '0 )
  );

  // -----------------
  // Memories
  // -----------------
  for (genvar i = 0; i < NumSramBanks; i++) begin : gen_sram_bank
    // Each bank may have a different depth (the last bank is the large one).
    localparam int unsigned BankNumWords  = SramBankNumWords(i);
    localparam int unsigned BankAddrWidth = cf_math_pkg::idx_width(BankNumWords);

    logic bank_req, bank_we, bank_gnt, bank_single_err;
    logic [SbrObiCfg.AddrWidth-1:0] bank_byte_addr;
    logic [BankAddrWidth-1:0] bank_word_addr;
    logic [SbrObiCfg.DataWidth-1:0] bank_wdata, bank_rdata;
    logic [SbrObiCfg.DataWidth/8-1:0] bank_be;

    obi_sram_shim #(
      .ObiCfg    ( SbrObiCfg     ),
      .obi_req_t ( sbr_obi_req_t ),
      .obi_rsp_t ( sbr_obi_rsp_t )
    ) i_sram_shim (
      .clk_i,
      .rst_ni,

      .obi_req_i ( xbar_mem_bank_obi_req[i] ),
      .obi_rsp_o ( xbar_mem_bank_obi_rsp[i] ),

      .req_o   ( bank_req       ),
      .we_o    ( bank_we        ),
      .addr_o  ( bank_byte_addr ),
      .wdata_o ( bank_wdata     ),
      .be_o    ( bank_be        ),

      .gnt_i   ( bank_gnt   ),
      .rdata_i ( bank_rdata )
    );

    assign bank_word_addr = bank_byte_addr[BankAddrWidth+2-1:2];

    tc_sram_impl #(
      .NumWords  ( BankNumWords ),
      .DataWidth ( 32 ),
      .NumPorts  (  1 ),
      .Latency   (  1 )
    ) i_sram (
      .clk_i,
      .rst_ni,

      .impl_i  ( sram_impl      ),
      .impl_o  (),

      .req_i   ( bank_req       ),
      .we_i    ( bank_we        ),
      .addr_i  ( bank_word_addr ),

      .wdata_i ( bank_wdata ),
      .be_i    ( bank_be    ),
      .rdata_o ( bank_rdata )
    );

    assign bank_gnt = 1'b1; // always ready for request
  end


  // Xbar space error subordinate
  obi_err_sbr #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMaxTrans ( 1             ),
    .RspData     ( 32'hBADCAB1E  )
  ) i_xbar_err (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .obi_req_i  ( xbar_error_obi_req ),
    .obi_rsp_o  ( xbar_error_obi_rsp )
  );


  // -----------------
  // Peripherals
  // -----------------

  // demultiplex to peripherals according to address map
  logic [cf_math_pkg::idx_width(NumPeriphs)-1:0] periph_idx;

  addr_decode #(
    .NoIndices ( NumPeriphs                     ),
    .NoRules   ( $size(PeriphAddrMap)           ),
    .addr_t    ( logic[SbrObiCfg.DataWidth-1:0] ),
    .rule_t    ( addr_map_rule_t                ),
    .Napot     ( 1'b0                           )
  ) i_addr_decode_periphs (
    .addr_i           ( xbar_periph_obi_req.a.addr ),
    .addr_map_i       ( PeriphAddrMap              ),
    .idx_o            ( periph_idx                 ),
    .dec_valid_o      (),
    .dec_error_o      (),
    .en_default_idx_i ( 1'b1        ),
    .default_idx_i    ( PeriphError )
  );

  obi_demux #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMgrPorts ( NumPeriphs    ),
    .NumMaxTrans ( 2             )
  ) i_obi_demux (
    .clk_i,
    .rst_ni,

    .sbr_port_select_i ( periph_idx          ),
    .sbr_port_req_i    ( xbar_periph_obi_req ),
    .sbr_port_rsp_o    ( xbar_periph_obi_rsp ),

    .mgr_ports_req_o   ( all_periph_obi_req  ),
    .mgr_ports_rsp_i   ( all_periph_obi_rsp  )
  );

  // SoC Control
  soc_ctrl_regs #(
    .obi_req_t       ( sbr_obi_req_t ),
    .obi_rsp_t       ( sbr_obi_rsp_t ),
    .BootAddrDefault ( BootAddr      )
  ) i_soc_ctrl (
    .clk_i,
    .rst_ni,
    .obi_req_i  ( soc_ctrl_obi_req ),
    .obi_rsp_o  ( soc_ctrl_obi_rsp ),
    .fetch_en_o ( fetch_enable     ),
    .sram_dly_o ( sram_impl        )
  );

  // UART
  obi_uart #(
    .ObiCfg    ( SbrObiCfg     ),
    .obi_req_t ( sbr_obi_req_t ),
    .obi_rsp_t ( sbr_obi_rsp_t )
  ) i_uart (
    .clk_i,
    .rst_ni,

    .obi_req_i ( uart_obi_req ),
    .obi_rsp_o ( uart_obi_rsp ),
    .irq_o     ( uart_irq     ),
    .irq_no    (),

    .rxd_i     ( uart_rx_i ),
    .txd_o     ( uart_tx_o ),

    // Modem control pins are optional
    .cts_ni    ( 1'b1 ),
    .dsr_ni    ( 1'b1 ),
    .ri_ni     ( 1'b1 ),
    .cd_ni     ( 1'b1 ),
    .rts_no    (),
    .dtr_no    (),
    .out1_no   (),
    .out2_no   ()
);

  // GPIO
  gpio #(
    .ObiCfg    ( SbrObiCfg     ),
    .obi_req_t ( sbr_obi_req_t ),
    .obi_rsp_t ( sbr_obi_rsp_t ),
    .GpioCount ( GpioCount     )
  ) i_gpio (
    .clk_i,
    .rst_ni,
    .gpio_i,
    .gpio_o,
    .gpio_out_en_o,
    .gpio_in_sync_o,
    .interrupt_o    ( gpio_irq     ),
    .obi_req_i      ( gpio_obi_req ),
    .obi_rsp_o      ( gpio_obi_rsp )
  );

  // CLINT
  clint #(
    .obi_req_t ( sbr_obi_req_t ),
    .obi_rsp_t ( sbr_obi_rsp_t )
  ) i_clint (
    .clk_i,
    .rst_ni,
    .rtc_i          ( ref_clk_i          ),
    .software_irq_o ( clint_software_irq ),
    .timer_irq_o    ( clint_timer_irq    ),
    .obi_req_i      ( clint_obi_req      ),
    .obi_rsp_o      ( clint_obi_rsp      )
  );

  // OBI timer
  obi_timer #(
    .obi_req_t ( sbr_obi_req_t ),
    .obi_rsp_t ( sbr_obi_rsp_t )
  ) i_obi_timer (
    .clk_i,
    .rst_ni,
    .obi_req_i  ( timer_obi_req ),
    .obi_rsp_o  ( timer_obi_rsp ),
    .expired_o  ( obi_timer_irq ),
    .overflow_o ()
  );

  // Bootrom
  bootrom #(
    .ObiCfg    ( SbrObiCfg     ),
    .obi_req_t ( sbr_obi_req_t ),
    .obi_rsp_t ( sbr_obi_rsp_t )
  ) i_bootrom (
    .clk_i,
    .rst_ni,
    .obi_req_i ( bootrom_obi_req ),
    .obi_rsp_o ( bootrom_obi_rsp )
  );

  // SRAM access monitor: counts reads/writes to the 3rd 512x32 bank
  // (gen_sram_bank[2]) within a configurable address window and raises an
  // interrupt after N accesses.
  sram_monitor #(
    .ObiCfg        ( SbrObiCfg           ),
    .obi_req_t     ( sbr_obi_req_t       ),
    .obi_rsp_t     ( sbr_obi_rsp_t       ),
    .WordBankDepth ( SramBankNumWords(2) )
  ) i_sram_monitor (
    .clk_i,
    .rst_ni,
    .cfg_obi_req_i ( sram_mon_obi_req ),
    .cfg_obi_rsp_o ( sram_mon_obi_rsp ),
    .bank_req_i    ( xbar_mem_bank_obi_req[1].req    ),
    .bank_we_i     ( xbar_mem_bank_obi_req[1].a.we   ),
    .bank_gnt_i    ( xbar_mem_bank_obi_rsp[1].gnt    ),
    .bank_addr_i   ( xbar_mem_bank_obi_req[1].a.addr ),
    .irq_o         ( sram_mon_irq                    )
  );

  // Peripheral space error subordinate
  obi_err_sbr #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMaxTrans ( 1             ),
    .RspData     ( 32'hBADCAB1E  )
  ) i_periph_err (
    .clk_i,
    .rst_ni,
    .testmode_i,
    .obi_req_i   ( error_obi_req ),
    .obi_rsp_o   ( error_obi_rsp )
  );

  // -----------------
  // Serial Link
  // -----------------


  logic [cf_math_pkg::idx_width(NumSlinkSbr)-1:0] slink_idx;

  addr_decode #(
    .NoIndices ( NumSlinkSbr                    ),
    .NoRules   ( $size(SlinkAddrMap)             ),
    .addr_t    ( logic[SbrObiCfg.DataWidth-1:0] ),
    .rule_t    ( addr_map_rule_t                ),
    .Napot     ( 1'b0                           )
  ) i_addr_decode_slink (
    .addr_i           ( xbar_slink_obi_req.a.addr ),
    .addr_map_i       ( SlinkAddrMap              ),
    .idx_o            ( slink_idx                 ),
    .dec_valid_o      (),
    .dec_error_o      (),
    .en_default_idx_i ( 1'b1       ),
    .default_idx_i    ( SlinkError )
  );

  obi_demux #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMgrPorts ( NumSlinkSbr   ),
    .NumMaxTrans ( 20             )
  ) i_obi_demux_slink (
    .clk_i,
    .rst_ni,

    .sbr_port_select_i ( slink_idx             ),
    .sbr_port_req_i    ( xbar_slink_obi_req    ),
    .sbr_port_rsp_o    ( xbar_slink_obi_rsp    ),

    .mgr_ports_req_o   ( all_slink_obi_req     ),
    .mgr_ports_rsp_i   ( all_slink_obi_rsp     )
  );

 // Error Subordinate Slink
  obi_err_sbr #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMaxTrans ( 1             ),
    .RspData     ( 32'hBADCAB1E  )
  ) i_slink_err (
    .clk_i,
    .rst_ni,
    .testmode_i ( testmode_i          ),
    .obi_req_i  ( slink_error_obi_req ),
    .obi_rsp_o  ( slink_error_obi_rsp )
  );

  localparam int unsigned ObiNodeIdWidth = 4;


  localparam slink_obi_cfg_t SlinkObiCfg = slink_obi_cfg(
      SbrObiCfg.AddrWidth, SbrObiCfg.DataWidth, SbrObiCfg.DataWidth, SbrObiCfg.IdWidth, ObiNodeIdWidth, SbrObiCfg.BeFull, (SbrObiCfg.OptionalCfg != '0));

  `SLINK_OBI_TYPEDEF_DEFAULT(slink_obi, SlinkObiCfg)
  
  slink #(
    .RecvFifoPayloadDepth (           1         ),
    .TxFifoDepth          (           3         ),
    .MaxOutstandingReqIn  (           2         ),
    .MaxInflightReqOut    (           2         ),
    .obi_req_mgr_t   ( mgr_obi_req_t            ),
    .obi_rsp_mgr_t   ( mgr_obi_rsp_t            ),
    .obi_req_sbr_t   ( sbr_obi_req_t            ),
    .obi_rsp_sbr_t   ( sbr_obi_rsp_t            ),
    .obi_r_chan_sbr_t( sbr_obi_r_chan_t         ),
    .a_optional_t    ( sbr_obi_a_chan_t         ), 
    .r_optional_t    ( sbr_obi_r_chan_t         ),
    .a_chan_write_t  ( slink_obi_a_chan_write_t ),
    .a_chan_read_t   ( slink_obi_a_chan_read_t  ),
    .r_chan_write_t  ( slink_obi_r_chan_write_t ),
    .r_chan_read_t   ( slink_obi_r_chan_read_t  ),
    .slink_obi_cfg   ( SlinkObiCfg              )
  ) i_slink (
    .clk_i             ( clk_i                   ),
    .rst_ni            ( rst_ni                  ),
    .testmode_i        ( testmode_i              ), 
    .obi_in_req_i      ( slink_obi_req_i         ),
    .obi_in_rsp_o      ( slink_obi_rsp_o         ),
    .obi_out_req_o     ( slink_obi_req_o         ),
    .obi_out_rsp_i     ( slink_obi_rsp_i         ),
    .obi_reg_req_i     ( slink_cfg_obi_req_i     ),
    .obi_reg_rsp_o     ( slink_cfg_obi_rsp_o     ),
    .ddr_rcv_clk_i     ( slink_ddr_rcv_clk_i     ),
    .ddr_rcv_clk_o     ( slink_ddr_rcv_clk_o     ),
    .ddr_i             ( slink_ddr_i             ),
    .ddr_o             ( slink_ddr_o             ),
    .credit_recv_clk_i ( slink_credit_recv_clk_i ),
    .credit_rtrn_clk_o ( slink_credit_rtrn_clk_o )
  );

endmodule
