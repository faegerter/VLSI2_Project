#!/usr/bin/env bash
#
# simulate.sh — build a test program and run it in simulation.
#
# End-to-end simulation driver: builds the requested test program with the
# sw/Makefile and runs it through either the Verilator flow
# (verilator/run_verilator.sh) or the QuestaSim flow (vsim/run_vsim.sh), on
# either the multi-node ring testbench (tb_croc_soc_ring) or the single-node
# standard testbench (tb_croc_soc). Everything runs inside the oseda env.
#
# Defaults: serial_link test, ring testbench, Verilator, RTL.

set -e

# Resolve repo paths from the script location so the inside-oseda and
# outside-oseda phases (see the workflow section below) agree on directories
# regardless of the directory the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---- Defaults ----
TEST="serial_link"     # test program (see --test)
TB="ring"              # ring | standard
SIM="verilator"        # verilator | vsim
POSTLAYOUT=0           # vsim only: simulate the post-layout (OpenROAD) netlist
USE_SDF=0              # vsim postlayout only: back-annotate croc.sdf
NUM_NODES=3            # ring only
N_TESTS=""             # ring only; empty -> per-test default (mac_accel:1, else:5)
VEC_LEN=128            # MAC test build parameter (matrix-vector length)
NUM_ROWS=""            # MAC test build parameter (empty -> Makefile default)
OSEDA_VERSION="-2025.12"

print_help() {
  cat << EOF
Usage: $0 [options]

Builds a test program and runs it in simulation.

Test selection:
  --test NAME       Test program to build/run (default: serial_link)
                      ring mode     : builds 'make test_NAME'; each node loads
                                      NAME_test_node<ID>.hex
                                      (e.g. serial_link, mac_accel)
                      standard mode : builds 'make compile'; runs
                                      ../sw/bin/NAME.hex (e.g. helloworld)
  --tb MODE         Testbench: ring (default) or standard
  --num-nodes N     Ring node count       (default: 3, ring only)
  --n-tests T       Test iteration count  (default: 5, ring only)

MAC test parameters (test_mac_accel; ignored by tests that don't use them):
  --vec-len V       Matrix-vector length             (default: 128)
  --num-rows R      Total rows (must be a multiple of --num-nodes;
                    default: derived as NUM_NODES * 2)

Simulator selection:
  --sim ENGINE      verilator (default) or vsim
  --postlayout      vsim only: simulate the post-layout (OpenROAD) netlist
  --sdf             vsim postlayout only: back-annotate SDF timing

  -h, --help        Show this help message

Examples:
  # default: serial-link ring on Verilator (RTL)
  ./simulate.sh

  # MAC accelerator ring on Verilator (4 nodes, custom geometry)
  ./simulate.sh --test mac_accel --num-nodes 4 --vec-len 64 --num-rows 8

  # serial-link ring, post-layout netlist with SDF, on QuestaSim
  ./simulate.sh --sim vsim --postlayout --sdf

  # single-node helloworld on the standard testbench (Verilator)
  ./simulate.sh --tb standard --test helloworld
EOF
}

# ---- Parse arguments ----
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --test)
      if [[ -n "${2:-}" && "$2" != --* ]]; then TEST="$2"; shift 2
      else echo "Error: --test requires a name (e.g. --test mac_accel)"; exit 1; fi
      ;;
    --tb)
      if [[ -n "${2:-}" && "$2" != --* ]]; then TB="$2"; shift 2
      else echo "Error: --tb requires a value (ring|standard)"; exit 1; fi
      ;;
    --sim)
      if [[ -n "${2:-}" && "$2" != --* ]]; then SIM="$2"; shift 2
      else echo "Error: --sim requires a value (verilator|vsim)"; exit 1; fi
      ;;
    --postlayout)
      POSTLAYOUT=1; shift
      ;;
    --sdf)
      USE_SDF=1; shift
      ;;
    --num-nodes)
      if [[ -n "${2:-}" && "$2" != --* ]]; then NUM_NODES="$2"; shift 2
      else echo "Error: --num-nodes requires a numeric argument"; exit 1; fi
      ;;
    --n-tests)
      if [[ -n "${2:-}" && "$2" != --* ]]; then N_TESTS="$2"; shift 2
      else echo "Error: --n-tests requires a numeric argument"; exit 1; fi
      ;;
    --vec-len)
      if [[ -n "${2:-}" && "$2" != --* ]]; then VEC_LEN="$2"; shift 2
      else echo "Error: --vec-len requires a numeric argument"; exit 1; fi
      ;;
    --num-rows)
      if [[ -n "${2:-}" && "$2" != --* ]]; then NUM_ROWS="$2"; shift 2
      else echo "Error: --num-rows requires a numeric argument"; exit 1; fi
      ;;
    -h|--help)
      print_help; exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'"; print_help; exit 1
      ;;
  esac
done

# ---- Per-test defaults ----
# If --n-tests was not given, default to 1 for the MAC accelerator test and 5
# otherwise. An explicit --n-tests always wins (it sets N_TESTS non-empty).
if [[ -z "$N_TESTS" ]]; then
  if [[ "$TEST" == "mac_accel" ]]; then N_TESTS=1; else N_TESTS=5; fi
fi

# ---- Validation ----
if [[ "$TB" != "ring" && "$TB" != "standard" ]]; then
  echo "Error: --tb must be 'ring' or 'standard', got '$TB'"; exit 1
fi
if [[ "$SIM" != "verilator" && "$SIM" != "vsim" ]]; then
  echo "Error: --sim must be 'verilator' or 'vsim', got '$SIM'"; exit 1
fi
if [[ "$POSTLAYOUT" -eq 1 && "$SIM" != "vsim" ]]; then
  echo "Error: --postlayout is only supported with --sim vsim"; exit 1
fi
if [[ "$USE_SDF" -eq 1 && "$POSTLAYOUT" -ne 1 ]]; then
  echo "Error: --sdf requires --postlayout (SDF back-annotates the netlist)"; exit 1
fi
for val in "$NUM_NODES" "$N_TESTS" "$VEC_LEN"; do
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; then
    echo "Error: --num-nodes, --n-tests and --vec-len must be positive integers"; exit 1
  fi
done
if [[ -n "$NUM_ROWS" ]]; then
  if ! [[ "$NUM_ROWS" =~ ^[0-9]+$ ]] || [[ "$NUM_ROWS" -lt 1 ]]; then
    echo "Error: --num-rows must be a positive integer"; exit 1
  fi
  if (( NUM_ROWS % NUM_NODES != 0 )); then
    echo "Error: --num-rows ($NUM_ROWS) must be a multiple of --num-nodes ($NUM_NODES)"; exit 1
  fi
fi

# ---- Resolve the SW build and the simulator invocation ----
# MAC build parameters; harmless for tests that don't use them. NUM_ROWS is
# only passed when given, so the Makefile/C default (NUM_NODES * 2) applies.
BUILD_DEFINES="VEC_LEN=${VEC_LEN}"
[[ -n "$NUM_ROWS" ]] && BUILD_DEFINES="${BUILD_DEFINES} NUM_ROWS=${NUM_ROWS}"

if [[ "$TB" == "ring" ]]; then
  MAKE_CMD="make test_${TEST} NUM_NODES=${NUM_NODES} N_TESTS=${N_TESTS} ${BUILD_DEFINES}"
  RUN_TARGET="../sw/bin/test"             # ring TB takes a binary directory;
                                          # node hexes are built into bin/test/
  TEST_NODE_NAME="${TEST}_test_node"      # per-node hex base name
else
  MAKE_CMD="make compile ${BUILD_DEFINES}"
  # Standard TB takes one .hex. Programs from test/*.c build into bin/test/;
  # helloworld (sw root) is the exception and lands directly in bin/.
  if [[ "$TEST" == "helloworld" ]]; then
    RUN_TARGET="../sw/bin/${TEST}.hex"
  else
    RUN_TARGET="../sw/bin/test/${TEST}.hex"
  fi
fi

if [[ "$SIM" == "verilator" ]]; then
  SIM_DIR="verilator"
  FLIST_CMD="./run_verilator.sh --flist"
  if [[ "$TB" == "ring" ]]; then
    RUN_SIM_CMD="./run_verilator.sh --ring --num-nodes ${NUM_NODES} --test-name ${TEST_NODE_NAME} --build --run ${RUN_TARGET}"
  else
    RUN_SIM_CMD="./run_verilator.sh --build --run ${RUN_TARGET}"
  fi
else
  SIM_DIR="vsim"
  FLIST_CMD="./run_vsim.sh --flist"
  BUILD_FLAG="--build"; [[ "$POSTLAYOUT" -eq 1 ]] && BUILD_FLAG="--build-netlist"
  SDF_FLAG="";          [[ "$USE_SDF" -eq 1 ]]    && SDF_FLAG="--sdf"
  if [[ "$TB" == "ring" ]]; then
    RUN_SIM_CMD="./run_vsim.sh --ring --num-nodes ${NUM_NODES} --test-name ${TEST_NODE_NAME} ${SDF_FLAG} ${BUILD_FLAG} --run ${RUN_TARGET}"
  else
    RUN_SIM_CMD="./run_vsim.sh ${SDF_FLAG} ${BUILD_FLAG} --run ${RUN_TARGET}"
  fi
fi

echo "=========================================================="
echo " test       : ${TEST}"
echo " testbench  : ${TB}"
echo " simulator  : ${SIM}$( [[ "$POSTLAYOUT" -eq 1 ]] && echo " (post-layout)" )$( [[ "$USE_SDF" -eq 1 ]] && echo " +sdf" )"
[[ "$TB" == "ring" ]] && echo " nodes      : ${NUM_NODES}   n-tests: ${N_TESTS}"
echo " mac params : vec-len=${VEC_LEN}   num-rows=${NUM_ROWS:-NUM_NODES*2}"
echo " build      : ${MAKE_CMD}"
echo " run        : ${RUN_SIM_CMD}"
echo "=========================================================="

# ---- Workflow ----
#
# Refresh the IHP13 technology setup. This runs regardless of configuration,
# outside oseda, from the repo root (croc-with-ring-bus-IP).
cd "${REPO_ROOT}"
icdesign ihp13 -update all -nogui

# bender and the RISC-V toolchain are ONLY available inside the oseda
# environment, so 'bender update', the SW build, and flist generation (which
# invokes bender) must run inside oseda. QuestaSim (vsim), however, is
# installed OUTSIDE oseda. Verilator is part of oseda. Therefore:
#
#   * --sim verilator : the whole flow runs inside oseda.
#   * --sim vsim      : the flist is generated inside oseda (bender), but the
#                       compile/run of vsim must happen OUTSIDE oseda.
if [[ "$SIM" == "verilator" ]]; then
  oseda ${OSEDA_VERSION} bash <<EOF
set -e
cd ${REPO_ROOT}
bender update
cd ${REPO_ROOT}/sw
make clean
${MAKE_CMD}
cd ${REPO_ROOT}/${SIM_DIR}
${FLIST_CMD}
${RUN_SIM_CMD}
EOF
else
  # Inside oseda: bender update, SW build, and flist generation (uses bender).
  oseda ${OSEDA_VERSION} bash <<EOF
set -e
cd ${REPO_ROOT}
bender update
cd ${REPO_ROOT}/sw
make clean
${MAKE_CMD}
cd ${REPO_ROOT}/${SIM_DIR}
${FLIST_CMD}
EOF

  # Outside oseda: compile and run with QuestaSim, which is not part of oseda.
  cd "${REPO_ROOT}/${SIM_DIR}"
  ${RUN_SIM_CMD}
fi
