# ---------------------------------------------------------------------------
#  report_power_ring.tcl  —  stimulus-based power for ONE croc_chip instance
#                            of the serial-link ring.
#
#  The ring VCD contains many chip instances; OpenROAD holds a single
#  croc_chip netlist. `read_vcd -scope <inst>` maps the recorded switching of
#  one chip instance onto that netlist, so we get that node's power. Summing
#  over all nodes (done by the driver) yields the whole-ring power.
#
#  Run from the openroad/ directory. Parameters are taken from Tcl globals if
#  the caller sets them, else from environment variables (upper-cased), else a
#  default:
#      pwr_vcd     PWR_VCD      path to the ring VCD                (required)
#      pwr_scope   PWR_SCOPE    VCD scope of the chip instance,     (required)
#                               e.g. tb_croc_soc_ring/gen_nodes[0]/i_croc_chip
#      pwr_corner  PWR_CORNER   tt | ff                             (default tt)
#      pwr_act     PWR_ACT      default activity for un-annotated   (default 0.01)
# ---------------------------------------------------------------------------

proc opt {name def} {
  set up [string toupper $name]
  if {[info exists ::$name]}    { return [set ::$name] }
  if {[info exists ::env($up)]} { return $::env($up) }
  return $def
}

set pwr_vcd    [opt pwr_vcd    ""]
set pwr_scope  [opt pwr_scope  ""]
set pwr_corner [opt pwr_corner "tt"]
set pwr_act    [opt pwr_act    0.01]

if {$pwr_vcd eq "" || $pwr_scope eq ""} {
  puts "ERROR: pwr_vcd and pwr_scope must be set"
  exit 1
}

source scripts/init_tech.tcl

# --- Design + parasitics ----------------------------------------------------
# Prefer the generated SPEF (tutorial flow). If it is absent, fall back to the
# routed ODB and estimate parasitics, so the flow still works without a SPEF.
if {[file exists out/croc.spef]} {
  puts "PWR_STEP: read_verilog + link_design + read_sdc + read_spef"
  read_verilog out/croc.v
  link_design  croc_chip
  read_sdc     out/croc.sdc
  read_spef    out/croc.spef
} else {
  puts "PWR_STEP: read_db + read_sdc + estimate_parasitics"
  read_db  out/croc.odb
  read_sdc out/croc.sdc
  setDefaultParasitics
  estimate_parasitics -global_routing
}

# --- Work around zero-period generated clocks -------------------------------
# A few slink generated clocks (clk_gen_slo*, clk_gen_cred_rtrn) do not resolve
# to a period in this standalone session, so report_power divides by zero and
# returns NaN/inf. Give any zero-period clock a sensible fallback period on its
# own source pin: the DDR/slow forwarded clocks run at ~clk_sys/4 (50 ns), the
# credit-return clock at ~clk_sys (12.5 ns). These slink clocks are essentially
# idle in the captured window (read_vcd measures them at ~80 us), so the exact
# value is immaterial to the total - it only needs to be nonzero.
puts "PWR_STEP: fix zero-period clocks"; flush stdout
foreach clk [get_clocks *] {
  if {[get_property $clk period] <= 0} {
    set nm  [get_name $clk]
    set src [get_property $clk sources]
    set p   [expr {[string match *cred* $nm] ? 12.5 : 50.0}]
    puts "PWR_FIX: zero-period clock $nm -> ${p} ns"
    create_clock -name $nm -period $p $src
  }
}

# --- Activity ---------------------------------------------------------------
# Default toggle for everything the VCD does not annotate; reset held static.
puts "PWR_STEP: set_power_activity"; flush stdout
set_power_activity -global -activity $pwr_act
set_power_activity -input_port rst_ni -activity 0

# Map one chip instance's recorded switching onto the netlist.
puts "PWR_STEP: read_vcd  (scope=$pwr_scope)"; flush stdout
read_vcd -scope $pwr_scope $pwr_vcd

# --- Report (markers make the Total row easy to parse) ----------------------
puts "PWR_STEP: report_power"
puts "PWR_SCOPE_BEGIN $pwr_scope"
report_power -corner $pwr_corner
puts "PWR_SCOPE_END $pwr_scope"
exit
