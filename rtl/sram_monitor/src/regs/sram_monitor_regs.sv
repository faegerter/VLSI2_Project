// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>

`include "common_cells/registers.svh"

module sram_monitor_regs import sram_monitor_pkg::*; #(
  parameter type         obi_req_t = logic,
  parameter type         obi_rsp_t = logic,
  /// Width of the tracked in-bank byte address (START/END registers).
  parameter int unsigned AddrWidth = 11,
  /// Width of the access counter / threshold.
  parameter int unsigned CntWidth  = 10
) (
  input  logic clk_i,
  input  logic rst_ni,

  // OBI subordinate config/status port (CPU access)
  input  obi_req_t obi_req_i,
  output obi_rsp_t obi_rsp_o,

  // Configuration outputs (to the monitor datapath)
  output logic                 enable_o,
  output access_type_e         access_type_o,
  output logic [CntWidth-1:0]  threshold_o,
  output logic [AddrWidth-1:0] start_addr_o,
  output logic [AddrWidth-1:0] end_addr_o,

  // Status inputs (read back over the bus)
  input  logic [CntWidth-1:0]  count_i,
  input  logic                 irq_i,

  // One-cycle clear strobes to the monitor datapath
  output logic clear_count_o, // reset the access counter
  output logic clear_irq_o    // clear the pending interrupt
);

  // ---------------------------------------------------------------------------
  // Config registers
  // ---------------------------------------------------------------------------
  logic                 enable_q,      enable_d;
  access_type_e         access_type_q, access_type_d;
  logic [CntWidth-1:0]  threshold_q,   threshold_d;
  logic [AddrWidth-1:0] start_addr_q,  start_addr_d;
  logic [AddrWidth-1:0] end_addr_q,    end_addr_d;

  // ---------------------------------------------------------------------------
  // OBI decode (only the low byte offset is needed to select a register)
  // ---------------------------------------------------------------------------
  logic        obi_we;
  logic [7:0]  obi_addr;
  logic [31:0] obi_wdata;
  logic [31:0] obi_rdata;

  assign obi_we    = obi_req_i.req & obi_req_i.a.we;
  assign obi_addr  = obi_req_i.a.addr[7:0];
  assign obi_wdata = obi_req_i.a.wdata;

  // ---------------------------------------------------------------------------
  // Read mux
  // ---------------------------------------------------------------------------
  always_comb begin
    case (obi_addr)
      CtrlReg:      obi_rdata = {31'b0, enable_q};   // clear bit reads as 0
      ThresholdReg: obi_rdata = 32'(threshold_q);
      CountReg:     obi_rdata = 32'(count_i);
      StatusReg:    obi_rdata = {31'b0, irq_i};
      StartAddrReg: obi_rdata = 32'(start_addr_q);
      EndAddrReg:   obi_rdata = 32'(end_addr_q);
      AccessReg:    obi_rdata = {30'b0, access_type_q};
      default:      obi_rdata = 32'hBADCAB1E;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Write / control-pulse logic
  // ---------------------------------------------------------------------------
  always_comb begin
    enable_d      = enable_q;
    access_type_d = access_type_q;
    threshold_d   = threshold_q;
    start_addr_d  = start_addr_q;
    end_addr_d    = end_addr_q;
    clear_count_o = 1'b0;
    clear_irq_o   = 1'b0;

    if (obi_we) begin
      case (obi_addr)
        CtrlReg: begin
          enable_d = obi_wdata[0];
          if (obi_wdata[1]) begin // clear: reset count and IRQ, keep enable
            clear_count_o = 1'b1;
            clear_irq_o   = 1'b1;
          end
        end
        ThresholdReg: threshold_d   = obi_wdata[CntWidth-1:0];
        StartAddrReg: start_addr_d  = obi_wdata[AddrWidth-1:0];
        EndAddrReg:   end_addr_d    = obi_wdata[AddrWidth-1:0];
        AccessReg:    access_type_d = access_type_e'(obi_wdata[1:0]);
        default: ; // COUNT and STATUS are read-only
      endcase
    end

    // Reading STATUS clears the pending interrupt.
    if (obi_req_i.req && !obi_req_i.a.we && obi_addr == StatusReg)
      clear_irq_o = 1'b1;
  end

  `FF(enable_q,      enable_d,      1'b0,        clk_i, rst_ni)
  `FF(access_type_q, access_type_d, WriteAccess, clk_i, rst_ni)
  `FF(threshold_q,   threshold_d,   '0,          clk_i, rst_ni)
  `FF(start_addr_q,  start_addr_d,  '0,          clk_i, rst_ni)
  `FF(end_addr_q,    end_addr_d,    '1,          clk_i, rst_ni) // default: whole bank

  // ---------------------------------------------------------------------------
  // OBI response: grant now, registered response next cycle
  // ---------------------------------------------------------------------------
  logic                              rvalid_q;
  logic [31:0]                       rdata_q;
  logic [$bits(obi_req_i.a.aid)-1:0] rid_q;

  `FF(rvalid_q, obi_req_i.req,   1'b0, clk_i, rst_ni)
  `FF(rdata_q,  obi_rdata,       '0,   clk_i, rst_ni)
  `FF(rid_q,    obi_req_i.a.aid, '0,   clk_i, rst_ni)

  assign obi_rsp_o.gnt     = obi_req_i.req;
  assign obi_rsp_o.rvalid  = rvalid_q;
  assign obi_rsp_o.r.rdata = rdata_q;
  assign obi_rsp_o.r.rid   = rid_q;
  assign obi_rsp_o.r.err   = 1'b0;
  assign obi_rsp_o.r.r_optional = '0;

  // ---------------------------------------------------------------------------
  // Outputs
  // ---------------------------------------------------------------------------
  assign enable_o      = enable_q;
  assign access_type_o = access_type_q;
  assign threshold_o   = threshold_q;
  assign start_addr_o  = start_addr_q;
  assign end_addr_o    = end_addr_q;

endmodule
