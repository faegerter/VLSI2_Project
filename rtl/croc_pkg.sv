// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Philippe Sauter <phsauter@iis.ee.ethz.ch>
// - Fabian Aegerter         <faegerter@ethz.ch>
// - Llorenç Muela Hausmann  <lmuela@ethz.ch>
// - Maximilian Kocher       <mkocher@ethz.ch>


// header files for the two interconnect types used in Croc
`include "obi/typedef.svh"

/// Package for croc configuration, address map and interconnect types
package croc_pkg;
  //////////////////////
  // JTAG Info        //
  //////////////////////
  /// JTAG IDCODE for the Croc JTAG tap, used to identify the device
  typedef struct packed {
    bit [ 3:0]  version;
    bit [15:0]  part_num;
    bit [10:0]  manufacturer;
    bit         _one;
  } pulp_jtag_idcode_t;
  localparam pulp_jtag_idcode_t PulpJtagIdCode = '{
    _one:          1'b1,    /* must be 1 */
    manufacturer: 11'h6d9,  /* identify as PULP Platform chip */
    part_num:     16'hC0C5, /* default Croc part number */
    version:       4'h1     /* 2nd version (2026) */
  };

  ////////////////////////
  // iDMA Configuration //
  ////////////////////////
  localparam bit iDMAEnable = 1'b0;


  //////////////////////////
  // Core Configuration   //
  //////////////////////////
  /// Physical Memory Protection enable
  localparam bit          CorePMPEnable = 1'b0;
  /// Core type identifier reported in the SoC info register:
  /// 3'b000=CVE2, 3'b001=Ibex, 3'b111=custom, others are reserved
  localparam int unsigned CoreId        = 0;


  ////////////////////////
  // SRAM Configuration //
  ////////////////////////
  // Check in your target technology which SRAMs are available
  // and then make sure it is implemented as an option in tc_sram_impl.sv

  /// Number of SRAM banks, each bank has its own OBI port (accessible in parallel)
  localparam int unsigned NumSramBanks      = 32'd4;
  /// Number of 32-bit words per SRAM bank, determines the depth of each SRAM bank
  localparam int unsigned SmallSramBankNumWords  = 512;
  // Largest single physical macro available is RM_IHPSG13_1P_2048x64,
  // which yields a 4096-word x 32-bit bank (see gen_4096x32xBx1 in tc_sram_impl.sv)
  localparam int unsigned LargeSramBankNumWords  = 4096;

  /// Number of 32-bit words for an individual SRAM bank.
  /// All banks are small except the last one, which is the large bank.
  /// This must stay consistent with the per-bank regions in CrocAddrMap below.
  function automatic int unsigned SramBankNumWords(int unsigned bank_idx);
    return (bank_idx == NumSramBanks - 1) ? LargeSramBankNumWords : SmallSramBankNumWords;
  endfunction

  /// Total number of 32-bit words across all SRAM banks
  function automatic int unsigned TotalSramNumWords();
    int unsigned total = 0;
    for (int unsigned i = 0; i < NumSramBanks; i++) total += SramBankNumWords(i);
    return total;
  endfunction


  //////////////////////
  // Address Map Type //
  //////////////////////
  // ideally compatible with:
  // https://pulp-platform.github.io/cheshire/um/arch/#memory-map

  /// Address map data type
  typedef struct packed {
      logic [ 3:0] idx;
      logic [31:0] start_addr;
      logic [31:0] end_addr;
  } addr_map_rule_t;


  ////////////////////////////////
  // Main Crossbar Address Map ///
  ////////////////////////////////
  /// Number of manager ports into crossbar
  /// User Domain, Debug module, Core Data, Core Instr; optionally iDMA Write and iDMA Read
  localparam int unsigned NumXbarManagers = 6 + (iDMAEnable ? 2 : 0);
  localparam int unsigned NumUserManagers = 2;

  /// Enum with crossbar subordinate idxs
  typedef enum bit [3:0] {
    XbarError  = 0,
    XbarPeriph = 1,
    XbarUser   = 2,
    XbarSlink  = 3,
    XbarBank0  = 4
  } croc_xbar_outputs_e;

  /// Address map given to the main crossbar
  localparam addr_map_rule_t [6:0] CrocAddrMap = '{
    '{ idx: XbarPeriph,  start_addr: 32'h0000_0000, end_addr: 32'h0300_C000 },
    '{ idx: XbarSlink,   start_addr: 32'h0FFF_F000, end_addr: 32'hFFFF_FFFF },
    '{ idx: XbarUser,    start_addr: 32'h0FFF_E000, end_addr: 32'h0FFF_F000 },
    '{ idx: XbarBank0,   start_addr: 32'h0400_0000, end_addr: 32'h0400_0800 },
    '{ idx: XbarBank0+1, start_addr: 32'h0400_0800, end_addr: 32'h0400_1000 },
    '{ idx: XbarBank0+2, start_addr: 32'h0400_1000, end_addr: 32'h0400_1800 },
    '{ idx: XbarBank0+3, start_addr: 32'h0400_1800, end_addr: 32'h0400_5800 }
  };

  // +1 for additional OBI error
  localparam int unsigned NumXbarSubordinates = $size(CrocAddrMap) + 1;

  /// Connectivity matrix for the main crossbar [NumXbarManagers-1:0][NumXbarSubordinates-1:0]
  /// Default is fully connected. If you use the iDMA you may want to reduce this
  /// to reduce routing and improve timing for your specific application.
  /// Eg. if you add something in the user_domain, you may not need connectivity to peripherals
  function automatic logic [NumXbarManagers-1:0][NumXbarSubordinates-1:0] xbar_connectivity();
    logic [NumXbarSubordinates-1:0] idma_mask;
    xbar_connectivity = '1; // full connectivity for all by default
  endfunction

  localparam logic [NumXbarManagers-1:0][NumXbarSubordinates-1:0] XbarConnectivity = xbar_connectivity();

  /// Converts the bus idx enum for the main crossbar to start address of a subordinate
  /// Eg : get_croc_start_addr(XbarUser) returns the start address of the User region
  /// This is necesary because the idx do not directly correspond to the indices of the array
  function automatic bit [31:0] get_croc_start_addr(croc_xbar_outputs_e port);
    bit [31:0] addr = '0;
    for (int unsigned i = 0; i < $size(CrocAddrMap); i++) begin
      if (croc_xbar_outputs_e'(CrocAddrMap[i].idx) == port) begin
        return CrocAddrMap[i].start_addr;
      end
    end
    return addr;
  endfunction

  // For convenience get most used base addresses
  localparam bit [31:0] UserBaseAddr = get_croc_start_addr(XbarUser); // use as base for your IPs
  localparam bit [31:0] BootAddr     = get_croc_start_addr(XbarBank0); // start of SRAM banks


  ////////////////////////////////
  // Peripheral Mux Address Map //
  ////////////////////////////////
  /// Enum with peripheral mux subordinate idxs
  typedef enum bit [3:0] {
    PeriphError    = 0,
    PeriphDebug    = 1,
    PeriphBootrom  = 2,
    PeriphClint    = 3,
    PeriphSocCtrl  = 4,
    PeriphUart     = 5,
    PeriphGpio     = 6,
    PeriphTimer    = 7,
    PeriphiDMA     = 8,
    PeriphSramMon  = 9
  } periph_outputs_e;

  /// Address map given to the peripheral mux
  localparam addr_map_rule_t [8:0] PeriphAddrMap = '{
    '{ idx: PeriphDebug,   start_addr: 32'h0000_0000, end_addr: 32'h0004_0000 },
    '{ idx: PeriphBootrom, start_addr: 32'h0200_0000, end_addr: 32'h0200_4000 },
    '{ idx: PeriphClint,   start_addr: 32'h0204_0000, end_addr: 32'h0208_0000 },
    '{ idx: PeriphSocCtrl, start_addr: 32'h0300_0000, end_addr: 32'h0300_1000 },
    '{ idx: PeriphUart,    start_addr: 32'h0300_2000, end_addr: 32'h0300_3000 },
    '{ idx: PeriphGpio,    start_addr: 32'h0300_5000, end_addr: 32'h0300_6000 },
    '{ idx: PeriphiDMA,    start_addr: 32'h0300_B000, end_addr: 32'h0300_C000 },
    '{ idx: PeriphTimer,   start_addr: 32'h0300_A000, end_addr: 32'h0300_B000 },
    '{ idx: PeriphSramMon, start_addr: 32'h0300_6000, end_addr: 32'h0300_7000 }
  };

  // +1 for additional OBI error
  localparam int unsigned NumPeriphs = $size(PeriphAddrMap) + 1;

  /// Converts the bus indices enum for the peripheral mux to start address of a peripheral
  /// Eg : get_periph_start_addr(PeriphGpio) returns the start address of the GPIO peripheral
  /// This is necesary because the idx do not directly correspond to the indices of the array
  function automatic bit [31:0] get_periph_start_addr(periph_outputs_e port);
    bit [31:0] addr = '0;
    for (int unsigned i = 0; i < $size(PeriphAddrMap); i++) begin
      if (periph_outputs_e'(PeriphAddrMap[i].idx) == port) begin
        return PeriphAddrMap[i].start_addr;
      end
    end
    return addr;
  endfunction

  localparam bit [31:0] BootromAddr  = get_periph_start_addr(PeriphBootrom);

  ////////////////////////////////
  // Serial Link Mux Address Map //
  ////////////////////////////////
  /// Enum with slink mux subordinate idxs
  typedef enum bit [1:0] {
    SlinkError      = 0,
    SlinkCfgRegs    = 1,
    SlinkRing       = 2
  } link_outputs_e;

  /// Address map given to the peripheral mux
  localparam addr_map_rule_t [1:0] SlinkAddrMap = '{
    '{ idx: SlinkCfgRegs, start_addr: 32'h0FFF_F000, end_addr: 32'h0FFF_F000 + slink_reg_pkg::SLINK_REG_SIZE },
    '{ idx: SlinkRing   , start_addr: 32'h1000_0000, end_addr: 32'hFFFF_FFFF }
  };

  // +1 for additional OBI error
  localparam int unsigned NumSlinkSbr = $size(SlinkAddrMap) + 1;


  ///////////////////////////////////////////
  // Interconnect Types and Configurations //
  ///////////////////////////////////////////
  // OBI is configured as 32 bit data, 32 bit address width

  // Usually we would use the typedef.svh macros to define interconnects from parameters.
  // To make it easier to understand we instead write them out here,
  // in a comment at the end you can find the equivalent using the macros.

  /// OBI manager configuration (from a manager into the crossbar)
  localparam obi_pkg::obi_cfg_t MgrObiCfg = '{
    UseRReady:   1'b0,
    CombGnt:     1'b0,
    AddrWidth:     32,
    DataWidth:     32,
    IdWidth:        1,
    Integrity:   1'b0,
    BeFull:      1'b1,
    OptionalCfg:  '0
  };

  
  `OBI_TYPEDEF_DEFAULT_ALL(mgr_obi, MgrObiCfg)                                                                

  // Create types for OBI subordinates/slaves (out of the interconnect, into the device)
  localparam obi_pkg::obi_cfg_t SbrObiCfg = obi_pkg::mux_grow_cfg(MgrObiCfg, NumXbarManagers);

  `OBI_TYPEDEF_DEFAULT_ALL(sbr_obi, SbrObiCfg)                                                                

  // Register Interface configured as 32 bit data, 32 bit address width (4 byte enable bits)
  //`REG_BUS_TYPEDEF_ALL(reg, logic[31:0], logic[31:0], logic[3:0]);
endpackage
