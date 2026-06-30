#!/bin/bash
# ---------------------------------------------------------------------------
#  run_power_sweep.sh  —  whole-ring power sweep over node counts 1..14
#
#  Because more nodes finish the workload sooner, the *active compute window*
#  differs for every ring size. The script therefore runs in two passes:
#
#    PASS 1 (probe)   : run each simulation once WITHOUT dumping. The testbench
#                       prints "[PWR_WINDOW] start_ns=.. stop_ns=.." (first core
#                       resume .. all nodes done). These are cached in
#                       results/windows.csv.
#    PASS 2 (measure) : re-run each simulation, this time dumping ONLY that
#                       window (+dump +vcd_start +vcd_dur), then run OpenROAD
#                       stimulus-based power once per node and sum over the ring.
#
#  For each ring size N:
#    NUM_ROWS = ceil(BASE_ROWS / N) * N   (rows divide evenly across the nodes;
#    lands in [64, 72] for BASE_ROWS=64). The MAC test is built with VEC_LEN=64
#    into per-node binaries. These sizes keep each node's W matrix
#    (ROWS_PER_NODE x VEC_LEN x 4 B) within the 22 KB on-chip SRAM for all N
#    (worst case N=1: 64x64x4 = 16 KB, exactly the space above W_MATRIX_BASE).
#
#  Output: results/power_sweep.csv (+ a printed table) with the internal,
#  switching, leakage and total power of the ENTIRE ring per node count.
#
#  Usage:
#      cd power
#      ./run_power_sweep.sh
#
#  Env overrides:
#      NODES="1 2 4 8"      subset of node counts          (default 1..14)
#      VEC_LEN=64           MAC vector length              (default 64)
#      BASE_ROWS=64         base row count to round up      (default 64)
#      PAD_NS=0             extra ns added around the window (default 0)
#      CORNER=tt            tt | ff                        (default tt)
#      FORCE_PROBE=1        redo the probe pass even if windows.csv exists
#      SKIP_BUILD_NETLIST=1 reuse existing vsim/work
#      KEEP_VCD=1           keep each per-N croc_ring.vcd  (default: deleted)
#      VSIM / OPENROAD      tool launch commands
# ---------------------------------------------------------------------------
set -u

# --- locate repo --------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT}"
[ -f env.sh ] && source env.sh

# --- config -------------------------------------------------------------------
NODES="${NODES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14}"
VEC_LEN="${VEC_LEN:-64}"     # matrix-vector length (64x64 ~ 4096-element matrix)
BASE_ROWS="${BASE_ROWS:-64}" # base row count; ceil(64/N)*N lands in [64, 72]
N_TESTS="${N_TESTS:-1}"      # MAC test iterations (simulate.sh uses 1 for mac_accel;
                             # the Makefile default of 5 makes every sim 5x longer)
PAD_NS="${PAD_NS:-0}"
# Cap the VCD dump to a short, representative slice of the compute window.
# Power is a time-average, so a few us of steady-state switching is enough; the
# full 270-440 us windows would produce a huge VCD and a very slow +acc sim.
# Set to 0 to dump the entire probed window.
MAX_VCD_DUR_NS="${MAX_VCD_DUR_NS:-20000}"   # 20 us (~1600 cycles @ 80 MHz)
CORNER="${CORNER:-tt}"
# --- tool environments (see scripts/simulate.sh) ------------------------------
#   * bender, the RISC-V toolchain (SW make) and flist generation: INSIDE oseda
#   * QuestaSim (vsim compile/run):                                 OUTSIDE oseda
#   * OpenROAD (SPEF + power):                                      INSIDE oseda
# IMPORTANT: oseda is fed commands via a heredoc on stdin (exactly like
# simulate.sh). `oseda ... bash -c` / `oseda ... openroad` leave oseda waiting
# on stdin and hang, so always use:  ${OSEDA} bash <<EOF ... EOF
OSEDA="${OSEDA:-oseda -2025.12}"
VSIM="${VSIM:-questa-2023.4 vsim}"          # OUTSIDE oseda
TEST_NAME="mac_accel_test_node"
BIN_DIR_REL="../sw/bin/test"          # relative to vsim/
TB="tb_croc_soc_ring"
VCD="${ROOT}/vsim/croc_ring.vcd"

RESULTS_DIR="${SCRIPT_DIR}/results"
LOG_DIR="${RESULTS_DIR}/logs"
CSV="${RESULTS_DIR}/power_sweep.csv"
WINDOWS="${RESULTS_DIR}/windows.csv"
mkdir -p "${LOG_DIR}"

log() { echo "[power-sweep] $*"; }

# --- helpers ------------------------------------------------------------------
num_rows() { local n="$1"; echo $(( ( (BASE_ROWS + n - 1) / n ) * n )); }

build_sw() {  # $1=N  $2=ROWS  $3=logfile
  # The RISC-V toolchain lives INSIDE oseda. `-D` define changes are not tracked
  # by the make dependencies, so clean first to force a rebuild with the new
  # NUM_NODES / NUM_ROWS / VEC_LEN.  (heredoc on stdin, like simulate.sh)
  ${OSEDA} bash > "$3" 2>&1 <<EOF
set -e
cd ${ROOT}/sw
make clean
make test_mac_accel NUM_NODES=$1 VEC_LEN=${VEC_LEN} NUM_ROWS=$2 N_TESTS=${N_TESTS}
EOF
}

build_netlist() {  # one-time post-layout netlist compile (env-split aware)
  local logf="${LOG_DIR}/compile_netlist.log"; : > "${logf}"
  # IHP tech refresh: OUTSIDE oseda, at the repo root. Off by default (the tech
  # is already set up if you have run sims before); enable with RUN_ICDESIGN=1.
  if [ "${RUN_ICDESIGN:-0}" = "1" ]; then
    log "  icdesign tech refresh (outside oseda)..."
    ( cd "${ROOT}" && icdesign ihp13 -update all -nogui ) >> "${logf}" 2>&1 \
        || log "  WARN: icdesign step failed (continuing)"
  fi
  # bender update + flist generation use bender: INSIDE oseda (heredoc).
  log "  bender update + flist generation (inside oseda)..."
  if ! ${OSEDA} bash >> "${logf}" 2>&1 <<EOF
set -e
cd ${ROOT}
bender update
cd ${ROOT}/vsim
./run_vsim.sh --flist
EOF
  then
    log "ERROR: flist generation failed (see ${logf})"; return 1
  fi
  # QuestaSim compile of the netlist: OUTSIDE oseda.
  log "  QuestaSim netlist compile (outside oseda)..."
  ( cd "${ROOT}/vsim" && ./run_vsim.sh --build-netlist ) >> "${logf}" 2>&1 \
      || { log "ERROR: netlist compile failed (see ${logf})"; return 1; }
}

# Run an OpenROAD Tcl inside oseda (heredoc on stdin). $1=tcl path relative to
# openroad/, $2=logfile.
run_openroad() {
  ${OSEDA} bash > "$2" 2>&1 <<EOF
cd ${ROOT}/openroad
openroad -exit $1
EOF
}

run_sim() {  # $1=N  $2=extra vsim args  $3=logfile   (QuestaSim: OUTSIDE oseda)
  ( cd vsim && ${VSIM} \
        +bin_dir="${BIN_DIR_REL}" \
        +test_name="${TEST_NAME}" \
        -gNumNodes="$1" \
        $2 \
        -c "${TB}" -t 10ps \
        -suppress vsim-3009 -suppress vsim-8683 \
        -suppress vsim-8386 -suppress vsim-3819 \
        -do "run -a; quit" ) > "$3" 2>&1
}

parse_window() {  # $1=simlog -> "start_ns stop_ns" (0 0 if absent)
  awk -F'[= ]+' '/\[PWR_WINDOW\]/{
        for (i=1;i<=NF;i++){ if($i=="start_ns")s=$(i+1); if($i=="stop_ns")e=$(i+1) } }
      END{ printf "%d %d", s+0, e+0 }' "$1"
}

# --- one-time: compile the post-layout netlist --------------------------------
if [ "${SKIP_BUILD_NETLIST:-0}" != "1" ]; then
  log "Compiling post-layout netlist (flist inside oseda, vsim outside)..."
  build_netlist || exit 1
fi

# --- one-time: generate the SPEF (best effort; power falls back to ODB) -------
if [ ! -f openroad/out/croc.spef ]; then
  log "Generating out/croc.spef ..."
  run_openroad "../power/gen_spef.tcl" "${LOG_DIR}/gen_spef.log" || true
  [ -f openroad/out/croc.spef ] && log "SPEF ready." \
      || log "No SPEF produced; power runs will estimate from the routed ODB."
fi

# =============================================================================
#  PASS 1 — PROBE: find each ring size's active compute window
# =============================================================================
if [ "${FORCE_PROBE:-0}" = "1" ] || [ ! -f "${WINDOWS}" ]; then
  log "############ PASS 1: probing VCD windows ############"
  echo "NumNodes,start_ns,stop_ns" > "${WINDOWS}"
  for N in ${NODES}; do
    ROWS=$(num_rows "${N}")
    log "probe N=${N} (NUM_ROWS=${ROWS})"
    build_sw "${N}" "${ROWS}" "${LOG_DIR}/sw_N${N}.log" \
      || { log "  ERROR: SW build failed (see ${LOG_DIR}/sw_N${N}.log)"; continue; }
    run_sim "${N}" "" "${LOG_DIR}/probe_N${N}.log"
    read -r S E < <(parse_window "${LOG_DIR}/probe_N${N}.log")
    if [ "${E}" -le "${S}" ] || [ "${E}" -le 0 ]; then
      log "  WARN: no valid [PWR_WINDOW] (start=${S} stop=${E}); will dump whole run"
      S=0; E=0
    else
      log "  window: start=${S} ns  stop=${E} ns  (dur=$((E-S)) ns)"
    fi
    echo "${N},${S},${E}" >> "${WINDOWS}"
  done
else
  log "Reusing cached windows from ${WINDOWS} (set FORCE_PROBE=1 to redo)"
fi

# load windows into assoc arrays
declare -A WIN_START WIN_STOP
while IFS=, read -r n s e; do
  [ "${n}" = "NumNodes" ] && continue
  WIN_START["${n}"]="${s}"; WIN_STOP["${n}"]="${e}"
done < "${WINDOWS}"

# =============================================================================
#  PASS 2 — MEASURE: dump the window, run power per node, sum over the ring
# =============================================================================
log "############ PASS 2: measuring power ############"
echo "NumNodes,NumRows,RowsPerNode,Internal_W,Switching_W,Leakage_W,Total_W" > "${CSV}"

for N in ${NODES}; do
  ROWS=$(num_rows "${N}")
  RPN=$(( ROWS / N ))
  S="${WIN_START[${N}]:-0}"; E="${WIN_STOP[${N}]:-0}"

  # derive the dump window (with optional padding); 0/0 => whole run.
  # Cap the duration to MAX_VCD_DUR_NS so the VCD stays small and the +acc sim
  # stops shortly after the window (the testbench $finish-es when the dump ends).
  if [ "${E}" -gt "${S}" ] && [ "${E}" -gt 0 ]; then
    START=$(( S - PAD_NS )); [ "${START}" -lt 0 ] && START=0
    DUR=$(( E - START + PAD_NS ))
    if [ "${MAX_VCD_DUR_NS}" -gt 0 ] && [ "${DUR}" -gt "${MAX_VCD_DUR_NS}" ]; then
      DUR=${MAX_VCD_DUR_NS}
    fi
  else
    START=0; DUR=0
  fi
  log "============================================================"
  log "N=${N} | NUM_ROWS=${ROWS} | rows/node=${RPN} | window [${START}, $((START+DUR))] ns"

  build_sw "${N}" "${ROWS}" "${LOG_DIR}/sw_N${N}.log" \
    || { log "  ERROR: SW build failed"; continue; }

  log "  simulating + dumping windowed VCD..."
  run_sim "${N}" "+dump +vcd_start=${START} +vcd_dur=${DUR} -voptargs=+acc" \
          "${LOG_DIR}/sim_N${N}.log"
  if [ ! -s "${VCD}" ]; then
    log "  ERROR: no VCD for N=${N} (see ${LOG_DIR}/sim_N${N}.log)"; continue
  fi

  # power per node, accumulated over the ring
  PERNODE="${LOG_DIR}/pernode_N${N}.txt"; : > "${PERNODE}"
  for (( n = 0; n < N; n++ )); do
    SCOPE="${TB}/gen_nodes[${n}]/i_croc_chip"
    PRE="${ROOT}/openroad/.pwr_run.tcl"
    {
      printf 'set pwr_vcd {%s}\n'    "${VCD}"
      printf 'set pwr_scope {%s}\n'  "${SCOPE}"
      printf 'set pwr_corner {%s}\n' "${CORNER}"
      printf 'source ../power/report_power_ring.tcl\n'
    } > "${PRE}"

    OLOG="${LOG_DIR}/power_N${N}_node${n}.log"
    run_openroad ".pwr_run.tcl" "${OLOG}"

    read -r I S2 L T < <(awk '
      /PWR_SCOPE_BEGIN/{f=1}
      f && /^Total[ \t]+[0-9.eE+-]+/{print $2, $3, $4, $5; f=0}' "${OLOG}")
    if [ -z "${T:-}" ]; then
      log "  WARN: could not parse power for node ${n} (see ${OLOG})"; continue
    fi
    log "  node ${n}: int=${I} sw=${S2} leak=${L} total=${T} W"
    echo "${I} ${S2} ${L} ${T}" >> "${PERNODE}"
  done
  rm -f "${ROOT}/openroad/.pwr_run.tcl"
  [ "${KEEP_VCD:-0}" = "1" ] || rm -f "${VCD}"

  # sum over the ring
  read -r RI RS RL RT < <(awk '
    {i+=$1; s+=$2; l+=$3; t+=$4}
    END{ if (NR>0) printf "%.6e %.6e %.6e %.6e", i, s, l, t }' "${PERNODE}")
  if [ -z "${RT:-}" ]; then
    log "  WARN: no per-node power collected for N=${N}"; continue
  fi
  log "  RING total: int=${RI} sw=${RS} leak=${RL} total=${RT} W"
  echo "${N},${ROWS},${RPN},${RI},${RS},${RL},${RT}" >> "${CSV}"
done

# --- summary ------------------------------------------------------------------
log "============================================================"
log "Done. Windows: ${WINDOWS}"
log "      Results: ${CSV}"
echo
if command -v column >/dev/null 2>&1; then
  column -t -s, "${CSV}"
else
  cat "${CSV}"
fi
