// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>
//
// MAC accelerator.
//
// Computes  result = sum_{i=0}^{vec_len-1}  W[row_base + i*S] * x[base + i*S]
// (S = bytes per word) for each of num_row_i rows, asserting done_o for one
// cycle after each row.
//
// 3-stage pipeline (single-cycle SRAM: gnt and rvalid always asserted):
//
//   Cycle:   0      1      2      3    ...   N-1     N       N+1
//   S0 req: W[0]  W[1]  W[2]  W[3]  ...  W[N-1]   -        -
//   S1 mul:  -    W[0]  W[1]  W[2]  ...  W[N-2] W[N-1]     -
//   S2 acc:  -      -   p[0]  p[1]  ...  p[N-3] p[N-2]  p[N-1]
//
// Assumptions:
//   - SRAM is single-cycle: gnt is asserted the same cycle as req, and
//     rvalid arrives exactly one cycle later. No stalls.
//   - matrix_base_addr_i, x_base_addr_i, vec_len_i, and num_row_i are held
//     stable from start_i until the final done_o pulse.
//   - start_i is a single-cycle pulse.

`include "common_cells/registers.svh"

module mac_accelerator #(
  /// OBI configuration of the manager ports (provides data/address widths).
  parameter obi_pkg::obi_cfg_t ObiCfg      = obi_pkg::ObiDefaultConfig,
  parameter int unsigned       VecLen      = 8,
  parameter type               mgr_req_t   = logic,
  parameter type               mgr_rsp_t   = logic,
  /// Number of OBI manager ports (see mgr_port_e below).
  parameter int unsigned      NumMgrPorts = 2
) (
  input  logic clk_i,
  input  logic rst_ni,

  // ---------- control ----------
  input  logic                        start_i,
  input  logic [ObiCfg.AddrWidth-1:0] matrix_base_addr_i,
  input  logic [ObiCfg.AddrWidth-1:0] x_base_addr_i,     // Base address of x vector in SRAM
  input  logic [31:0]                 vec_len_i,         // Runtime vector length (<= VecLen)
  input  logic [31:0]                 num_row_i,         // Number of rows to compute sequentially
  // Back-pressure: the control reg file's pending-IRQ flag (its latched done
  // bit). The MAC holds in DONE until the CPU acknowledges the previous row's
  // IRQ (reads STATUS), so no done pulse is lost when the CPU cannot service
  // the per-row interrupt in time (e.g. a remote node stalled on a slink write).
  input  logic                        irq_pending_i,

  // ---------- result ----------
  output logic [ObiCfg.DataWidth-1:0] result_o,  // Valid during the done_o pulse
  output logic                        done_o,    // Single-cycle pulse after each row completes

  // ---------- OBI manager ports ----------
  // Indexed by mgr_port_e: PortMatrix = W reads, PortVector = x reads
  output mgr_req_t [NumMgrPorts-1:0] mgr_obi_req_o,
  input  mgr_rsp_t [NumMgrPorts-1:0] mgr_obi_rsp_i
);

  // -------------------------------------------------------------------------
  // Local parameters and types
  // -------------------------------------------------------------------------
  localparam int unsigned AddrWidth = ObiCfg.AddrWidth;
  localparam int unsigned DataWidth = ObiCfg.DataWidth;
  localparam int unsigned StrbWidth = DataWidth / 8;     // bytes per word (byte-enable width)
  localparam int unsigned ByteOff   = $clog2(StrbWidth); // address bits for the in-word byte offset
  localparam int unsigned IdxW      = $clog2(VecLen + 1);

  // OBI manager port selector (index into the manager port array)
  typedef enum logic [0:0] {
    PortMatrix = 1'd0,  // W matrix reads
    PortVector = 1'd1   // x vector reads
  } mgr_port_e;

  // -------------------------------------------------------------------------
  // FSM state encoding
  // -------------------------------------------------------------------------
  typedef enum logic [1:0] {
    IDLE,   // Waiting for start_i pulse
    FETCH,  // S0: issuing OBI read requests for W and x in lock-step
    DRAIN,  // S0 done; flushing the last two pipeline stages
    DONE    // One-cycle done_o pulse, then advance to next row or return to IDLE
  } state_e;

  // -------------------------------------------------------------------------
  // State and datapath registers (_q = current, _d = next)
  // -------------------------------------------------------------------------
  state_e               state_q,     state_d;
  logic [IdxW-1:0]      s0_idx_q,   s0_idx_d;   // Index of element currently being fetched
  logic [AddrWidth-1:0] s0_addr_q,  s0_addr_d;  // W fetch address for the current cycle
  logic [IdxW-1:0]      vec_len_q,  vec_len_d;  // Latched vector length (trimmed to IdxW bits)
  logic                 s1_valid_q, s1_valid_d; // S1: W/x responses are in-flight this cycle
  logic                 s2_valid_q, s2_valid_d; // S2: product register holds a valid result
  logic [DataWidth-1:0] product_q,  product_d;  // S2: registered W[i]*x[i] product
  logic [DataWidth-1:0] acc_q,      acc_d;      // S2: running accumulator
  logic [1:0]           drain_cnt_q, drain_cnt_d; // Cycles remaining to flush S1 and S2
  logic [31:0]          row_q,      row_d;      // Index of the current row
  logic [AddrWidth-1:0] row_base_q, row_base_d; // Base address of the current W row

  // -------------------------------------------------------------------------
  // OBI request channels — both ports issue in lock-step during FETCH
  // -------------------------------------------------------------------------
  logic issue_req;
  assign issue_req = (state_q == FETCH);

  always_comb begin
    mgr_obi_req_o[PortMatrix]         = '0;
    mgr_obi_req_o[PortMatrix].req     = issue_req;
    mgr_obi_req_o[PortMatrix].a.addr  = s0_addr_q;          // W[row][i] address
    mgr_obi_req_o[PortMatrix].a.we    = 1'b0;
    mgr_obi_req_o[PortMatrix].a.be    = '1;
    mgr_obi_req_o[PortMatrix].a.wdata = '0;
  end

  always_comb begin
    mgr_obi_req_o[PortVector]         = '0;
    mgr_obi_req_o[PortVector].req     = issue_req;
    mgr_obi_req_o[PortVector].a.addr  = x_base_addr_i + (s0_idx_q << ByteOff);  // x[i] address
    mgr_obi_req_o[PortVector].a.we    = 1'b0;
    mgr_obi_req_o[PortVector].a.be    = '1;
    mgr_obi_req_o[PortVector].a.wdata = '0;
  end

  // OBI handshake and read-data aliases
  logic                 req_granted;
  logic                 rsp_valid;
  logic [DataWidth-1:0] w_data;
  logic [DataWidth-1:0] x_data;

  assign req_granted = mgr_obi_req_o[PortMatrix].req & mgr_obi_rsp_i[PortMatrix].gnt;
  assign rsp_valid   = mgr_obi_rsp_i[PortMatrix].rvalid;
  assign w_data      = mgr_obi_rsp_i[PortMatrix].r.rdata;
  assign x_data      = mgr_obi_rsp_i[PortVector].r.rdata;

  // -------------------------------------------------------------------------
  // Combinational next-state and datapath logic
  // -------------------------------------------------------------------------
  always_comb begin
    // Default: hold all state; outputs deasserted
    state_d     = state_q;
    s0_idx_d    = s0_idx_q;
    s0_addr_d   = s0_addr_q;
    vec_len_d   = vec_len_q;
    s1_valid_d  = 1'b0;
    s2_valid_d  = 1'b0;
    product_d   = product_q;
    acc_d       = acc_q;
    drain_cnt_d = drain_cnt_q;
    row_d       = row_q;
    row_base_d  = row_base_q;
    done_o      = 1'b0;
    result_o    = acc_q;

    // ------------------------------------------------------------------
    // S1: Multiply — W and x responses arrive one cycle after the request
    // ------------------------------------------------------------------
    if (rsp_valid && s1_valid_q) begin
      s2_valid_d = 1'b1;
      product_d  = w_data * x_data;
    end

    // ------------------------------------------------------------------
    // S2: Accumulate — add the registered product into the accumulator
    // ------------------------------------------------------------------
    if (s2_valid_q) begin
      acc_d = acc_q + product_q;
    end

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    case (state_q)

      IDLE: begin
        if (start_i) begin
          vec_len_d   = vec_len_i[IdxW-1:0];
          s0_addr_d   = matrix_base_addr_i;
          row_base_d  = matrix_base_addr_i;
          s0_idx_d    = '0;
          row_d       = '0;
          acc_d       = '0;
          s1_valid_d  = 1'b0;
          s2_valid_d  = 1'b0;
          drain_cnt_d = '0;
          state_d     = FETCH;
        end
      end

      FETCH: begin
        if (req_granted) begin
          s1_valid_d = 1'b1;
          s0_addr_d  = s0_addr_q + StrbWidth;  // next word
          s0_idx_d   = s0_idx_q  + 1;

          if (s0_idx_q == vec_len_q - 1) begin
            // Last element requested; two more cycles needed to flush S1 and S2
            drain_cnt_d = 2'd2;
            state_d     = DRAIN;
          end
        end
      end

      DRAIN: begin
        // Non-stalling SRAM: decrement every cycle until pipeline is empty
        drain_cnt_d = drain_cnt_q - 1;
        if (drain_cnt_q == 2'd1)
          state_d = DONE;
      end

      DONE: begin
        // Wait until the CPU has acknowledged the previous row's IRQ (the reg
        // file clears its done/irq flag on a STATUS read) before emitting this
        // row's done pulse and advancing. Prevents lost done pulses when the
        // CPU cannot service the per-row interrupt in time.
        if (!irq_pending_i) begin
          // Signal row completion for one cycle, then advance.
          done_o   = 1'b1;
          result_o = acc_q;

          if (row_q == num_row_i - 1) begin
            // All rows complete — return to idle
            state_d = IDLE;
          end else begin
            // Advance to the next row
            row_d       = row_q + 1;
            row_base_d  = row_base_q + (vec_len_q << ByteOff);
            s0_addr_d   = row_base_q + (vec_len_q << ByteOff);
            s0_idx_d    = '0;
            acc_d       = '0;
            s1_valid_d  = 1'b0;
            s2_valid_d  = 1'b0;
            drain_cnt_d = '0;
            state_d     = FETCH;
          end
        end
        // else: remain in DONE, holding result_o = acc_q with done_o = 0
        // (both defaults) until the pending IRQ is acknowledged.
      end

      default: state_d = IDLE;

    endcase
  end

  // -------------------------------------------------------------------------
  // State registers
  // -------------------------------------------------------------------------
  `FF(state_q,     state_d,     IDLE, clk_i, rst_ni)
  `FF(s0_idx_q,    s0_idx_d,    '0,   clk_i, rst_ni)
  `FF(s0_addr_q,   s0_addr_d,   '0,   clk_i, rst_ni)
  `FF(vec_len_q,   vec_len_d,   '0,   clk_i, rst_ni)
  `FF(s1_valid_q,  s1_valid_d,  '0,   clk_i, rst_ni)
  `FF(s2_valid_q,  s2_valid_d,  '0,   clk_i, rst_ni)
  `FF(product_q,   product_d,   '0,   clk_i, rst_ni)
  `FF(acc_q,       acc_d,       '0,   clk_i, rst_ni)
  `FF(drain_cnt_q, drain_cnt_d, '0,   clk_i, rst_ni)
  `FF(row_base_q,  row_base_d,  '0,   clk_i, rst_ni)
  `FF(row_q,       row_d,       '0,   clk_i, rst_ni)

endmodule
