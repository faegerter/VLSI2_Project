// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter         <phsauter@iis.ee.ethz.ch>
// - Fabian Aegerter         <faegerter@ethz.ch>
// - Maximilian Kocher       <mkocher@ethz.ch>



package user_pkg;

  //////////////////
  // User Manager //
  //////////////////
  localparam int unsigned NumMacMgr    = 2;
   


  ///////////////////////
  // User Subordinates //
  ///////////////////////

  // The base address of the user domain can be retrived from `croc_pkg::UserBaseAddr`
  // Recommended: place subordinates at 4KB boundaries (32'hXXXX_X000)


  typedef enum bit [1:0] {
    UserError   = 0,
    UserMacCtrl = 1,  // MAC control/config registers + trigger
    UserRom     = 2
  } user_demux_outputs_e;




  localparam croc_pkg::addr_map_rule_t [1:0] UserAddrMap = '{
    '{
      idx:        UserMacCtrl,
      start_addr: croc_pkg::UserBaseAddr + 32'h0000_0000,
      end_addr:   croc_pkg::UserBaseAddr + 32'h0000_0100  // 256 B for all MAC ctrl regs
    },
    '{
      idx:        UserRom,
      start_addr: croc_pkg::UserBaseAddr + 32'h0000_0200,
      end_addr:   croc_pkg::UserBaseAddr + 32'h0000_0240
    }  
  };


  // +1 for additional OBI error
  localparam int unsigned NumDemuxSbr = $size(UserAddrMap) + 1;

endpackage
