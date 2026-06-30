# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Automatic collection of SRAMs and delay-line macros
# Used for automatic macro placement
# set macros [list]

# set srams [get_cells *RM_IHP*]
# foreach inst $srams {
#     lappend macros $inst
# }

# technology dependent
set DFF_CLK_PIN CK
set DFF_DATA_PIN D
set DFF_OUTP_PIN Q
#
set MUX_CONTROL_PIN S0
set MUX_OUT_PIN Y
set CLKGATE_GATE_PIN E

# Macro names as produced by the yosys synthesis
# Used for manual macro placement

set CROC            i_croc_soc/i_croc
set USER            i_croc_soc/i_user
set SLINK 			$CROC/i_slink
set SLINK_LINK 		$SLINK.i_serial_link_data_link
set SLINK_PHY0 		$SLINK.gen_phy_channels\[0\]
set SLINK_TX 		$SLINK_PHY0.i_serial_link_physical.i_slink_phys_layer_tx
set SLINK_RX 		$SLINK_PHY0.i_serial_link_physical.i_slink_phys_layer_rx
set IBEX            $CROC/i_core_wrap.i_ibex
set SRAM            $CROC/gen_sram_bank
set JTAG            $CROC/i_dmi_jtag
set SRAM_512x32     gen_512x32xBx1.i_cut
set SRAM_4096x32    gen_4096x32xBx1.i_cut


set SL_IN       [get_ports slink_ddr?_i]
set SL_OUT      [get_ports slink_ddr?_o]
set SL_OUT_CLK  [get_ports slink_ddr_rcv_clk_o]


# memory banks
set sram {\[0\].i_sram/}
set bank0_sram0 $SRAM$sram$SRAM_512x32
set sram {\[1\].i_sram/}
set bank1_sram0 $SRAM$sram$SRAM_512x32
set sram {\[2\].i_sram/}
set bank2_sram0 $SRAM$sram$SRAM_512x32
set sram {\[3\].i_sram/}
set bank3_sram1 $SRAM$sram$SRAM_4096x32

# TX internal divided data-launch clock, from clk_slow
set SLINK_TX_SLOW_REG [get_fanin -to $SLINK_TX.clk_slow -startpoints_only -only_cells]
set SLINK_TX_SLOW_Q   [get_pins -of_objects $SLINK_TX_SLOW_REG -filter "name == $DFF_OUTP_PIN"]
set SLINK_TX_SLOW_CLK [get_pins -of_objects $SLINK_TX_SLOW_REG -filter "name == $DFF_CLK_PIN"]

# port i_serial_link/ddr_rcv_clk_o
set SLO_PHY_RCLK_REG [get_cells *ddr_rcv_clk_o*]
set SLO_PHY_RCLK_Q   [get_pins -of_objects $SLO_PHY_RCLK_REG -filter "name == $DFF_OUTP_PIN"]
set SLO_PHY_RCLK_CLK [get_pins -of_objects $SLO_PHY_RCLK_REG -filter "name == $DFF_CLK_PIN"]

# Credit return: tc_clk_gating in slink_link_layer (sg13g2_slgcp_1 inside)
set SLINK_CREDIT_ICG      $SLINK_LINK.i_clk_gate/gen_clkgate.i_clkgate
set SLINK_CREDIT_ICG_CLK  [get_pins -of_objects $SLINK_CREDIT_ICG -filter "name == CK"]
set SLINK_CREDIT_ICG_GCLK [get_pins -of_objects $SLINK_CREDIT_ICG -filter "name == ECK"]
set SLINK_CREDIT_ICG_GATE [get_pins -of_objects $SLINK_CREDIT_ICG -filter "name == E"]

# TX forwarded clock register
# set SLINK_TX_FWDCLK_REG [get_cells *ddr_rcv_clk_o*reg*]
# set SLINK_TX_FWDCLK_Q   [get_pins -of_objects $SLINK_TX_FWDCLK_REG -filter "name == $DFF_OUTP_PIN"]
# set SLINK_TX_FWDCLK_CLK [get_pins -of_objects $SLINK_TX_FWDCLK_REG -filter "name == $DFF_CLK_PIN"]
# CDC async nets
set ASYNC_PINS_SL_RX     [get_nets $SLINK_RX.i_cdc_in.*async_*]
set ASYNC_PINS_SL_CREDIT [get_nets $SLINK_LINK.i_credit_recv_cdc_fifo_gray.*async_*]

# JTAG request and response CDCs
# Goal: Find the async nets and their source and destination cells
# We only want to constrain paths internal to the CDC and going through the async nets.
# It is more complex than usual due to how OpenROAD currently dissolves hierarchy when reading in designs.
set JTAG_CDC_REQ $JTAG/i_dmi_cdc.i_cdc_req
# find all startpoints (flops) that drive through async_data nets and flops that directly drive async nets
set JTAG_ASYNC_REQ_START [get_fanin -to [get_nets $JTAG_CDC_REQ/*async_data*] -flat -startpoints_only -only_cells]
set JTAG_ASYNC_REQ_START [concat $JTAG_ASYNC_REQ_START [get_cells $JTAG_CDC_REQ/*async*_o*_reg]]
# find all endpoints (flops) that are driven through async nets and are in the CDC
set JTAG_ASYNC_REQ_END [list]
set JTAG_ASYNC_REQ_CANDIDATES [get_fanout -from [get_nets $JTAG_CDC_REQ/*async*_data*] -flat -endpoints_only -only_cells]
foreach cell $JTAG_ASYNC_REQ_CANDIDATES {
	if {[string match "${JTAG_CDC_REQ}/*" [get_name $cell]]} {
		lappend JTAG_ASYNC_REQ_END $cell
	}
}
# These paths (clear and isolate) go out of the CDC but we know they cannot cause timing violations
# because they have a seperate 4-phase handshake making sure they stay stable for multiple cycles in each clock domain.
lappend JTAG_ASYNC_REQ_END {*}[get_fanout -from [get_pins $JTAG_CDC_REQ/*i_cdc_reset_ctrlr_half_a*async_data*_reg/Q] -flat -endpoints_only -only_cells]

# The same for the response CDC
set JTAG_CDC_RSP $JTAG/i_dmi_cdc.i_cdc_resp
set JTAG_ASYNC_RSP_START [get_fanin -to [get_nets $JTAG_CDC_RSP/*async_data*] -flat -startpoints_only -only_cells]
set JTAG_ASYNC_RSP_START [concat $JTAG_ASYNC_RSP_START [get_cells $JTAG_CDC_RSP/*async*_o*_reg]]
set JTAG_ASYNC_RSP_END [list]
set JTAG_ASYNC_RSP_CANDIDATES [get_fanout -from [get_nets $JTAG_CDC_RSP/*async*_data*] -flat -endpoints_only -only_cells]
foreach cell $JTAG_ASYNC_RSP_CANDIDATES {
	if {[string match "${JTAG_CDC_RSP}/*" [get_name $cell]]} {
		lappend JTAG_ASYNC_RSP_END $cell
	}
}
lappend JTAG_ASYNC_RSP_END {*}[get_fanout -from [get_pins $JTAG_CDC_RSP/*i_cdc_reset_ctrlr_half_a*async_data*_reg/Q] -flat -endpoints_only -only_cells]

