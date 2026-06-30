// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Llorenç Muela Hausmann <lmuela@ethz.ch>
// Author: Fabian Aegerter <faegerter@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"


module slink_prot_layer #(
    parameter int  TxFifoDepth = 3,
    parameter int  MaxOutstandingReqIn = 2,
    parameter int  MaxInflightReqOut = 2,
    parameter int  NodeIdWidth = 4,
    parameter type obi_req_mgr_t  = logic,
    parameter type obi_rsp_mgr_t  = logic,
    parameter type obi_req_sbr_t  = logic,
    parameter type obi_rsp_sbr_t  = logic,
    parameter type obi_r_chan_sbr_t = logic,
    parameter type a_optional_t  = logic,
    parameter type r_optional_t  = logic,
    parameter type axis_req_t = logic,
    parameter type axis_rsp_t = logic,
    parameter type a_chan_write_t   = logic,
    parameter type a_chan_read_t    = logic,
    parameter type r_chan_write_t   = logic,
    parameter type r_chan_read_t    = logic,
    parameter type payload_t  = logic,
    parameter slink_pkg::slink_obi_cfg_t slink_obi_cfg
) (
    input  logic      clk_i,
    input  logic      rst_ni,
    input  logic[NodeIdWidth-1:0] node_id_i,
    input  logic[NodeIdWidth-1:0] global_addr_i,
    // TODO Consider renaming in/out to sbr/mgr... Maybe? Not sure...
    input  obi_req_sbr_t  obi_in_req_i,
    output obi_rsp_sbr_t  obi_in_rsp_o,
    output obi_req_mgr_t  obi_out_req_o,
    input  obi_rsp_mgr_t  obi_out_rsp_i,
    output axis_req_t axis_out_req_o,
    input  axis_rsp_t axis_out_rsp_i,
    input  axis_req_t axis_in_req_i,
    output axis_rsp_t axis_in_rsp_o,
    output logic      error_looped_rsp_o
);

    localparam int unsigned IdxWidth = (MaxOutstandingReqIn > 1) ? $clog2(MaxOutstandingReqIn) : 1;
    localparam int unsigned TxFifoAddrDepth = (TxFifoDepth > 1) ? $clog2(TxFifoDepth) : 1;
    localparam int unsigned TxFifoCntrDepth = (TxFifoDepth > 1) ? $clog2(TxFifoDepth+1) : 1;
    localparam int unsigned InflightReqOutAddrDepth = (MaxInflightReqOut > 1) ? $clog2(MaxInflightReqOut) : 1;
    localparam int unsigned InflightReqOutCntrDepth = (MaxInflightReqOut > 1) ? $clog2(MaxInflightReqOut+1) : 1;


    // AID and RID inside link for ordering purposes. No need to match to sbr or mgr.
    // Relation slink_obi_cfg.IDWidth >= IdxWidth must nevertheless hold!
    typedef logic [slink_obi_cfg.IDWidth-1:0]     obi_id_t;

    // These are supposed to be shared between sbr and mgr, as well as to be the same for link
    typedef logic [slink_obi_cfg.DataWidth-1:0]   obi_data_t;
    typedef logic [slink_obi_cfg.DataWidth/8-1:0] obi_be_t;
    typedef logic [slink_obi_cfg.AddrWidth-1:0]   obi_addr_t;
    // AIDs and RIDs for sbr and mgr (may be different)
    typedef logic [$bits(obi_in_req_i.a.aid)-1:0]  obi_sbr_id_t;
    typedef logic [$bits(obi_out_req_o.a.aid)-1:0] obi_mgr_id_t;

    typedef logic [NodeIdWidth-1:0] node_id_t;
    typedef logic [IdxWidth-1:0]    rsp_reorder_idx_t;


    typedef struct packed {
        node_id_t src_id;
        logic is_write;
        // Global writes occupy an inflight slot to keep the shared OBI response
        // channel ordered, but their response is dropped instead of sent back.
        logic is_global;
        obi_id_t obi_id;
    } out_req_inflight_meta_t;


    typedef struct packed {
        slink_pkg::tx_type_e tx_type;
        obi_sbr_id_t aid;
        logic is_write;
        node_id_t dst_id;
    } tx_meta_t;

    typedef struct packed {
        slink_pkg::rx_type_e rx_type;
        logic is_write;
    } rx_meta_t;


    //////////////////
    //   FUNCTIONS  //
    //////////////////

    function automatic obi_r_chan_sbr_t obi_r_chan_pack(obi_data_t rdata, obi_sbr_id_t rid, logic err, r_optional_t r_optional);
        return '{
            rdata: rdata,
            rid: rid,
            err: err,
            r_optional: r_optional
        };
    endfunction

    function automatic node_id_t get_node_id_from_addr(obi_addr_t addr);
        return addr[slink_obi_cfg.AddrWidth-1 -: NodeIdWidth];
    endfunction

    function automatic obi_addr_t get_local_addr(obi_addr_t addr);
        return {{NodeIdWidth{1'b0}}, addr[slink_obi_cfg.AddrWidth-1 : 0]};
    endfunction

    function automatic payload_t make_r_payload(
        logic is_write,
        node_id_t src_id,
        node_id_t dst_id,
        r_chan_write_t rwr,
        r_chan_read_t  rrd
    );
        payload_t ret;
        ret        = '0;
        ret.src_id = src_id;
        ret.dst_id = dst_id;
        if (is_write) begin
            ret.hdr    = slink_pkg::TagRWrite;
            ret.obi_ch = rwr;
        end else begin
            ret.hdr    = slink_pkg::TagRRead;
            ret.obi_ch = rrd;
        end
        return ret;
    endfunction

    function automatic payload_t make_a_payload(
        logic is_write,
        node_id_t src_id,
        node_id_t dst_id,
        a_chan_write_t awr,
        a_chan_read_t  ard
    );
        payload_t ret;
        ret        = '0;
        ret.src_id = src_id;
        ret.dst_id = dst_id;
        if (is_write) begin
            ret.hdr    = slink_pkg::TagAWrite;
            ret.obi_ch = awr;
        end else begin
            ret.hdr    = slink_pkg::TagARead;
            ret.obi_ch = ard;
        end
        return ret;
    endfunction


    function automatic payload_t make_global_payload(
        node_id_t src_id,
        a_chan_write_t awr
    );
        payload_t ret;
        ret        = '0;
        ret.src_id = src_id;
        ret.hdr    = slink_pkg::TagWriteGlobal;
        ret.obi_ch = awr;
        return ret;
    endfunction



    ///////////////////////////////
    //   TX ARBITER SIGNALS      //
    ///////////////////////////////

    logic rr_tx_out_arb_q, rr_tx_out_arb_d;
    payload_t payload_out, payload_in;
    tx_meta_t tx_meta;
    node_id_t obi_in_addr_to_nid;

    `FF(rr_tx_out_arb_q, rr_tx_out_arb_d, '0);

    ////////////////////////////
    //   TX FIFO SIGNALS      //
    ////////////////////////////

    logic tx_fifo_valid_out, tx_fifo_ready_out;
    logic tx_fifo_valid_in, tx_fifo_ready_in;
    payload_t tx_fifo_data_in, tx_fifo_data_out;
    logic [TxFifoAddrDepth-1:0] tx_fifo_fill_state;

    /////////////////////////////////////
    //   ISSUED REQUESTS FIFO SIGNALS  //
    /////////////////////////////////////

    out_req_inflight_meta_t out_req_inflight_fifo_data_in;
    out_req_inflight_meta_t out_req_inflight_fifo_data_out;
    logic [InflightReqOutAddrDepth-1:0] out_req_inflight_fifo_fill_state;
    logic out_req_inflight_fifo_pop;
    logic out_req_inflight_fifo_push;
    logic out_req_inflight_fifo_full;
    logic out_req_inflight_fifo_empty;

    ////////////////////////////////
    //   REORDER BUFFER SIGNALS   //
    ////////////////////////////////

    logic rsp_reorder_full;
    rsp_reorder_idx_t rsp_reorder_tail_idx, rsp_reorder_head_idx;
    obi_sbr_id_t [MaxOutstandingReqIn-1:0] rsp_reorder_saved_aid;
    logic rsp_reorder_alloc;
    obi_sbr_id_t rsp_reorder_alloc_aid;
    logic rsp_reorder_fill_valid;
    rsp_reorder_idx_t rsp_reorder_fill_idx;
    obi_r_chan_sbr_t rsp_reorder_fill_data;
    logic rsp_reorder_fill_ready;
    logic rsp_reorder_head_valid;
    obi_r_chan_sbr_t rsp_reorder_head_data;
    logic rsp_reorder_head_ready;

    logic self_req_pend_fill_accept;
    logic self_req_pend_fill_d, self_req_pend_fill_q;
    rsp_reorder_idx_t self_req_pend_fill_idx_d, self_req_pend_fill_idx_q;
    logic self_req_pend_err_d, self_req_pend_err_q;

    `FF(self_req_pend_fill_q, self_req_pend_fill_d, '0)
    `FF(self_req_pend_fill_idx_q, self_req_pend_fill_idx_d, '0)
    `FF(self_req_pend_err_q, self_req_pend_err_d, '0)

    ////////////////////////////
    //   OBI CHANNEL SIGNALS  //
    ////////////////////////////

    r_chan_write_t r_chan_write_out;
    r_chan_read_t  r_chan_read_out;
    a_chan_write_t a_chan_write_out;
    a_chan_read_t  a_chan_read_out;


    r_chan_write_t r_chan_write_in;
    r_chan_read_t  r_chan_read_in;
    a_chan_write_t a_chan_write_in;
    a_chan_read_t  a_chan_read_in;

    a_optional_t a_chan_read_optional_in;
    a_optional_t a_chan_write_optional_in;
    r_optional_t r_chan_read_optional_in;
    r_optional_t r_chan_write_optional_in;
    obi_be_t a_chan_read_be_in;
    obi_be_t a_chan_write_be_in;

    //////////////////////////////////
    //   DERIVED CONDITION SIGNALS  //
    //////////////////////////////////

    rx_meta_t rx_meta;

    logic can_enqueue_response, can_enqueue_tx;
    logic [InflightReqOutCntrDepth-1:0] tx_rsp_slots_needed;
    logic [TxFifoCntrDepth-1:0]         tx_fifo_free_slots;

    logic rx_has_transit, rx_has_incoming_a;
    logic rx_has_incoming_global, rx_has_global_loop;
    logic rx_pass_through_avbl;

    logic obi_in_self_req_avbl, obi_in_tx_req_avbl;
    logic obi_out_req_commit, obi_in_gnt_commit;

    assign rx_has_incoming_a      = rx_meta.rx_type == slink_pkg::RxIncomingA;
    assign rx_has_transit         = (rx_meta.rx_type == slink_pkg::RxTransit);
    assign rx_has_incoming_global = rx_meta.rx_type == slink_pkg::RxIncomingGlobal;
    assign rx_has_global_loop     = rx_meta.rx_type == slink_pkg::RxGlobalLoop;
    assign rx_pass_through_avbl   = rx_has_transit || rx_has_incoming_global;

    assign obi_in_addr_to_nid = get_node_id_from_addr(obi_in_req_i.a.addr);
    
    assign payload_in      = payload_t'(axis_in_req_i.t.data);
    assign tx_fifo_data_in = payload_out;

    assign axis_out_req_o.tvalid = tx_fifo_valid_out;
    assign axis_out_req_o.t.data = tx_fifo_data_out;
    assign tx_fifo_ready_out     = axis_out_rsp_i.tready;

    ////////////////////////////////////
    //   OBI CHANNEL PACKING (TX)     //
    ////////////////////////////////////

    assign r_chan_write_out.rid = out_req_inflight_fifo_data_out.obi_id;
    assign r_chan_write_out.err = obi_out_rsp_i.r.err;

    assign r_chan_read_out.rid   = out_req_inflight_fifo_data_out.obi_id;
    assign r_chan_read_out.err   = obi_out_rsp_i.r.err;
    assign r_chan_read_out.rdata = obi_out_rsp_i.r.rdata;

    assign a_chan_write_out.addr  = obi_in_req_i.a.addr[slink_obi_cfg.AddrWidth-NodeIdWidth-1 : 0];
    assign a_chan_write_out.aid   = rsp_reorder_tail_idx;
    assign a_chan_write_out.wdata = obi_in_req_i.a.wdata;

    assign a_chan_read_out.addr = obi_in_req_i.a.addr[slink_obi_cfg.AddrWidth-NodeIdWidth-1 : 0];
    assign a_chan_read_out.aid  = rsp_reorder_tail_idx;

    //////////////////////////////////////
    //   OBI CHANNEL UNPACKING (RX)     //
    //////////////////////////////////////

    assign r_chan_read_in  = r_chan_read_t'(payload_in.obi_ch);
    assign r_chan_write_in = r_chan_write_t'(payload_in.obi_ch);
    assign a_chan_read_in  = a_chan_read_t'(payload_in.obi_ch);
    assign a_chan_write_in = a_chan_write_t'(payload_in.obi_ch);

    //////////////////////////////////////
    //   OPTIONAL & BYTE-ENABLE WIRING  //
    //////////////////////////////////////

    if (slink_obi_cfg.UseOptional) begin : gen_optional
        assign r_chan_write_out.r_optional = obi_out_rsp_i.r.r_optional;
        assign r_chan_read_out.r_optional  = obi_out_rsp_i.r.r_optional;
        assign a_chan_write_out.a_optional = obi_in_req_i.a.a_optional;
        assign a_chan_read_out.a_optional  = obi_in_req_i.a.a_optional;

        assign a_chan_read_optional_in  = a_chan_read_in.a_optional;
        assign a_chan_write_optional_in = a_chan_write_in.a_optional;
        assign r_chan_read_optional_in  = r_chan_read_in.r_optional;
        assign r_chan_write_optional_in = r_chan_write_in.r_optional;
    end else begin : gen_no_optional
        assign a_chan_read_optional_in  = '0;
        assign a_chan_write_optional_in = '0;
        assign r_chan_read_optional_in  = '0;
        assign r_chan_write_optional_in = '0;
    end

    if (slink_obi_cfg.UseByteEnable) begin : gen_be
        assign a_chan_read_be_in  = a_chan_read_in.be;
        assign a_chan_write_be_in = a_chan_write_in.be;
        assign a_chan_write_out.be = obi_in_req_i.a.be;
        assign a_chan_read_out.be  = obi_in_req_i.a.be;
    end else begin : gen_no_be
        assign a_chan_read_be_in  = '1;
        assign a_chan_write_be_in = '1;
    end



    ///////////////////////////
    //   ISSUED REQS FIFO   //
    ///////////////////////////

    fifo_v3 #(
        .DEPTH  ( MaxInflightReqOut    ),
        .dtype  ( out_req_inflight_meta_t )
    ) i_out_req_inflight_fifo (
        .clk_i      ( clk_i                            ),
        .rst_ni     ( rst_ni                           ),
        .flush_i    ( 1'b0                             ),
        .testmode_i ( 1'b0                             ),
        .full_o     ( out_req_inflight_fifo_full       ),
        .empty_o    ( out_req_inflight_fifo_empty      ),
        .usage_o    ( out_req_inflight_fifo_fill_state ),
        .data_i     ( out_req_inflight_fifo_data_in    ),
        .push_i     ( out_req_inflight_fifo_push       ),
        .data_o     ( out_req_inflight_fifo_data_out   ),
        .pop_i      ( out_req_inflight_fifo_pop        )
    );

    /////////////////////////////
    //   REORDER BUFFER INST   //
    /////////////////////////////

    slink_rsp_reorder #(
        .MaxOutstanding ( MaxOutstandingReqIn ),
        .obi_r_chan_t   ( obi_r_chan_sbr_t    ),
        .obi_id_t       ( obi_sbr_id_t        )
    ) i_rsp_reorder (
        .clk_i       ( clk_i                  ),
        .rst_ni      ( rst_ni                 ),
        .full_o      ( rsp_reorder_full       ),
        .tail_idx_o  ( rsp_reorder_tail_idx   ),
        .head_idx_o  ( rsp_reorder_head_idx   ),
        .saved_aid_o ( rsp_reorder_saved_aid  ),
        .pending_o   (                        ),
        .alloc_i     ( rsp_reorder_alloc      ),
        .alloc_aid_i ( rsp_reorder_alloc_aid  ),
        .fill_valid_i( rsp_reorder_fill_valid ),
        .fill_idx_i  ( rsp_reorder_fill_idx   ),
        .fill_data_i ( rsp_reorder_fill_data  ),
        .fill_ready_o( rsp_reorder_fill_ready ),
        .head_valid_o( rsp_reorder_head_valid ),
        .head_data_o ( rsp_reorder_head_data  ),
        .head_ready_i( rsp_reorder_head_ready )
    );

    /////////////////////////////
    //        TX FIFO          //
    /////////////////////////////

    stream_fifo #(
        .DEPTH  ( TxFifoDepth ),
        .T      ( payload_t     )
    ) i_axis_out_reg (
        .clk_i      ( clk_i              ),
        .rst_ni     ( rst_ni             ),
        .flush_i    ( 1'b0               ),
        .testmode_i ( 1'b0               ),
        .usage_o    ( tx_fifo_fill_state ),
        .valid_i    ( tx_fifo_valid_in   ),
        .ready_o    ( tx_fifo_ready_in   ),
        .data_i     ( tx_fifo_data_in    ),
        .valid_o    ( tx_fifo_valid_out  ),
        .ready_i    ( tx_fifo_ready_out  ),
        .data_o     ( tx_fifo_data_out   )
    );



    always_comb begin : rx_classifier
        rx_meta = '0;
        rx_meta.rx_type = slink_pkg::RxNone;
        
        if (axis_in_req_i.tvalid) begin
            unique case (payload_in.hdr)
                slink_pkg::TagARead,
                slink_pkg::TagAWrite: begin
                    if      (payload_in.src_id == node_id_i) rx_meta.rx_type = slink_pkg::RxLoopA;
                    else if (payload_in.dst_id == node_id_i) rx_meta.rx_type = slink_pkg::RxIncomingA;
                    else                                     rx_meta.rx_type = slink_pkg::RxTransit;
                    rx_meta.is_write = (payload_in.hdr == slink_pkg::TagAWrite);
                end
                slink_pkg::TagRRead,
                slink_pkg::TagRWrite: begin
                    if      (payload_in.src_id == node_id_i) rx_meta.rx_type = slink_pkg::RxLoopR;
                    else if (payload_in.dst_id == node_id_i) rx_meta.rx_type = slink_pkg::RxIncomingR;
                    else                                     rx_meta.rx_type = slink_pkg::RxTransit;
                    rx_meta.is_write = (payload_in.hdr == slink_pkg::TagRWrite);
                end
                slink_pkg::TagWriteGlobal: begin
                    if      (payload_in.src_id == node_id_i) rx_meta.rx_type = slink_pkg::RxGlobalLoop;
                    else                                     rx_meta.rx_type = slink_pkg::RxIncomingGlobal;
                    rx_meta.is_write = (payload_in.hdr == slink_pkg::TagWriteGlobal);
                end
                default: rx_meta.rx_type = slink_pkg::RxError;
            endcase
        end
    end


    always_comb begin : obi_in_handler
        obi_in_rsp_o = '0;

        obi_in_self_req_avbl = 1'b0;
        obi_in_tx_req_avbl = 1'b0;

        rsp_reorder_head_ready = 1'b0;

        if (obi_in_req_i.req && !rsp_reorder_full) begin
            if (obi_in_addr_to_nid == node_id_i || (obi_in_addr_to_nid == global_addr_i && obi_in_req_i.a.we == 1'b0)) begin
                if (!self_req_pend_fill_q) begin
                    obi_in_self_req_avbl = 1'b1;
                end
            end else begin
                obi_in_tx_req_avbl = 1'b1;
            end
            if (obi_in_gnt_commit) obi_in_rsp_o.gnt = 1'b1;
        end

        if (rsp_reorder_head_valid) begin
            rsp_reorder_head_ready = 1'b1;
            obi_in_rsp_o.rvalid    = 1'b1;
            obi_in_rsp_o.r         = rsp_reorder_head_data;
        end
    end


    always_comb begin : obi_out_handler
        obi_out_req_o = '0;

        if (rx_has_incoming_a) begin
            if (rx_meta.is_write) begin
                obi_out_req_o.a.addr       = get_local_addr(a_chan_write_in.addr);
                // AID sizes might differ, but AID not really important here.
                obi_out_req_o.a.aid        = obi_mgr_id_t'(a_chan_write_in.aid);
                obi_out_req_o.a.wdata      = a_chan_write_in.wdata;
                obi_out_req_o.a.we         = 1'b1;
                obi_out_req_o.a.a_optional = a_chan_write_optional_in;
                obi_out_req_o.a.be         = a_chan_write_be_in;
            end else begin
                obi_out_req_o.a.addr       = get_local_addr(a_chan_read_in.addr);
                // AID sizes might differ, but AID not really important here.
                obi_out_req_o.a.aid        = obi_mgr_id_t'(a_chan_read_in.aid);
                obi_out_req_o.a.wdata      = '0;
                obi_out_req_o.a.we         = 1'b0;
                obi_out_req_o.a.a_optional = a_chan_read_optional_in;
                obi_out_req_o.a.be         = a_chan_read_be_in;
            end
            if (obi_out_req_commit) obi_out_req_o.req = 1'b1;
        end else if (rx_has_incoming_global) begin
            obi_out_req_o.a.addr       = get_local_addr(a_chan_write_in.addr);
            obi_out_req_o.a.aid        = obi_mgr_id_t'(a_chan_write_in.aid);
            obi_out_req_o.a.wdata      = a_chan_write_in.wdata;
            obi_out_req_o.a.we         = 1'b1;
            obi_out_req_o.a.a_optional = a_chan_write_optional_in;
            obi_out_req_o.a.be         = a_chan_write_be_in;
            if (obi_out_req_commit) obi_out_req_o.req = 1'b1;
        end
    end


    always_comb begin : capacity_handler
        can_enqueue_response = 1'b0;
        can_enqueue_tx       = 1'b0;

        tx_rsp_slots_needed = out_req_inflight_fifo_full 
                            ? MaxInflightReqOut 
                            : out_req_inflight_fifo_fill_state + rx_has_incoming_a;

        tx_fifo_free_slots  = TxFifoDepth - tx_fifo_fill_state;

        if (tx_fifo_ready_in) begin
            can_enqueue_tx       = tx_fifo_free_slots > tx_rsp_slots_needed;

            can_enqueue_response = !out_req_inflight_fifo_full && 
                                   tx_fifo_free_slots > out_req_inflight_fifo_fill_state;
        end
    end


    always_comb begin : rsp_reorder_arbiter
        self_req_pend_fill_accept = 1'b0;
        rsp_reorder_fill_valid    = 1'b0;
        rsp_reorder_fill_idx      = '0;
        rsp_reorder_fill_data     = '0;

        unique case (rx_meta.rx_type)
            slink_pkg::RxIncomingR: begin
                if (rx_meta.is_write) begin
                    rsp_reorder_fill_valid = 1'b1;
                    rsp_reorder_fill_idx   = r_chan_write_in.rid;
                    rsp_reorder_fill_data  = obi_r_chan_pack(
                        '0, 
                        rsp_reorder_saved_aid[r_chan_write_in.rid], 
                        r_chan_write_in.err, 
                        r_chan_write_optional_in
                    );
                end else begin
                    rsp_reorder_fill_valid = 1'b1;
                    rsp_reorder_fill_idx   = r_chan_read_in.rid;
                    rsp_reorder_fill_data  = obi_r_chan_pack(
                        r_chan_read_in.rdata, 
                        rsp_reorder_saved_aid[r_chan_read_in.rid], 
                        r_chan_read_in.err, 
                        r_chan_read_optional_in
                    );
                end
            end
            slink_pkg::RxLoopA: begin
                if (rx_meta.is_write) begin
                    rsp_reorder_fill_valid = 1'b1;
                    rsp_reorder_fill_idx   = a_chan_write_in.aid;
                    rsp_reorder_fill_data  = obi_r_chan_pack(
                        '0, rsp_reorder_saved_aid[a_chan_write_in.aid], 
                        1'b1, '0
                    );
                end else begin
                    rsp_reorder_fill_valid = 1'b1;
                    rsp_reorder_fill_idx   = a_chan_read_in.aid;
                    rsp_reorder_fill_data  = obi_r_chan_pack(
                        '0, rsp_reorder_saved_aid[a_chan_read_in.aid], 
                        1'b1, '0
                    );
                end
            end
            // TODO: Verify if makes sense to have this as last priority
            default: begin
                if (self_req_pend_fill_q) begin
                    self_req_pend_fill_accept = 1'b1;
                    rsp_reorder_fill_valid    = 1'b1;
                    rsp_reorder_fill_idx      = self_req_pend_fill_idx_q;
                    rsp_reorder_fill_data     = obi_r_chan_pack(
                        '0, rsp_reorder_saved_aid[self_req_pend_fill_idx_q],
                        self_req_pend_err_q, '0
                    );
                end
            end
        endcase
    end


    always_comb begin : tx_fifo_in_arbiter
        tx_meta = '0;
        tx_meta.tx_type = slink_pkg::TxNone;

        if (obi_out_rsp_i.rvalid && !out_req_inflight_fifo_empty &&
                !out_req_inflight_fifo_data_out.is_global) begin
            // Prio 1: outgoing R response must always win (since no handshake).
            // A global write's response is dropped (drained in the commiter), so it
            // never produces a TxOutgoingR and frees the TX slot for other traffic.
            tx_meta.tx_type   = slink_pkg::TxOutgoingR;
            tx_meta.is_write = out_req_inflight_fifo_data_out.is_write;
            tx_meta.dst_id   = out_req_inflight_fifo_data_out.src_id;

        end else if (can_enqueue_tx) begin
            // Prio 2: round-robin between Host A request and ring pass-through
            // (transit or incoming-global forward).
            unique case ({obi_in_tx_req_avbl, rx_pass_through_avbl})
                2'b01: begin
                    tx_meta.tx_type = rx_has_transit ? slink_pkg::TxTransit : slink_pkg::TxForwardGlobal;
                end
                2'b10: begin
                    tx_meta.tx_type  = obi_in_addr_to_nid == global_addr_i ? slink_pkg::TxOutgoingGlobal : slink_pkg::TxOutgoingA;
                    tx_meta.is_write = obi_in_req_i.a.we;
                    tx_meta.dst_id   = obi_in_addr_to_nid;
                    tx_meta.aid      = obi_in_req_i.a.aid;
                end
                2'b11: begin
                    if (rr_tx_out_arb_q) begin
                        tx_meta.tx_type  = rx_has_transit ? slink_pkg::TxTransit : slink_pkg::TxForwardGlobal;
                    end else begin
                        tx_meta.tx_type  = obi_in_addr_to_nid == global_addr_i ? slink_pkg::TxOutgoingGlobal : slink_pkg::TxOutgoingA;
                        tx_meta.is_write = obi_in_req_i.a.we;
                        tx_meta.dst_id   = obi_in_addr_to_nid;
                        tx_meta.aid      = obi_in_req_i.a.aid;
                    end
                end
                default: ;
            endcase
        end
    end


    always_comb begin : tx_payload_builder
        payload_out = '0;

        unique case (tx_meta.tx_type)
            slink_pkg::TxOutgoingR: begin
                payload_out = make_r_payload(
                    tx_meta.is_write, node_id_i, tx_meta.dst_id, 
                    r_chan_write_out, r_chan_read_out
                );
            end
            slink_pkg::TxOutgoingA: begin
                payload_out = make_a_payload(
                    tx_meta.is_write, node_id_i, tx_meta.dst_id, 
                    a_chan_write_out, a_chan_read_out
                );
            end
            slink_pkg::TxOutgoingGlobal: begin
                payload_out = make_global_payload(node_id_i, a_chan_write_out);
            end
            slink_pkg::TxForwardGlobal,
            slink_pkg::TxTransit: begin
                // Forward the received payload onward unchanged.
                payload_out = payload_in;
            end
            default: ;
        endcase
    end


    always_comb begin : out_req_inflight_fifo_arbiter
        out_req_inflight_fifo_data_in = '0;

        unique case (payload_in.hdr)
            slink_pkg::TagAWrite: begin
                out_req_inflight_fifo_data_in = '{
                    src_id:    payload_in.src_id,
                    is_write:  1'b1,
                    is_global: 1'b0,
                    obi_id:    a_chan_write_in.aid
                };
            end
            slink_pkg::TagARead: begin
                out_req_inflight_fifo_data_in = '{
                    src_id:    payload_in.src_id,
                    is_write:  1'b0,
                    is_global: 1'b0,
                    obi_id:    a_chan_read_in.aid
                };
            end
            slink_pkg::TagWriteGlobal: begin
                // Tracked only to keep the OBI response channel ordered; the
                // response itself is dropped (see commiter), so src_id is unused.
                out_req_inflight_fifo_data_in = '{
                    src_id:    payload_in.src_id,
                    is_write:  1'b1,
                    is_global: 1'b1,
                    obi_id:    a_chan_write_in.aid
                };
            end
            default: begin
                out_req_inflight_fifo_data_in = '0;
            end
        endcase
    end


    always_comb begin : commiter

        error_looped_rsp_o   = 1'b0;

        axis_in_rsp_o.tready = 1'b0;

        tx_fifo_valid_in           = 1'b0;
        out_req_inflight_fifo_pop  = 1'b0;
        out_req_inflight_fifo_push = 1'b0;

        obi_out_req_commit = 1'b0;
        obi_in_gnt_commit  = 1'b0;

        rsp_reorder_alloc     = 1'b0;
        rsp_reorder_alloc_aid = '0;

        self_req_pend_fill_d     = self_req_pend_fill_q;
        self_req_pend_fill_idx_d = self_req_pend_fill_idx_q;
        self_req_pend_err_d      = self_req_pend_err_q;

        rr_tx_out_arb_d = rr_tx_out_arb_q;


        unique case (rx_meta.rx_type)
            slink_pkg::RxIncomingA: begin
                if (can_enqueue_response) begin
                    obi_out_req_commit = 1'b1;
                    if (obi_out_rsp_i.gnt) begin
                        axis_in_rsp_o.tready       = 1'b1;
                        out_req_inflight_fifo_push = 1'b1;
                    end
                end
            end
            slink_pkg::RxIncomingR,
            slink_pkg::RxLoopA: begin
                if (rsp_reorder_fill_ready) begin
                    axis_in_rsp_o.tready = 1'b1;
                end
            end
            slink_pkg::RxLoopR: begin
                // R channel loop means answer to remote request could not be delivered. 
                // We can do nothing else than drop it. 
                // TODO: could send error or something.
                error_looped_rsp_o   = 1'b1; // Set error flag in register
                axis_in_rsp_o.tready = 1'b1; // Consume and discard
            end
            slink_pkg::RxGlobalLoop: begin
                // A global write made it all the way around back to its originator.
                // The originator already responded to its host when injecting the
                // broadcast, so just consume and discard to stop it from looping.
                axis_in_rsp_o.tready = 1'b1;
            end
            slink_pkg::RxError: begin
                // Consume and discard (not a payload, should never happen)
                axis_in_rsp_o.tready = 1'b1;
            end
            default: ;
        endcase


        if (obi_in_self_req_avbl) begin
            obi_in_gnt_commit        = 1'b1;
            rsp_reorder_alloc        = 1'b1;
            rsp_reorder_alloc_aid    = obi_in_req_i.a.aid;
            self_req_pend_fill_d     = 1'b1;
            self_req_pend_fill_idx_d = rsp_reorder_tail_idx;
            self_req_pend_err_d      = 1'b1; // Self/global-read can't be served -> error rsp

        end else if (self_req_pend_fill_accept && rsp_reorder_fill_ready) begin
            self_req_pend_fill_d     = 1'b0;
            self_req_pend_fill_idx_d = '0;
        end


        if (tx_fifo_ready_in) begin
            unique case (tx_meta.tx_type)
                slink_pkg::TxOutgoingR: begin
                    tx_fifo_valid_in          = 1'b1;
                    out_req_inflight_fifo_pop = 1'b1;
                end
                slink_pkg::TxOutgoingA: begin
                    tx_fifo_valid_in      = 1'b1;
                    obi_in_gnt_commit     = 1'b1;
                    rsp_reorder_alloc     = 1'b1;
                    rsp_reorder_alloc_aid = tx_meta.aid;
                    rr_tx_out_arb_d       = ~rr_tx_out_arb_q; // Update RR on commit
                end
                slink_pkg::TxOutgoingGlobal: begin
    
                    if (!self_req_pend_fill_q) begin
                        tx_fifo_valid_in      = 1'b1;
                        obi_in_gnt_commit     = 1'b1;
                        rsp_reorder_alloc        = 1'b1;
                        rsp_reorder_alloc_aid    = tx_meta.aid;
                        self_req_pend_fill_d     = 1'b1;
                        self_req_pend_fill_idx_d = rsp_reorder_tail_idx;
                        self_req_pend_err_d      = 1'b0;
                        rr_tx_out_arb_d          = ~rr_tx_out_arb_q; // Update RR on commit
                    end
                end
                slink_pkg::TxForwardGlobal: begin
                    if (!out_req_inflight_fifo_full) begin
                        obi_out_req_commit = 1'b1;
                        if (obi_out_rsp_i.gnt) begin
                            tx_fifo_valid_in           = 1'b1;
                            axis_in_rsp_o.tready       = 1'b1;
                            out_req_inflight_fifo_push = 1'b1;
                            rr_tx_out_arb_d            = ~rr_tx_out_arb_q; // Update RR on commit
                        end
                    end
                end
                slink_pkg::TxTransit: begin
                    tx_fifo_valid_in     = 1'b1;
                    axis_in_rsp_o.tready = 1'b1;
                    rr_tx_out_arb_d      = ~rr_tx_out_arb_q; // Update RR on commit
                end
                default: ;
            endcase
        end


        if (obi_out_rsp_i.rvalid && !out_req_inflight_fifo_empty &&
                out_req_inflight_fifo_data_out.is_global) begin
            out_req_inflight_fifo_pop = 1'b1;
        end
    end

    ////////////////////
    //   ASSERTIONS   //
    ////////////////////
    
    `ASSERT(AxisStable, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> $stable(axis_out_req_o.t))
    `ASSERT(AxisHandshake, axis_out_req_o.tvalid & !axis_out_rsp_i.tready |=> axis_out_req_o.tvalid)

    `ASSERT(TxOutRFIFOTracked, obi_out_rsp_i.rvalid |-> !out_req_inflight_fifo_empty)
    `ASSERT(TxOutRFIFOFull, (obi_out_rsp_i.rvalid && !out_req_inflight_fifo_data_out.is_global)
                            |-> !out_req_inflight_fifo_empty && tx_fifo_ready_in)
    `ASSERT(GntCommitMutex, !(obi_in_self_req_avbl && (tx_meta.tx_type == slink_pkg::TxOutgoingA ||
                                                       tx_meta.tx_type == slink_pkg::TxOutgoingGlobal)))

    `ASSERT_INIT(TxFifoDeeperThanInflight, TxFifoDepth > MaxInflightReqOut)
    `ASSERT_INIT(AddrWidthGreaterThanNodeId, slink_obi_cfg.AddrWidth > NodeIdWidth)
    `ASSERT_INIT(IdWidthGeqThanIdxWidth, slink_obi_cfg.IDWidth >= IdxWidth)
endmodule
