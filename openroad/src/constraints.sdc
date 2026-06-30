# Copyright 2024 ETH Zurich and University of Bologna.
# Solderpad Hardware License, Version 0.51, see LICENSE for details.
# SPDX-License-Identifier: SHL-0.51

# Authors:
# - Philippe Sauter <phsauter@iis.ee.ethz.ch>

# Backend constraints

############
## Global ##
############

source src/instances.tcl

# Not set in the liberty file of the EZ cells; limiting fanout often reduced routing stress
set_max_fanout 16 [current_design]


#############################
## Driving Cells and Loads ##
#############################

# As a default, drive multiple GPIO pads and be driven by one.
# accomodate for driving up to 2 74HC pads plus a 5pF trace
set_load [expr 2 * 5.0 + 5.0] [all_outputs]
set_driving_cell [all_inputs] -lib_cell sg13cmos5l_IOPadOut16mA -pin pad

# Serial link drives one pad per IO, but may have larger capacity (e.g. FPGA)
set SLINK_OUT_PADS [get_ports {slink_ddr*_o slink_ddr_rcv_clk_o slink_credit_rtrn_clk_o}]
set_load -min  4.0 $SLINK_OUT_PADS
set_load -max 16.0 $SLINK_OUT_PADS

##################
## Input Clocks ##
##################
puts "Clocks..."

# We target 80 MHz
set TCK_SYS 12.500
create_clock -name clk_sys -period $TCK_SYS [get_ports clk_i]

set TCK_JTG 25.0
create_clock -name clk_jtg -period $TCK_JTG [get_ports jtag_tck_i]

set TCK_RTC 50.0
create_clock -name clk_rtc -period $TCK_RTC [get_ports ref_clk_i]

set TCK_SLI       [expr 4 * $TCK_SYS] ; # nominal slink rate (clk_sys / 4)
set TCK_SLI_CRED  $TCK_SYS            ; # credit clock can match clk_sys
create_clock -name clk_sli_rx   -period $TCK_SLI      [get_ports slink_ddr_rcv_clk_i]
create_clock -name clk_sli_cred -period $TCK_SLI_CRED [get_ports slink_credit_recv_clk_i]

######################
## Generated Clocks ##
######################

# Create slow clock driving TX output (worst case: divided by 4)
	#puts "SLINK slow TX clk: master-clk from [get_full_name $SLINK_TX_SLOW_CLK] & drives pins [get_full_name $SLINK_TX_SLOW_Q]"
create_generated_clock -name clk_gen_slo_drv \
    -edges {1 5 9} \
    -source $SLINK_TX_SLOW_CLK \
    $SLINK_TX_SLOW_Q

# Create clock for serial link TX (worst case: divided by 4, +90 deg)
puts "SLINK slow RX clk: master-clk from [get_full_name $SLO_PHY_RCLK_CLK] & drives pins [get_full_name $SLO_PHY_RCLK_Q]"
create_generated_clock -name clk_gen_slo \
    -edges {3 7 11} \
    -source $SLO_PHY_RCLK_CLK \
    $SLO_PHY_RCLK_Q

# puts "SLINK forwarded DDR clk pad: source [get_full_name $SLO_PHY_RCLK_CLK] -> [get_full_name $SL_OUT_CLK]"
# create_generated_clock -name clk_gen_slo -add \
#     -master_clock clk_sys \
#     -edges {3 7 11} \
#     -source $SLO_PHY_RCLK_CLK \
#     $SL_OUT_CLK

# Credit return: gated clk_sys, worst case one enabled cycle per sys cycle
	puts "SLINK credit return clk: ICG GCLK [get_full_name $SLINK_CREDIT_ICG_GCLK] -> port slink_credit_rtrn_clk_o"
create_generated_clock -name clk_gen_cred_rtrn \
    -divide_by 1 \
    -source $SLINK_CREDIT_ICG_CLK \
    $SLINK_CREDIT_ICG_GCLK
    
# create_generated_clock -name clk_gen_cred_rtrn -add \
#     -master_clock clk_sys \
#     -divide_by 1 \
#     -source $SLINK_CREDIT_ICG_CLK \
#     [get_ports slink_credit_rtrn_clk_o]


##################################
## Clock Groups & Uncertainties ##
##################################

# Define which clocks are asynchronous to each other
# If you have added a clock it is a good idea to temporarily add -allow_paths.
# This means the paths between clocks (CDC) are timed and will show up as violations,
# making them very easy to find and write constraints for.
set_clock_groups -asynchronous -name clk_groups_async \
     -group {clk_rtc} \
     -group {clk_jtg} \
     -group {clk_sys clk_gen_slo_drv clk_gen_slo clk_gen_cred_rtrn} \
     -group {clk_sli_rx} \
     -group {clk_sli_cred}

#removed -group {clk_sys} 
# We set reasonable uncertainties in their transistion timing
# and transition (rise/fall) times for all clocks (ns)
set CLK_UNCERTAINTY   0.1
set_clock_uncertainty $CLK_UNCERTAINTY [all_clocks]
set_clock_transition  0.2 [all_clocks]

set_clock_gating_check -setup 0.5 -hold 0.0 [get_clocks clk_sys]


####################
## Cdcs and Syncs ##
####################
puts "CDC/Sync..."

# Clock Domain Crossings: paths going from an FF with one clock to an FF with another.
# The setup/hold checks on these paths are deactivated by set_clock_groups -asynchronous.
# An additional requirement is that the max delay is below min($TCK_SYS, $TCK_JTG) 
# to make sure any change propages within one cycle of either clock.
# An (optional) lower delay is better for metastability recovery -> 3ns as a reasonable goal

## Constrain `cdc_2phase` for DMI request
set_max_delay 3.0 -from $JTAG_ASYNC_REQ_START -to $JTAG_ASYNC_REQ_END -ignore_clock_latency

# Constrain `cdc_2phase` for DMI response
set_max_delay 3.0 -from $JTAG_ASYNC_RSP_START -to $JTAG_ASYNC_RSP_END -ignore_clock_latency

# Constrain `cdc_fifo_gray` for serial link in
set_max_delay [expr $TCK_SYS * 0.20   ] -through $ASYNC_PINS_SL_RX -ignore_clock_latency
set_min_delay [expr - $CLK_UNCERTAINTY] -through $ASYNC_PINS_SL_RX -ignore_clock_latency
set_max_delay [expr $TCK_SYS * 0.20   ] -through $ASYNC_PINS_SL_CREDIT -ignore_clock_latency
set_min_delay [expr - $CLK_UNCERTAINTY] -through $ASYNC_PINS_SL_CREDIT -ignore_clock_latency


#############
## SoC Ins ##
#############
puts "Input/Outputs..."

# Reset should propagate to system domain within a clock cycle.
set_input_delay -max [ expr $TCK_JTG * 0.10 ] [get_ports {rst_ni testmode_i}]  
set_false_path -hold   -from [get_ports {rst_ni testmode_i}]
set_max_delay $TCK_SYS -from [get_ports {rst_ni testmode_i}]


##########
## JTAG ##
##########
puts "JTAG..."

set_input_delay  -min -add_delay -clock clk_jtg [ expr $TCK_JTG * 0.10 ] [get_ports {jtag_tdi_i jtag_tms_i}]
set_input_delay  -max -add_delay -clock clk_jtg [ expr $TCK_JTG * 0.30 ] [get_ports {jtag_tdi_i jtag_tms_i}]
set_output_delay -min -add_delay -clock clk_jtg [ expr $TCK_JTG * 0.10 ] [get_ports jtag_tdo_o]
set_output_delay -max -add_delay -clock clk_jtg [ expr $TCK_JTG * 0.20 ] [get_ports jtag_tdo_o]

# Reset should propagate to system domain within a clock cycle.
set_input_delay -max [ expr $TCK_JTG * 0.10 ] [get_ports jtag_trst_ni]  
set_false_path -hold    -from [get_ports jtag_trst_ni]
set_max_delay $TCK_JTG  -from [get_ports jtag_trst_ni]


##########
## GPIO ##
##########
puts "GPIO..."

set_input_delay  -min -add_delay -clock clk_sys [ expr $TCK_SYS * 0.10 ] [get_ports {gpio*}]
set_input_delay  -max -add_delay -clock clk_sys [ expr $TCK_SYS * 0.30 ] [get_ports {gpio*}]

set_output_delay -min -add_delay -clock clk_sys [ expr $TCK_SYS * 0.10 ] [get_ports {gpio*}]
set_output_delay -max -add_delay -clock clk_sys [ expr $TCK_SYS * 0.30 ] [get_ports {gpio*}]

# The timing of these signals are not important but we want to keep them in-cycle
set_output_delay -min -add_delay -clock clk_sys [ expr $TCK_SYS * 0.10 ] [get_ports {status_o}]
set_output_delay -max -add_delay -clock clk_sys [ expr $TCK_SYS * 0.10 ] [get_ports {status_o}]


##########
## UART ##
##########
puts "UART..."

set_input_delay  -min -add_delay -clock clk_sys [ expr $TCK_SYS * 0.10 ] [get_ports uart_rx_i]
set_input_delay  -max -add_delay -clock clk_sys [ expr $TCK_SYS * 0.30 ] [get_ports uart_rx_i]
set_output_delay -min -add_delay -clock clk_sys [ expr $TCK_SYS * 0.10 ] [get_ports uart_tx_o]
set_output_delay -max -add_delay -clock clk_sys [ expr $TCK_SYS * 0.30 ] [get_ports uart_tx_o]


#################
## Serial Link ##
#################
puts "Serial Link..."

set SL_MAX_SKEW 0.55
# set SL_IN       [get_ports slink_ddr?_i]
# set SL_OUT      [get_ports slink_ddr?_o]
# set SL_OUT_CLK  [get_ports slink_ddr_rcv_clk_o]



# set SL_OUT_CLK_PORTS [get_ports {slink_ddr_rcv_clk_o slink_credit_rtrn_clk_o}]
# # Launch-to-pad for forwarded / credit clocks (clears unconstrained output endpoints)
# set_max_delay [expr {$TCK_SLI * 0.25}] -from [get_clocks clk_gen_slo] -to $SL_OUT_CLK_PORTS -ignore_clock_latency
# set_max_delay $TCK_SYS -from [get_clocks clk_gen_cred_rtrn] -to [get_ports slink_credit_rtrn_clk_o] -ignore_clock_latency
# # Hold at chip boundary is partner/board responsibility
# set_false_path -hold -to $SL_OUT_CLK_PORTS





# DDR Input: Maximize assumed *transition* (unstable) interval by maximizing input delay span.
# Transitions happen *between* sampling input clock edges, so centered around T/4 *after* sampling edges.
# We assume that the transition takes up almost a full half period, so (T/4 - (T/4-skew), T/4 + (T/4-skew)).
set_input_delay -min -add_delay -clock clk_sli_rx -network_latency_included [expr +$SL_MAX_SKEW] $SL_IN
set_input_delay -min -add_delay -clock_fall -clock clk_sli_rx -network_latency_included [expr +$SL_MAX_SKEW] $SL_IN
set_input_delay -max -add_delay -clock clk_sli_rx -network_latency_included [expr $TCK_SLI / 2 -1.5 - $SL_MAX_SKEW] $SL_IN
set_input_delay -max -add_delay -clock_fall -clock clk_sli_rx -network_latency_included [expr $TCK_SLI / 2 -1.5 - $SL_MAX_SKEW] $SL_IN

# DDR Output: Maximize *stable* interval we provide by maximizing output delay span (i.e. range in
# which the target device may sample). This allows our outputs to transition only in a small margin.
# The stable interval is centered around the centered clock sent for sampling, so (-T/4+skew, T/4-skew)
set_output_delay -min -add_delay -clock clk_gen_slo -reference_pin $SL_OUT_CLK [expr -$TCK_SLI / 4 + $SL_MAX_SKEW] $SL_OUT
set_output_delay -min -add_delay -clock_fall -clock clk_gen_slo -reference_pin $SL_OUT_CLK [expr -$TCK_SLI / 4 + $SL_MAX_SKEW] $SL_OUT
set_output_delay -max -add_delay -clock clk_gen_slo -reference_pin $SL_OUT_CLK [expr $TCK_SLI / 4 - $SL_MAX_SKEW] $SL_OUT
set_output_delay -max -add_delay -clock_fall -clock clk_gen_slo -reference_pin $SL_OUT_CLK [expr $TCK_SLI / 4 - $SL_MAX_SKEW] $SL_OUT


# Do not consider noncritical edges between driving and sent TX clock
set_false_path -setup -rise_from [get_clocks clk_gen_slo_drv] -rise_to [get_clocks clk_gen_slo]
set_false_path -setup -fall_from [get_clocks clk_gen_slo_drv] -fall_to [get_clocks clk_gen_slo]
set_false_path -hold  -rise_from [get_clocks clk_gen_slo_drv] -fall_to [get_clocks clk_gen_slo]
set_false_path -hold  -fall_from [get_clocks clk_gen_slo_drv] -rise_to [get_clocks clk_gen_slo]

set SLINK_CLK_MUX_CELLS [get_fanout -only_cells -from $SLINK_TX_SLOW_Q]
set SLINK_CLK_MUX_PINS  [get_pins -of_objects $SLINK_CLK_MUX_CELLS -filter "name == $MUX_CONTROL_PIN"]
set_sense -clock -stop_propagation $SLINK_CLK_MUX_PINS
