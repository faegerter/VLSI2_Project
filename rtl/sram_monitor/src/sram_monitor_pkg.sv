// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>


package sram_monitor_pkg;

  // Which accesses the monitor tracks
  typedef enum logic [1:0] {
    WriteAccess = 2'd0, 
    ReadAccess  = 2'd1, 
    RWAccess    = 2'd2  
  } access_type_e;

  // Configuration/status register map: byte offset within the OBI subordinate.
  typedef enum logic [7:0] {
    CtrlReg      = 8'h00, // bit0 = enable, bit1 = clear (W1: reset COUNT + IRQ)
    ThresholdReg = 8'h04, // accesses after which the IRQ fires (0 disables firing)
    CountReg     = 8'h08, // RO: in-window accesses since last clear/fire
    StatusReg    = 8'h0C, // RO bit0: IRQ pending; reading clears the IRQ
    StartAddrReg = 8'h10, // lowest  tracked in-bank byte address (inclusive)
    EndAddrReg   = 8'h14, // highest tracked in-bank byte address (inclusive)
    AccessReg    = 8'h18  // access_type_e
  } sram_monitor_reg_e;

endpackage
