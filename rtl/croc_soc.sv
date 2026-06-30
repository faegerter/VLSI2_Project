// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>
// - Fabian Aegerter         <faegerter@ethz.ch>
// - Maximilian Kocher       <mkocher@ethz.ch>

module croc_soc import croc_pkg::*; #(
  parameter int unsigned GpioCount = 12,
  parameter int unsigned SlinkNumChannels = 1,
  parameter int unsigned SlinkNumLanes = 10
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic ref_clk_i,
  input  logic testmode_i,
  output logic status_o,

  input  logic jtag_tck_i,
  input  logic jtag_tdi_i,
  output logic jtag_tdo_o,
  input  logic jtag_tms_i,
  input  logic jtag_trst_ni,

  input  logic uart_rx_i,
  output logic uart_tx_o,

  input  logic [GpioCount-1:0] gpio_i,        // Input from GPIO pins
  output logic [GpioCount-1:0] gpio_o,        // Output to GPIO pins
  output logic [GpioCount-1:0] gpio_out_en_o, // Output enable signal; 0 -> input, 1 -> output

  input   logic  [SlinkNumChannels-1:0]                    slink_ddr_rcv_clk_i,    
  output  logic  [SlinkNumChannels-1:0]                    slink_ddr_rcv_clk_o,    
  input   logic  [SlinkNumChannels-1:0][SlinkNumLanes-1:0] slink_ddr_i,            
  output  logic  [SlinkNumChannels-1:0][SlinkNumLanes-1:0] slink_ddr_o,            
  input   logic                                            slink_credit_recv_clk_i,
  output  logic                                            slink_credit_rtrn_clk_o
);

  logic synced_rst_n;

  rstgen i_rstgen (
    .clk_i,
    .rst_ni,
    .test_mode_i ( testmode_i ),
    .rst_no      ( synced_rst_n ),
    .init_no     ()
  );

// Connection between Croc_domain and User_domain: User Sbr, Croc Mgr
sbr_obi_req_t user_sbr_obi_req;
sbr_obi_rsp_t user_sbr_obi_rsp;

// Connection between Croc_domain and User_domain: Croc Sbr, User Mgr
// Number of manager ports the user domain drives into the crossbar
// ([0] = port 1 / W matrix reads, [1] = port 2 / x vector reads).
mgr_obi_req_t [NumUserManagers-1:0] user_mgr_obi_req;
mgr_obi_rsp_t [NumUserManagers-1:0] user_mgr_obi_rsp;

localparam int unsigned NumExternalIrqs = 4;
logic [NumExternalIrqs-1:0] interrupts;
logic [      GpioCount-1:0] gpio_in_sync;

croc_domain #(
  .GpioCount        ( GpioCount        ),
  .NumExternalIrqs  ( NumExternalIrqs  ),
  .SlinkNumChannels ( SlinkNumChannels ),
  .SlinkNumLanes    ( SlinkNumLanes    )
) i_croc (
  .clk_i,
  .rst_ni ( synced_rst_n ),
  .ref_clk_i,
  .testmode_i,

  .jtag_tck_i,
  .jtag_tdi_i,
  .jtag_tdo_o,
  .jtag_tms_i,
  .jtag_trst_ni,

  .uart_rx_i,
  .uart_tx_o,

  .gpio_i,
  .gpio_o,
  .gpio_out_en_o,

  .gpio_in_sync_o ( gpio_in_sync ),

  .user_sbr_obi_req_o  ( user_sbr_obi_req ),
  .user_sbr_obi_rsp_i  ( user_sbr_obi_rsp ),

  .user_mgr_obi_req_i  ( user_mgr_obi_req ),
  .user_mgr_obi_rsp_o  ( user_mgr_obi_rsp ),

  .interrupts_i ( interrupts ),
  .core_busy_o  ( status_o   ),

  .slink_ddr_rcv_clk_i      ( slink_ddr_rcv_clk_i     ),    
  .slink_ddr_rcv_clk_o      ( slink_ddr_rcv_clk_o     ), 

  .slink_ddr_i              ( slink_ddr_i             ),            
  .slink_ddr_o              ( slink_ddr_o             ), 

  .slink_credit_recv_clk_i  ( slink_credit_recv_clk_i ),
  .slink_credit_rtrn_clk_o  ( slink_credit_rtrn_clk_o )
);

user_domain #(
  .GpioCount        ( GpioCount        ),
  .NumExternalIrqs  ( NumExternalIrqs  )
) i_user (
  .clk_i,
  .rst_ni ( synced_rst_n ),
  .ref_clk_i,
  .testmode_i,

  .user_sbr_obi_req_i ( user_sbr_obi_req ),
  .user_sbr_obi_rsp_o ( user_sbr_obi_rsp ),

  .user_mgr_obi_req_o ( user_mgr_obi_req ),
  .user_mgr_obi_rsp_i ( user_mgr_obi_rsp ),

  .gpio_in_sync_i ( gpio_in_sync ),
  .interrupts_o   ( interrupts   )
);

endmodule
