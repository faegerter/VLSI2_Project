// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter         <phsauter@iis.ee.ethz.ch>
// - Fabian Aegerter         <faegerter@ethz.ch>
// - Maximilian Kocher       <mkocher@ethz.ch>

 
module user_domain
  import user_pkg::*;
  import croc_pkg::*;
#(
  parameter int unsigned GpioCount       = 12,
  parameter int unsigned NumExternalIrqs = 4,  // must be >= 2
  parameter int unsigned VecLen_x        = 256
) (
  input  logic clk_i,
  input  logic ref_clk_i,
  input  logic rst_ni,
  input  logic testmode_i,
 
  input  sbr_obi_req_t user_sbr_obi_req_i,  // CPU -> user domain (subordinate port)
  output sbr_obi_rsp_t user_sbr_obi_rsp_o,
 
  // user domain -> SRAM: [0] = port 1 (W matrix reads), [1] = port 2 (x vector reads)
  output mgr_obi_req_t [NumUserManagers-1:0] user_mgr_obi_req_o,
  input  mgr_obi_rsp_t [NumUserManagers-1:0] user_mgr_obi_rsp_i,
 
  input  logic [      GpioCount-1:0] gpio_in_sync_i,
  output logic [NumExternalIrqs-1:0] interrupts_o
);
 
  // IRQ line mapping (positions are fixed by the platform — do not reorder):
  //   interrupts_o[0] = mac_irq       → IRQ_MAC_DONE  (line 20)
  //   interrupts_o[1] = 1'b0          — reserved (was irq_finish, now unused)
  //   interrupts_o[2] = mac_irq_start → IRQ_MAC_START (line 22)
  assign interrupts_o = {{(NumExternalIrqs-3){1'b0}}, mac_irq_start, 1'b0, mac_irq};
 
 
  ////////////////////////////
  // User Subordinate DEMUX //
  ////////////////////////////
 
  // Buses coming out of the demultiplexer, one per subordinate
  sbr_obi_req_t [NumDemuxSbr-1:0] all_user_sbr_obi_req;
  sbr_obi_rsp_t [NumDemuxSbr-1:0] all_user_sbr_obi_rsp;
 
  // Named aliases for readability
  sbr_obi_req_t user_error_obi_req, user_mac_ctrl_obi_req, user_rom_obi_req;
  sbr_obi_rsp_t user_error_obi_rsp, user_mac_ctrl_obi_rsp, user_rom_obi_rsp;
 
  assign user_error_obi_req                = all_user_sbr_obi_req[UserError];
  assign all_user_sbr_obi_rsp[UserError]   = user_error_obi_rsp;
 
  assign user_mac_ctrl_obi_req             = all_user_sbr_obi_req[UserMacCtrl];
  assign all_user_sbr_obi_rsp[UserMacCtrl] = user_mac_ctrl_obi_rsp;
 
  assign user_rom_obi_req                  = all_user_sbr_obi_req[UserRom];
  assign all_user_sbr_obi_rsp[UserRom]     = user_rom_obi_rsp;
 
  // Address decoder: maps incoming address to subordinate index
  logic [cf_math_pkg::idx_width(NumDemuxSbr)-1:0] user_idx;
 
  addr_decode #(
    .NoIndices ( NumDemuxSbr                     ),
    .NoRules   ( $size(UserAddrMap)              ),
    .addr_t    ( logic [SbrObiCfg.AddrWidth-1:0] ),
    .rule_t    ( addr_map_rule_t                 ),
    .Napot     ( 1'b0                            )
  ) i_addr_decode (
    .addr_i           ( user_sbr_obi_req_i.a.addr ),
    .addr_map_i       ( UserAddrMap               ),
    .idx_o            ( user_idx                  ),
    .dec_valid_o      (                           ),
    .dec_error_o      (                           ),
    .en_default_idx_i ( 1'b1                      ),
    .default_idx_i    ( UserError                 )
  );
 
  obi_demux #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMgrPorts ( NumDemuxSbr   ),
    .NumMaxTrans ( 2             )
  ) i_obi_demux (
    .clk_i,
    .rst_ni,
    .sbr_port_select_i ( user_idx             ),
    .sbr_port_req_i    ( user_sbr_obi_req_i   ),
    .sbr_port_rsp_o    ( user_sbr_obi_rsp_o   ),
    .mgr_ports_req_o   ( all_user_sbr_obi_req ),
    .mgr_ports_rsp_i   ( all_user_sbr_obi_rsp )
  );
 
 
  //-------------------------------------------------------------------------------------------------
  // User Subordinates
  //-------------------------------------------------------------------------------------------------
 
  // Error subordinate: returns 0xBADCAB1E for unmapped addresses
  obi_err_sbr #(
    .ObiCfg      ( SbrObiCfg     ),
    .obi_req_t   ( sbr_obi_req_t ),
    .obi_rsp_t   ( sbr_obi_rsp_t ),
    .NumMaxTrans ( 1             ),
    .RspData     ( 32'hBADCAB1E  )
  ) i_user_err (
    .clk_i,
    .rst_ni,
    .testmode_i ( testmode_i         ),
    .obi_req_i  ( user_error_obi_req ),
    .obi_rsp_o  ( user_error_obi_rsp )
  );
 
  //-------------------------------------------------------------------------------------------------
  // MAC control register file
  // See mac_ctrl_regs.sv for the full register map.
  //-------------------------------------------------------------------------------------------------
 
  logic [31:0] mac_matrix_base_addr;
  logic [31:0] mac_x_base_addr;
  logic [31:0] mac_vec_len;
  logic [31:0] mac_num_row;
  logic        mac_start;
  logic [31:0] mac_result;
  logic        mac_done;
  logic        mac_irq;
  logic        mac_irq_start;
 
  mac_ctrl_regs #(
    .obi_req_t ( sbr_obi_req_t ),
    .obi_rsp_t ( sbr_obi_rsp_t )
  ) i_mac_ctrl (
    .clk_i,
    .rst_ni,
    .obi_req_i          ( user_mac_ctrl_obi_req ),
    .obi_rsp_o          ( user_mac_ctrl_obi_rsp ),
    .matrix_base_addr_o ( mac_matrix_base_addr  ),
    .x_base_addr_o      ( mac_x_base_addr       ),
    .vec_len_o          ( mac_vec_len           ),
    .num_row_o          ( mac_num_row           ),
    .start_o            ( mac_start             ),
    .result_i           ( mac_result            ),
    .done_i             ( mac_done              ),
    .irq_o              ( mac_irq               ),
    .irq_start_o        ( mac_irq_start         )
  );
 
  //-------------------------------------------------------------------------------------------------
  // MAC accelerator
  //-------------------------------------------------------------------------------------------------
 
  mac_accelerator #(
    .ObiCfg      ( MgrObiCfg     ),
    .VecLen      ( VecLen_x      ),
    .mgr_req_t   ( mgr_obi_req_t ),
    .mgr_rsp_t   ( mgr_obi_rsp_t ),
    .NumMgrPorts ( NumMacMgr     )
  ) i_mac_accel (
    .clk_i,
    .rst_ni,
    .start_i            ( mac_start            ),
    .matrix_base_addr_i ( mac_matrix_base_addr ),
    .x_base_addr_i      ( mac_x_base_addr      ),
    .vec_len_i          ( mac_vec_len          ),
    .num_row_i          ( mac_num_row          ),
    .irq_pending_i      ( mac_irq              ),
    .result_o           ( mac_result           ),
    .done_o             ( mac_done             ),
    .mgr_obi_req_o      ( user_mgr_obi_req_o   ),
    .mgr_obi_rsp_i      ( user_mgr_obi_rsp_i   )
  );
 
  //-------------------------------------------------------------------------------------------------
  // User ROM
  //-------------------------------------------------------------------------------------------------
 
  user_rom #(
    .ObiCfg    ( SbrObiCfg     ),
    .obi_req_t ( sbr_obi_req_t ),
    .obi_rsp_t ( sbr_obi_rsp_t )
  ) i_user_rom (
    .clk_i,
    .rst_ni,
    .obi_req_i ( user_rom_obi_req ),
    .obi_rsp_o ( user_rom_obi_rsp )
  );
 
endmodule
