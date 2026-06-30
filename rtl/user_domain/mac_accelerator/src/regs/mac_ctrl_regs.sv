// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>

`include "common_cells/registers.svh"

// MAC control register file
//
// Register map (byte-addressed from MAC_CTRL_BASE):
//   Offset 0x00 : matrix_base_addr  (R/W) — base address of W in SRAM
//   Offset 0x04 : vec_len           (R/W) — number of elements in x (<= VecLen)
//   Offset 0x08 : num_row           (R/W) — number of rows for the MAC to compute
//   Offset 0x0C : result            (R)   — dot-product result of the last completed row
//   Offset 0x10 : status            (R)   — bit 0 = done (latched; cleared on read)
//   Offset 0x1C : x_base_addr       (R/W) — base address of x in SRAM
//   Offset 0x24 : start             (W)   — write any value to issue a one-cycle start
//                                           pulse; reading returns the pending irq_start flag
//
// Interrupt outputs:
//   irq_o       — mirrors the done flag; asserted until status is read
//   irq_start_o — asserted on a write to 0x24; cleared on a read of 0x24

module mac_ctrl_regs #(
  parameter type obi_req_t = logic,
  parameter type obi_rsp_t = logic
) (
  input  logic clk_i,
  input  logic rst_ni,

  // OBI subordinate port (CPU access)
  input  obi_req_t obi_req_i,
  output obi_rsp_t obi_rsp_o,

  // To MAC accelerator
  output logic [31:0] matrix_base_addr_o,
  output logic [31:0] x_base_addr_o,
  output logic [31:0] vec_len_o,
  output logic [31:0] num_row_o,
  output logic        start_o,      // Single-cycle pulse to start the MAC

  // From MAC accelerator
  input  logic [31:0] result_i,
  input  logic        done_i,       // Single-cycle pulse: row computation complete

  // Interrupts to CPU
  output logic        irq_o,        // Asserted while done flag is set; cleared on status read
  output logic        irq_start_o   // Asserted on start write; cleared on start read
);

  // -------------------------------------------------------------------------
  // Register declarations (_q = present state, _d = next state)
  // -------------------------------------------------------------------------
  logic [31:0] matrix_base_addr_q, matrix_base_addr_d;
  logic [31:0] x_base_addr_q,      x_base_addr_d;
  logic [31:0] vec_len_q,          vec_len_d;
  logic [31:0] num_row_q,          num_row_d;
  logic [31:0] result_q,           result_d;
  logic        done_q,             done_d;
  logic        start_q,            start_d;
  logic        irq_start_q,        irq_start_d;

  // -------------------------------------------------------------------------
  // OBI bus signal aliases
  // -------------------------------------------------------------------------
  logic        obi_we;
  logic [31:0] obi_addr;
  logic [31:0] obi_wdata;
  logic [31:0] obi_rdata;

  assign obi_we    = obi_req_i.req & obi_req_i.a.we;
  assign obi_addr  = obi_req_i.a.addr;
  assign obi_wdata = obi_req_i.a.wdata;

  // -------------------------------------------------------------------------
  // OBI response — grant immediately; rvalid, rdata and rid registered one
  // cycle later. The request id (aid) is echoed back as rid; err is never set.
  // -------------------------------------------------------------------------
  logic                              rvalid_q;
  logic [31:0]                       rdata_q;
  logic [$bits(obi_req_i.a.aid)-1:0] rid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvalid_q <= 1'b0;
      rdata_q  <= '0;
      rid_q    <= '0;
    end else begin
      rvalid_q <= obi_req_i.req;
      rdata_q  <= obi_rdata;
      rid_q    <= obi_req_i.a.aid;
    end
  end

  assign obi_rsp_o.gnt     = obi_req_i.req;
  assign obi_rsp_o.rvalid  = rvalid_q;
  assign obi_rsp_o.r.rdata = rdata_q;
  assign obi_rsp_o.r.rid   = rid_q;
  assign obi_rsp_o.r.err   = 1'b0;
  assign obi_rsp_o.r.r_optional = '0;

  // -------------------------------------------------------------------------
  // Read mux (combinational)
  // -------------------------------------------------------------------------
  always_comb begin
    obi_rdata = '0;
    case (obi_addr[7:0])
      8'h00:   obi_rdata = matrix_base_addr_q;
      8'h04:   obi_rdata = vec_len_q;
      8'h08:   obi_rdata = num_row_q;
      8'h0C:   obi_rdata = result_q;
      8'h10:   obi_rdata = {31'b0, done_q};
      8'h1C:   obi_rdata = x_base_addr_q;
      8'h24:   obi_rdata = {31'b0, irq_start_q};
      default: obi_rdata = 32'hBADCAB1E;
    endcase
  end

  // -------------------------------------------------------------------------
  // Next-state logic (combinational)
  // -------------------------------------------------------------------------
  always_comb begin
    // Default: hold all state
    matrix_base_addr_d = matrix_base_addr_q;
    x_base_addr_d      = x_base_addr_q;
    vec_len_d          = vec_len_q;
    num_row_d          = num_row_q;
    result_d           = result_q;
    done_d             = done_q;
    start_d            = 1'b0;       // Start is a pulse; de-assert every cycle by default
    irq_start_d        = irq_start_q;

    // Latch result and assert done flag on MAC row completion
    if (done_i) begin
      result_d = result_i;
      done_d   = 1'b1;
    end

    // CPU writes
    if (obi_we) begin
      case (obi_addr[7:0])
        8'h00: matrix_base_addr_d = obi_wdata;
        8'h04: vec_len_d          = obi_wdata;
        8'h08: num_row_d          = obi_wdata;
        8'h1C: x_base_addr_d      = obi_wdata;
        8'h24: begin
          start_d     = 1'b1;  // Issue one-cycle start pulse
          irq_start_d = 1'b1;  // Latch IRQ until acknowledged
        end
        default: ;  // result (0x0C) and status (0x10) are read-only
      endcase
    end

    // CPU reads that have side effects
    if (obi_req_i.req && !obi_req_i.a.we) begin
      case (obi_addr[7:0])
        8'h10: done_d      = 1'b0;  // Reading status clears the done flag
        8'h24: irq_start_d = 1'b0;  // Reading start reg acknowledges the IRQ
        default: ;
      endcase
    end
  end

  // -------------------------------------------------------------------------
  // State registers
  // -------------------------------------------------------------------------
  `FF(matrix_base_addr_q, matrix_base_addr_d, '0,   clk_i, rst_ni)
  `FF(x_base_addr_q,      x_base_addr_d,      '0,   clk_i, rst_ni)
  `FF(vec_len_q,          vec_len_d,          '0,   clk_i, rst_ni)
  `FF(num_row_q,          num_row_d,          '0,   clk_i, rst_ni)
  `FF(result_q,           result_d,           '0,   clk_i, rst_ni)
  `FF(done_q,             done_d,             1'b0, clk_i, rst_ni)
  `FF(start_q,            start_d,            1'b0, clk_i, rst_ni)
  `FF(irq_start_q,        irq_start_d,        1'b0, clk_i, rst_ni)

  // -------------------------------------------------------------------------
  // Outputs
  // -------------------------------------------------------------------------
  assign matrix_base_addr_o = matrix_base_addr_q;
  assign x_base_addr_o      = x_base_addr_q;
  assign vec_len_o          = vec_len_q;
  assign num_row_o          = num_row_q;
  assign start_o            = start_q;
  assign irq_o              = done_q;
  assign irq_start_o        = irq_start_q;

endmodule