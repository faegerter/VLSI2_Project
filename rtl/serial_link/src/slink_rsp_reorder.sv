// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Llorenç Muela Hausmann <lmuela@ethz.ch>
// Author: Fabian Aegerter <faegerter@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

module slink_rsp_reorder #(
    parameter int unsigned  MaxOutstanding = 2,
    parameter type          obi_r_chan_t   = logic,
    parameter type          obi_id_t       = logic,
    localparam int unsigned IdxWidth       = (MaxOutstanding > 1) ? $clog2(MaxOutstanding) : 1
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    output logic                          full_o,
    output logic    [IdxWidth-1:0]        tail_idx_o,
    output logic    [IdxWidth-1:0]        head_idx_o,
    output obi_id_t [MaxOutstanding-1:0]  saved_aid_o,
    output logic    [MaxOutstanding-1:0]  pending_o,
    input  logic                          alloc_i,
    input  obi_id_t                       alloc_aid_i,
    input  logic                          fill_valid_i,
    input  logic [IdxWidth-1:0]           fill_idx_i,
    input  obi_r_chan_t                   fill_data_i,
    output logic                          fill_ready_o,
    output logic                          head_valid_o,
    output obi_r_chan_t                   head_data_o,
    input  logic                          head_ready_i
);

    function automatic logic [IdxWidth-1:0] incr_wrap(logic [IdxWidth-1:0] v);
        return (v == IdxWidth'(MaxOutstanding - 1)) ? '0 : v + 1'b1;
    endfunction

    logic    [IdxWidth-1:0]              head_q, head_d;
    logic    [IdxWidth-1:0]              tail_q, tail_d;
    logic    [MaxOutstanding-1:0]        pending_q, pending_d;
    obi_id_t [MaxOutstanding-1:0]        ids_q, ids_d;

    logic     [MaxOutstanding-1:0]       sr_clear;

    logic     [MaxOutstanding-1:0]       sr_in_valid;
    logic     [MaxOutstanding-1:0]       sr_in_ready;
    obi_r_chan_t [MaxOutstanding-1:0]    sr_in_data;
    logic     [MaxOutstanding-1:0]       sr_out_valid;
    logic     [MaxOutstanding-1:0]       sr_out_ready;
    obi_r_chan_t [MaxOutstanding-1:0]    sr_out_data;

    `FF(head_q,    head_d,    '0)
    `FF(tail_q,    tail_d,    '0)
    `FF(pending_q, pending_d, '0)
    `FF(ids_q,     ids_d,     '0)


    for (genvar i = 0; i < MaxOutstanding; i++) begin : gen_slot_regs
        stream_register #(
            .T (obi_r_chan_t)
        ) i_slot_reg (
            .clk_i      ( clk_i           ),
            .rst_ni     ( rst_ni          ),
            .clr_i      ( sr_clear[i]     ),
            .testmode_i ( 1'b0            ),
            .valid_i    ( sr_in_valid[i]  ),
            .ready_o    ( sr_in_ready[i]  ),
            .data_i     ( sr_in_data[i]   ),
            .valid_o    ( sr_out_valid[i] ),
            .ready_i    ( sr_out_ready[i] ),
            .data_o     ( sr_out_data[i]  )
        );
    end

    logic fill_at_head;
    assign fill_at_head = fill_valid_i && (fill_idx_i == head_q);


    always_comb begin : fill_demux
        sr_in_valid             = '0;
        sr_in_data              = '{default: '0};
        sr_in_data [fill_idx_i] = fill_data_i;
        if (!fill_at_head) begin
            sr_in_valid[fill_idx_i] = fill_valid_i;
        end
    end
    assign fill_ready_o = fill_at_head ? head_ready_i : sr_in_ready[fill_idx_i];


    assign head_valid_o = fill_at_head ? 1'b1          : sr_out_valid[head_q];
    assign head_data_o  = fill_at_head ? fill_data_i   : sr_out_data [head_q];

    always_comb begin : head_drain_mux
        sr_out_ready         = '0;
        sr_clear             = '0;
        if (!fill_at_head) begin
            sr_out_ready[head_q] = head_ready_i;
        end
    end


    assign tail_idx_o  = tail_q;
    assign head_idx_o  = head_q;
    assign full_o      = pending_q[tail_q];
    assign saved_aid_o = ids_q;
    assign pending_o   = pending_q;

    always_comb begin : state_update
        head_d    = head_q;
        tail_d    = tail_q;
        pending_d = pending_q;
        ids_d     = ids_q;

        if (alloc_i && !full_o) begin
            ids_d[tail_q]     = alloc_aid_i;
            pending_d[tail_q] = 1'b1;
            tail_d            = incr_wrap(tail_q);
        end

        if (head_valid_o && head_ready_i) begin
            pending_d[head_q] = 1'b0;
            head_d            = incr_wrap(head_q);
        end
    end

    //////////////////////
    //   ASSERTIONS     //
    //////////////////////

    `ASSERT(NoAllocWhenFull,    alloc_i        |-> !full_o)
    `ASSERT(FillOnPendingSlot,  fill_valid_i   |-> pending_q[fill_idx_i])
    `ASSERT(DrainOnPendingSlot, head_valid_o   |-> pending_q[head_q])

endmodule : slink_rsp_reorder
