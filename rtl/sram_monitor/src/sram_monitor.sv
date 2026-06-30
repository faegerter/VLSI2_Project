// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>
//
// SRAM access monitor.
//
// Passively snoops one SRAM bank's OBI request channel and raises an interrupt once a configurable number of
// accesses to a configurable address window have occurred. 


`include "common_cells/registers.svh"

module sram_monitor import sram_monitor_pkg::*; #(
  /// OBI configuration of the watched bank port (provides the address width).
  parameter obi_pkg::obi_cfg_t ObiCfg        = obi_pkg::ObiDefaultConfig,
  parameter type               obi_req_t     = logic,
  parameter type               obi_rsp_t     = logic,
  /// Number of 32-bit words in the watched SRAM bank.
  parameter int unsigned       WordBankDepth = 512
) (
  input  logic clk_i,
  input  logic rst_ni,

  // OBI subordinate config/status port (CPU access)
  input  obi_req_t cfg_obi_req_i,
  output obi_rsp_t cfg_obi_rsp_o,

  // Passive monitor tap on the watched SRAM bank's OBI request channel.
  // An access is (req & gnt); its direction is given by we (1 = write).
  input  logic                        bank_req_i,
  input  logic                        bank_we_i,
  input  logic                        bank_gnt_i,
  input  logic [ObiCfg.AddrWidth-1:0] bank_addr_i,

  // Level-high interrupt, asserted until cleared (STATUS read or CTRL.clear).
  output logic irq_o
);

  // Minimal widths derived from the bank depth, to reduce flip-flop count.
  // idx_width(WordBankDepth) is the word-index width; +2 for the byte offset.
  localparam int unsigned BankAddrWidth = cf_math_pkg::idx_width(WordBankDepth) + 2; // in-bank byte address
  localparam int unsigned CntWidth      = cf_math_pkg::idx_width(WordBankDepth) + 1; // counter / threshold

  // Configuration from the register file
  logic                     enable;
  access_type_e             access_type;
  logic [CntWidth-1:0]      threshold;
  logic [BankAddrWidth-1:0] start_addr;
  logic [BankAddrWidth-1:0] end_addr;
  logic                     clear_count;
  logic                     clear_irq;

  // Monitor state
  logic [CntWidth-1:0] count_q, count_d;
  logic                irq_q,   irq_d;

  // ---------------------------------------------------------------------------
  // Configuration register file
  // ---------------------------------------------------------------------------
  sram_monitor_regs #(
    .obi_req_t ( obi_req_t     ),
    .obi_rsp_t ( obi_rsp_t     ),
    .AddrWidth ( BankAddrWidth ),
    .CntWidth  ( CntWidth      )
  ) i_regs (
    .clk_i,
    .rst_ni,
    .obi_req_i     ( cfg_obi_req_i ),
    .obi_rsp_o     ( cfg_obi_rsp_o ),
    .enable_o      ( enable        ),
    .access_type_o ( access_type   ),
    .threshold_o   ( threshold     ),
    .start_addr_o  ( start_addr    ),
    .end_addr_o    ( end_addr      ),
    .count_i       ( count_q       ),
    .irq_i         ( irq_q         ),
    .clear_count_o ( clear_count   ),
    .clear_irq_o   ( clear_irq     )
  );

  // ---------------------------------------------------------------------------
  // Access qualification: compare only the in-bank address bits (the upper bits
  // are constant for all accesses that reach this bank).
  // ---------------------------------------------------------------------------
  logic [BankAddrWidth-1:0] mon_addr;
  logic in_window, access, dir_match, count_event, fire;

  assign mon_addr    = bank_addr_i[BankAddrWidth-1:0];
  assign in_window   = (mon_addr >= start_addr) && (mon_addr <= end_addr);
  assign access      = bank_req_i & bank_gnt_i & in_window;
  assign dir_match   = (access_type == WriteAccess) ?  bank_we_i :
                       (access_type == ReadAccess)  ? ~bank_we_i :
                                                       1'b1;       // RWAccess
  assign count_event = enable & access & dir_match;
  assign fire        = count_event && (threshold != '0) &&
                       (count_q + 1 >= threshold);

  // ---------------------------------------------------------------------------
  // Counter + interrupt latch (SW clear overrides a coincident event)
  // ---------------------------------------------------------------------------
  always_comb begin
    count_d = count_q;
    irq_d   = irq_q;

    if (count_event) count_d = fire ? '0 : (count_q + 1'b1);
    if (fire)        irq_d   = 1'b1;

    if (clear_count) count_d = '0;
    if (clear_irq)   irq_d   = 1'b0;
  end

  `FF(count_q, count_d, '0,   clk_i, rst_ni)
  `FF(irq_q,   irq_d,   1'b0, clk_i, rst_ni)

  assign irq_o = irq_q;

endmodule
