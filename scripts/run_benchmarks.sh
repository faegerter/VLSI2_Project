#!/usr/bin/env bash
set -e
# ---------------------------------------------------------------------------
# run_benchmarks.sh
# Runs a series of MAC accelerator simulations and extracts cycle counts.
# Usage: ./run_benchmarks.sh [--config "nodes rows veclen" ...] [--output FILE]
# ---------------------------------------------------------------------------
OUTPUT_FILE="benchmark_results.txt"
CONFIGS=()
print_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --config 'N_NODES NUM_ROWS VEC_LEN'   Add a test configuration (repeatable)"
  echo "  --output FILE                          Output file (default: benchmark_results.txt)"
  echo "  -h, --help                             Show this help"
  echo ""
  echo "Example:"
  echo "  $0 --config '2 8 64' --config '4 16 128' --config '8 32 256'"
}
# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIGS+=("$2")
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Error: Unknown argument '$1'"
      print_help
      exit 1
      ;;
  esac
done
if [[ ${#CONFIGS[@]} -eq 0 ]]; then
  echo "Error: No configurations specified. Use --config 'N_NODES NUM_ROWS VEC_LEN'"
  print_help
  exit 1
fi
# Initialize output file with tab-separated header (paste-ready for Excel)
printf "N_NODES\tNUM_ROWS\tVEC_LEN\tCYCLE_DIFF\n" > "$OUTPUT_FILE"
# Run each configuration
for cfg in "${CONFIGS[@]}"; do
  read -r N_NODES NUM_ROWS VEC_LEN <<< "$cfg"
  # Validate
  for val in "$N_NODES" "$NUM_ROWS" "$VEC_LEN"; do
    if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; then
      echo "Error: Invalid config values in '$cfg' — must be positive integers"
      exit 1
    fi
  done
  echo ""
  echo "============================================================"
  echo " Running: N_NODES=$N_NODES  NUM_ROWS=$NUM_ROWS  VEC_LEN=$VEC_LEN  N_TESTS=10"
  echo "============================================================"
  # Patch VEC_LEN and NUM_ROWS into the C source before building.
  # mac_simulate.sh calls 'make' which picks up NUM_NODES and N_TESTS,
  # but VEC_LEN and NUM_ROWS are #defines in the C file — so we pass them
  # as extra CFLAGS via the environment.
  export EXTRA_CFLAGS="-DVEC_LEN=${VEC_LEN} -DNUM_ROWS_OVERRIDE=${NUM_ROWS}"
  # Capture full simulation output
  SIM_OUTPUT=$(bash mac_simulate.sh \
    --num-nodes "$N_NODES" \
    --n-tests 10 \
    --vec-len "$VEC_LEN" \
    --num-rows "$NUM_ROWS" \
    2>&1) || {
      echo "  [WARNING] Simulation failed for config: $cfg"
      printf "%s\t%s\t%s\tFAILED\n" "$N_NODES" "$NUM_ROWS" "$VEC_LEN" >> "$OUTPUT_FILE"
      continue
  }
  # Extract cycle difference from the TIMING line:
  # Example: [TIMING] start=13539 cycles, end=47469 cycles difference= 33930
  CYCLE_DIFF=$(echo "$SIM_OUTPUT" | \
    grep -oP '\[TIMING\].*difference=\s*\K[0-9]+' | \
    tail -1)
  if [[ -z "$CYCLE_DIFF" ]]; then
    echo "  [WARNING] Could not extract cycle count from output"
    printf "%s\t%s\t%s\tNO_TIMING_FOUND\n" "$N_NODES" "$NUM_ROWS" "$VEC_LEN" >> "$OUTPUT_FILE"
  else
    echo "  -> Cycle difference: $CYCLE_DIFF"
    printf "%s\t%s\t%s\t%s\n" "$N_NODES" "$NUM_ROWS" "$VEC_LEN" "$CYCLE_DIFF" >> "$OUTPUT_FILE"
  fi
done
echo ""
echo "============================================================"
echo " Benchmark complete. Results saved to: $OUTPUT_FILE"
echo "============================================================"
cat "$OUTPUT_FILE"