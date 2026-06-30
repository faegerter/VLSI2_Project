// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Tim Fischer <fischeti@iis.ee.ethz.ch>
// Author: Llorenç Muela Hausmann <lmuela@ethz.ch>
// Author: Fabian Aegerter <faegerter@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// Implements the Data Link layer of the Serial Link
// Handles the RAW mode
module slink_link_layer #(
  parameter type axis_req_t = logic,
  parameter type axis_rsp_t = logic,
  parameter type phy_data_t = logic,
  parameter int NumChannels = 1,
  parameter int NumLanes    = 8,
  parameter int RawModeFifoDepth = 8,
  parameter int PayloadSplits = -1,
  parameter bit EnDdr = 1'b1,
  parameter bit EnBypass = 1'b1,
  localparam int Log2NumChannels = (NumChannels > 1)? $clog2(NumChannels) : 1,
  localparam int unsigned Log2RawModeFifoDepth = $clog2(RawModeFifoDepth),
  parameter type credit_t  = logic,
  // For credit-based control flow
  parameter int NumCredits  = -1,
  parameter int CdcSyncStages = 2,
  parameter int AChannelWritePayloadSize = -1,
  parameter int AChannelReadPayloadSize = -1,
  parameter int RChannelWritePayloadSize = -1,
  parameter int RChannelReadPayloadSize = -1,
  parameter int BandWidth = -1
) (
  input  logic                            clk_i,
  input  logic                            rst_ni,
  // AXI Stream interface signals
  input  axis_req_t                       axis_in_req_i,
  output axis_rsp_t                       axis_in_rsp_o,
  output axis_req_t                       axis_out_req_o,
  input  axis_rsp_t                       axis_out_rsp_i,
  // Phy Channel interface signals
  output phy_data_t [NumChannels-1:0]     data_out_o,
  output logic      [NumChannels-1:0]     data_out_valid_o,
  input  logic                            data_out_ready_i,
  input  phy_data_t [NumChannels-1:0]     data_in_i,
  input  logic      [NumChannels-1:0]     data_in_valid_i,
  output logic      [NumChannels-1:0]     data_in_ready_o,
  // Debug/Calibration signals
  input  logic                            cfg_flow_control_fifo_clear_i,
  input  logic                            cfg_raw_mode_en_i,
  input  logic [Log2NumChannels-1:0]      cfg_raw_mode_in_ch_sel_i,
  output phy_data_t                       cfg_raw_mode_in_data_o,
  output logic [NumChannels-1:0]          cfg_raw_mode_in_data_valid_o,
  input  logic                            cfg_raw_mode_in_data_ready_i,
  input  logic [NumChannels-1:0]          cfg_raw_mode_out_ch_mask_i,
  input  phy_data_t                       cfg_raw_mode_out_data_i,
  input  logic                            cfg_raw_mode_out_data_valid_i,
  input  logic                            cfg_raw_mode_out_en_i,
  input  logic                            cfg_raw_mode_out_data_fifo_clear_i,
  output logic [Log2RawModeFifoDepth-1:0] cfg_raw_mode_out_data_fifo_fill_state_o,
  output logic                            cfg_raw_mode_out_data_fifo_is_full_o,
  // Credits
  input  logic                            credit_recv_clk_i,
  output logic                            credit_rtrn_clk_o,
  output credit_t                         credits_out_o,
  // Bypass
  input  logic[slink_reg_pkg::Log2MaxNodeIds-1:0]        node_id_i,
  input  logic                            stop_send_i
  );

    localparam int AChannelWritePayloadSplits = (AChannelWritePayloadSize + BandWidth - 1)/BandWidth;
    localparam int AChannelReadPayloadSplits  = (AChannelReadPayloadSize + BandWidth - 1)/BandWidth;
    localparam int RChannelWritePayloadSplits = (RChannelWritePayloadSize + BandWidth - 1)/BandWidth;
    localparam int RChannelReadPayloadSplits  = (RChannelReadPayloadSize + BandWidth - 1)/BandWidth;

    typedef enum logic [1:0] {LinkSendIdle, LinkSendBusy} link_state_e;
    typedef phy_data_t [NumChannels-1:0] phy_data_chan_t;



    ///////////////////////////////
    //   RAW MODE SIGNALS        //
    ///////////////////////////////

    logic raw_mode_fifo_full, raw_mode_fifo_empty;
    logic raw_mode_fifo_push, raw_mode_fifo_pop;
    phy_data_t raw_mode_fifo_data_in, raw_mode_fifo_data_out;
    logic [NumChannels-1:0] raw_mode_data_in_ready;
    logic [NumChannels-1:0] raw_mode_data_out_valid;
    phy_data_t [NumChannels-1:0] raw_mode_data_out;


    assign cfg_raw_mode_out_data_fifo_is_full_o = raw_mode_fifo_full;
    assign raw_mode_fifo_push = cfg_raw_mode_out_data_valid_i & ~raw_mode_fifo_full;
    assign raw_mode_fifo_data_in = cfg_raw_mode_out_data_i;



    ///////////////////////////////
    //   DATA IN SIGNALS         //
    ///////////////////////////////

    logic [PayloadSplits-1:0] recv_reg_in_valid, recv_reg_in_ready;
    logic [PayloadSplits-1:0] recv_reg_out_valid, recv_reg_out_ready;
    phy_data_t [PayloadSplits-1:0][NumChannels-1:0] recv_reg_data, recv_reg_in_data;
    logic [$clog2(PayloadSplits)-1:0] recv_reg_index_q, recv_reg_index_d;
    logic [$clog2(PayloadSplits)-1:0] recv_reg_payload_size_q, recv_reg_payload_size_d;
    logic [NumChannels-1:0] rx_data_in_ready;
    logic [$bits(phy_data_t)*NumChannels-1:0] data_in_flat;
    
    
    assign data_in_flat = data_in_i; 


    `FF(recv_reg_payload_size_q, recv_reg_payload_size_d, '0)
    `FF(recv_reg_index_q, recv_reg_index_d, '0)



    ///////////////////////////////
    //   BYPASS SIGNALS          //
    ///////////////////////////////

    logic en_rx_tx_bypass;
    phy_data_t [NumChannels-1:0] bypass_data_out;
    logic [NumChannels-1:0] bypass_data_out_valid; 
    logic [NumChannels-1:0] bypass_data_in_ready;
    logic [$clog2(PayloadSplits)-1:0] bypass_payload_split_index_q, bypass_payload_split_index_d;
    logic [$clog2(PayloadSplits*NumChannels*NumLanes*(1+EnDdr)):0]  bypass_payload_size_q, bypass_payload_size_d;
    logic rx_tx_bypass_active_q, rx_tx_bypass_active_d;

    logic no_active_bypass, all_channels_valid, data_out_idle, data_in_idle, different_node_id;
    logic [slink_reg_pkg::Log2MaxNodeIds-1:0] incoming_node_id;

    assign incoming_node_id   = data_in_flat[$bits(slink_pkg::tag_e)+slink_reg_pkg::Log2MaxNodeIds-1 : $bits(slink_pkg::tag_e)];

    assign no_active_bypass   = ~rx_tx_bypass_active_q;
    assign all_channels_valid = &data_in_valid_i;
    assign data_in_idle       = (recv_reg_index_q == '0);
    assign data_out_idle      = ~axis_in_req_i.tvalid;
    assign different_node_id  = (incoming_node_id != node_id_i) && (slink_pkg::tag_e'(data_in_flat[$bits(slink_pkg::tag_e)-1:0]) != slink_pkg::TagWriteGlobal);


    generate
        if (EnBypass) begin : gen_en_rx_tx_bypass
            assign en_rx_tx_bypass = no_active_bypass
                                   & all_channels_valid
                                   & data_in_idle
                                   & data_out_idle
                                   & different_node_id
                                   & ~stop_send_i;
        end else begin : gen_no_en_rx_tx_bypass
            assign en_rx_tx_bypass = 1'b0;
        end
    endgenerate


    `FF(rx_tx_bypass_active_q, rx_tx_bypass_active_d, 0)
    `FF(bypass_payload_split_index_q, bypass_payload_split_index_d, '0)
    `FF(bypass_payload_size_q, bypass_payload_size_d, '0)



    ///////////////////////////////
    //   DATA OUT SIGNALS        //
    ///////////////////////////////

    link_state_e link_state_q, link_state_d;
    logic [$clog2(PayloadSplits*NumChannels*NumLanes*(1+EnDdr)):0] link_out_index_q, link_out_index_d;
    logic [$clog2(PayloadSplits*NumChannels*NumLanes*(1+EnDdr)):0]  link_out_payload_size_q, link_out_payload_size_d;
    logic      [NumChannels-1:0]     tx_data_out_valid; 
    phy_data_t [NumChannels-1:0]     tx_data_out;


    `FF(link_out_index_q, link_out_index_d, '0)
    `FF(link_state_q, link_state_d, LinkSendIdle)
    `FF(link_out_payload_size_q, link_out_payload_size_d, '0)



    ///////////////////////////////
    //   CREDITS SIGNALS         //
    ///////////////////////////////

    credit_t credits_out_q, credits_out_d;
    credit_t credits_to_send_q, credits_to_send_d;
    logic credit_clk_out_en;
    logic credit_in_ready, credit_in;
    logic credits_available;

    assign credits_out_o     = credits_out_q;
    assign credits_available = (credits_out_q != '0);


    `FF(credits_to_send_q, credits_to_send_d, '0)
    `FF(credits_out_q, credits_out_d, NumCredits)



    ///////////////////////////////
    //   STREAM REGISTERS (RX)   //
    ///////////////////////////////

    for (genvar i = 0; i < PayloadSplits; i++) begin : gen_recv_reg
      stream_register #(
        .T (phy_data_chan_t)
      ) i_recv_reg (
        .clk_i      ( clk_i                       ),
        .rst_ni     ( rst_ni                      ),
        .clr_i      ( 1'b0                        ),
        .testmode_i ( 1'b0                        ),
        .valid_i    ( recv_reg_in_valid[i]        ),
        .ready_o    ( recv_reg_in_ready[i]        ),
        .data_i     ( recv_reg_in_data[i]         ),
        .valid_o    ( recv_reg_out_valid[i]       ),
        .ready_i    ( recv_reg_out_ready[i]       ),
        .data_o     ( recv_reg_data[i]            )
      );
    end



    ///////////////////////////////
    //   RAW MODE FIFO           //
    ///////////////////////////////

    fifo_v3 #(
      .dtype  ( phy_data_t        ),
      .DEPTH  ( RawModeFifoDepth  )
    ) i_raw_mode_fifo (
      .clk_i      ( clk_i                                   ),
      .rst_ni     ( rst_ni                                  ),
      .flush_i    ( cfg_raw_mode_out_data_fifo_clear_i      ),
      .testmode_i ( 1'b0                                    ),
      .full_o     ( raw_mode_fifo_full                      ),
      .empty_o    ( raw_mode_fifo_empty                     ),
      .usage_o    ( cfg_raw_mode_out_data_fifo_fill_state_o ),
      .data_i     ( raw_mode_fifo_data_in                   ),
      .push_i     ( raw_mode_fifo_push                      ),
      .data_o     ( raw_mode_fifo_data_out                  ),
      .pop_i      ( raw_mode_fifo_pop                       )
    );



    ////////////////////////////////////
    //   RECEIVING CREDITS CDC FIFO   //
    ////////////////////////////////////

    cdc_fifo_gray #(
      .WIDTH( 1 ),
      .LOG_DEPTH    ( $clog2(NumCredits) + CdcSyncStages ),
      .SYNC_STAGES  ( CdcSyncStages                      ) 
    ) i_credit_recv_cdc_fifo_gray(
      .src_clk_i   ( credit_recv_clk_i    ),
      .src_rst_ni  ( rst_ni               ),
      .src_data_i  ( 1'b1                 ),
      .src_valid_i ( 1'b1                 ),
      .src_ready_o (                      ),

      .dst_clk_i   ( clk_i                ),
      .dst_rst_ni  ( rst_ni               ),
      .dst_data_o  (                      ),
      .dst_valid_o ( credit_in            ),
      .dst_ready_i ( credit_in_ready      )
  );


    ////////////////////////////////////
    //   PHYSICAL & LINK LAYER TEST   //
    ////////////////////////////////////

    always_comb begin : raw_mode
        raw_mode_data_in_ready = '0;
        raw_mode_data_out_valid = '0;
        raw_mode_data_out = '0;
        raw_mode_fifo_pop = 1'b0;
        cfg_raw_mode_in_data_o = '0;
        cfg_raw_mode_in_data_valid_o = '0;

        if (cfg_raw_mode_en_i) begin
            cfg_raw_mode_in_data_valid_o = data_in_valid_i;
            if (cfg_raw_mode_in_data_ready_i) begin
                if (data_in_valid_i[cfg_raw_mode_in_ch_sel_i]) begin
                    raw_mode_data_in_ready[cfg_raw_mode_in_ch_sel_i] = 1'b1;
                    cfg_raw_mode_in_data_o = data_in_i[cfg_raw_mode_in_ch_sel_i];
                end else begin
                    // TODO: send out Error response
                end
            end

            if (cfg_raw_mode_out_en_i & ~raw_mode_fifo_empty) begin
                raw_mode_data_out_valid = cfg_raw_mode_out_ch_mask_i;
                raw_mode_data_out = {{NumChannels}{raw_mode_fifo_data_out}};
                if (data_out_ready_i && credits_available) begin
                    raw_mode_fifo_pop = 1'b1;
                end
            end
        end 
    end



    ///////////////////////////////
    //   DATA IN & DATA OUT      //
    ///////////////////////////////

    always_comb begin : rx_data_to_protocol
        rx_data_in_ready = '0;
        recv_reg_in_valid = '0;
        recv_reg_in_data = '0;
        recv_reg_index_d = recv_reg_index_q;
        recv_reg_payload_size_d = recv_reg_payload_size_q;
        axis_out_req_o.tvalid = 1'b0;
        axis_out_req_o.t.data = recv_reg_data;
        recv_reg_out_ready = '0;

        if(!(cfg_raw_mode_en_i || en_rx_tx_bypass || rx_tx_bypass_active_q)) begin
            if (&data_in_valid_i && recv_reg_in_ready[recv_reg_index_q]) begin
                if(recv_reg_index_q == 0)begin 
                    unique case(slink_pkg::tag_e'(data_in_flat[$bits(slink_pkg::tag_e)-1:0]))
                        slink_pkg::TagAWrite: begin 
                            recv_reg_payload_size_d = AChannelWritePayloadSplits;
                            for (int i = AChannelWritePayloadSplits; i < PayloadSplits; i++) begin
                                recv_reg_in_data[i] = '0;
                                recv_reg_in_valid[i] = 1'b1;
                            end
                        end
                        slink_pkg::TagWriteGlobal: begin 
                            recv_reg_payload_size_d = AChannelWritePayloadSplits;
                            for (int i = AChannelWritePayloadSplits; i < PayloadSplits; i++) begin
                                recv_reg_in_data[i] = '0;
                                recv_reg_in_valid[i] = 1'b1;
                            end
                        end
                        slink_pkg::TagARead: begin 
                            recv_reg_payload_size_d = AChannelReadPayloadSplits; 
                            for (int i = AChannelReadPayloadSplits; i < PayloadSplits; i++) begin
                                recv_reg_in_data[i] = '0;
                                recv_reg_in_valid[i] = 1'b1;
                            end
                        end
                        slink_pkg::TagRWrite: begin
                            recv_reg_payload_size_d = RChannelWritePayloadSplits;
                            for (int i = RChannelWritePayloadSplits; i < PayloadSplits; i++) begin
                                recv_reg_in_data[i] = '0;
                                recv_reg_in_valid[i] = 1'b1;
                            end
                        end
                        slink_pkg::TagRRead: begin
                            recv_reg_payload_size_d = RChannelReadPayloadSplits;
                            for (int i = RChannelReadPayloadSplits; i < PayloadSplits; i++) begin
                                recv_reg_in_data[i] = '0;
                                recv_reg_in_valid[i] = 1'b1;
                            end
                        end 
                        default: begin
                            recv_reg_payload_size_d = 1;
                            if(PayloadSplits > 1) begin
                                recv_reg_in_data[PayloadSplits-1:1] = '0;
                                recv_reg_in_valid[PayloadSplits-1:1] = '1;
                            end
                        end
                    endcase
                end
                recv_reg_in_data[recv_reg_index_q] = data_in_i;
                recv_reg_in_valid[recv_reg_index_q] = 1'b1;
                rx_data_in_ready = {NumChannels{&data_in_valid_i}};
                recv_reg_index_d = (recv_reg_index_q == recv_reg_payload_size_d - 1) ? 0 : recv_reg_index_q + 1;
            end

            axis_out_req_o.tvalid = &recv_reg_out_valid & ~stop_send_i;
            recv_reg_out_ready = {PayloadSplits{axis_out_rsp_i.tready}};
        end
    end


    generate
        if (EnBypass) begin : gen_rx_tx_bypass
            always_comb begin : protocol_bypass 
                bypass_data_out = '0;
                bypass_data_out_valid = '0;
                bypass_payload_split_index_d = bypass_payload_split_index_q;
                bypass_payload_size_d = bypass_payload_size_q;
                bypass_data_in_ready = '0;
                rx_tx_bypass_active_d = rx_tx_bypass_active_q;

                if(!cfg_raw_mode_en_i) begin  
                    if((en_rx_tx_bypass || rx_tx_bypass_active_d) && (&data_in_valid_i))begin
                        rx_tx_bypass_active_d = 1'b1;
                        bypass_data_out_valid = '1;
                        bypass_data_out = data_in_i;
                        if(data_out_ready_i && credits_available)begin 
                            if(bypass_payload_split_index_q == 0)begin 
                                unique case(slink_pkg::tag_e'(data_in_flat[$bits(slink_pkg::tag_e)-1:0]))
                                    slink_pkg::TagAWrite: bypass_payload_size_d = AChannelWritePayloadSplits;
                                    slink_pkg::TagARead:  bypass_payload_size_d = AChannelReadPayloadSplits; 
                                    slink_pkg::TagRWrite: bypass_payload_size_d = RChannelWritePayloadSplits;
                                    slink_pkg::TagRRead:  bypass_payload_size_d = RChannelReadPayloadSplits;
                                    default:              bypass_payload_size_d = 1;
                                endcase
                            end

                            bypass_data_in_ready = {NumChannels{&data_in_valid_i}};

                            if (bypass_payload_split_index_q == bypass_payload_size_d - 1) begin 
                                bypass_payload_split_index_d = 0;
                                rx_tx_bypass_active_d = 1'b0;
                            end else begin 
                                bypass_payload_split_index_d = bypass_payload_split_index_q + 1;
                            end
                        end
                    end
                end
            end
        end else begin : gen_no_rx_tx_bypass
            always_comb begin : protocol_bypass
                bypass_data_out              = '0;
                bypass_data_out_valid        = '0;
                bypass_payload_split_index_d = '0;
                bypass_payload_size_d        = '0;
                bypass_data_in_ready         = '0;
                rx_tx_bypass_active_d        = 1'b0;
            end
        end
    endgenerate



    always_comb begin : protocol_to_tx_data
        tx_data_out = '0;
        tx_data_out_valid = '0;
        axis_in_rsp_o.tready = 1'b0;
        link_out_index_d = link_out_index_q;
        link_state_d = link_state_q;
        link_out_payload_size_d = link_out_payload_size_q;

        if(!(cfg_raw_mode_en_i || en_rx_tx_bypass || rx_tx_bypass_active_q)) begin
            unique case (link_state_q)
                LinkSendIdle: begin
                    if (axis_in_req_i.tvalid) begin
                        unique case(slink_pkg::tag_e'(axis_in_req_i.t.data[1:0]))
                            slink_pkg::TagAWrite:      link_out_payload_size_d = AChannelWritePayloadSplits * BandWidth;
                            slink_pkg::TagWriteGlobal: link_out_payload_size_d = AChannelWritePayloadSplits * BandWidth;
                            slink_pkg::TagARead:       link_out_payload_size_d = AChannelReadPayloadSplits  * BandWidth; 
                            slink_pkg::TagRWrite:      link_out_payload_size_d = RChannelWritePayloadSplits * BandWidth;
                            slink_pkg::TagRRead:       link_out_payload_size_d = RChannelReadPayloadSplits  * BandWidth; 
                            default:    link_out_payload_size_d = 1;
                        endcase
                        link_out_index_d = NumChannels * NumLanes * (1 + EnDdr);
                        tx_data_out_valid = '1;
                        tx_data_out = axis_in_req_i.t.data;
                        if (data_out_ready_i && credits_available) begin
                            link_state_d = LinkSendBusy;
                            if (link_out_index_d >= link_out_payload_size_d) begin
                                link_state_d = LinkSendIdle;
                                axis_in_rsp_o.tready = 1'b1;
                            end
                        end
                    end
                end

                LinkSendBusy: begin 
                    tx_data_out_valid = '1;
                    tx_data_out = axis_in_req_i.t.data >> link_out_index_q;
                    if (data_out_ready_i && credits_available) begin
                        link_out_index_d = link_out_index_q + NumChannels * NumLanes * (1 + EnDdr);
                        if (link_out_index_d >= link_out_payload_size_q) begin
                            link_state_d = LinkSendIdle;
                            axis_in_rsp_o.tready = 1'b1;
                        end
                    end
                end
                default:;
            endcase
        end
    end


    always_comb begin : rx_bypass_raw_mode_mux 
        data_in_ready_o = '0;
        if (cfg_raw_mode_en_i) begin 
            data_in_ready_o = raw_mode_data_in_ready;
        end 
        else if (en_rx_tx_bypass || rx_tx_bypass_active_q) begin 
            data_in_ready_o = bypass_data_in_ready;
        end 
        else begin 
            data_in_ready_o = rx_data_in_ready;
        end
    end



    always_comb begin : tx_bypass_raw_mode_mux
        data_out_valid_o = '0;
        data_out_o = '0;
        if (~stop_send_i) begin
            if (cfg_raw_mode_en_i) begin
                data_out_o = raw_mode_data_out;
                data_out_valid_o = (credits_out_q != '0) ? raw_mode_data_out_valid : '0; 
            end 
            else if(en_rx_tx_bypass || rx_tx_bypass_active_q) begin
                data_out_o = bypass_data_out;
                data_out_valid_o = (credits_out_q != '0) ? bypass_data_out_valid : '0;
            end 
            else begin
                data_out_o = tx_data_out;
                data_out_valid_o = (credits_out_q != '0) ? tx_data_out_valid : '0; 
            end
        end
    end



    //////////////////////
    //   FLOW CONTROL   //
    //////////////////////

    tc_clk_gating #(
      .IS_FUNCTIONAL(1) // The gate is required to prevent glitches during
                        // transitioning. Target specific implementations must not
                        // remove it to save ICGs (e.g. in FPGAs).
    ) i_clk_gate (
      .clk_i     ( clk_i             ),
      .en_i      ( credit_clk_out_en ),
      .test_en_i ( 1'b0              ),
      .clk_o     ( credit_rtrn_clk_o )
    );



    always_comb begin : send_credits
        credits_to_send_d = credits_to_send_q;
        credit_clk_out_en = 1'b0;
        if (&data_in_ready_o) begin 
            credits_to_send_d++;
        end
        if(credits_to_send_d != '0) begin 
            credit_clk_out_en = 1'b1;
            credits_to_send_d--;
        end
    end



    always_comb begin : recv_credits
        credits_out_d = credits_out_q;
        credit_in_ready = 1'b0;
        if (data_out_ready_i && (|data_out_valid_o)) begin
            credits_out_d--;
        end
        if (credit_in) begin
            credits_out_d++;
            credit_in_ready = 1'b1;
        end
    end

    
    
    ////////////////////
    //   ASSERTIONS   //
    ////////////////////

    `ASSERT_INIT(ThroughputPerCycleTooSmallForDynamicPayloads, $bits(slink_pkg::tag_e) <= NumChannels*NumLanes*(1 + EnDdr))
    `ASSERT_INIT(ThroughputPerCycleTooSmallForBypass, !EnBypass || ($bits(slink_pkg::tag_e)+slink_reg_pkg::Log2MaxNodeIds <= NumChannels*NumLanes*(1 + EnDdr)))
    
    `ASSERT(RxtoProtocolAndBypassActiveAtTheSameTime, !(recv_reg_index_q != '0 && rx_tx_bypass_active_q))
    `ASSERT(ProtocoltoTxAndBypassActiveAtTheSameTime, !(link_state_q == LinkSendBusy && rx_tx_bypass_active_q))
    `ASSERT(RecvRegsStable, (&recv_reg_out_valid) & !(&recv_reg_out_ready) |=> $stable(&recv_reg_out_valid))
    `ASSERT(ReceivedNotTooManyCredits, credits_out_q <=  NumCredits)

endmodule
