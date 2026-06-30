# ---------------------------------------------------------------------------
#  gen_spef.tcl  —  one-time SPEF generation for the post-layout croc_chip
#
#  Run from the openroad/ directory:
#      cd openroad
#      oseda -2025.12 openroad -exit ../power/gen_spef.tcl
#
#  This PDK checkout ships no OpenRCX pattern-rules file (technology/rcx/ is
#  empty), so we cannot run `extract_parasitics -ext_model_file ...`. Instead we
#  estimate parasitics from the *routed* ODB (global-routing topology + the
#  per-layer wire RC from setDefaultParasitics) and write that out as SPEF.
#
#  If you ever obtain the IHP RCX rules, swap the estimate block for:
#      define_process_corner -ext_model_index 0 tt
#      extract_parasitics -ext_model_file <IHP_rcx_patterns.rules>
#  for a more accurate extraction.
# ---------------------------------------------------------------------------

source scripts/init_tech.tcl

set extRules ../technology/rcx/IHP_rcx_patterns.rules
read_def out/croc.def          ;# routed design (geometry + netlist)

define_process_corner -ext_model_index 0 tt
extract_parasitics -ext_model_file $extRules

write_spef out/croc.spef
puts "WROTE out/croc.spef"
exit
