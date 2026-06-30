#!/usr/bin/env bash
set -e
# Default values
NUM_NODES=2
N_TESTS=1
VEC_LEN=128
NUM_ROWS_PARAM=""

print_help() {
  echo "Usage: $0 [--num-nodes N] [--n-tests T] [--vec-len V] [--num-rows R]"
  echo ""
  echo "Options:"
  echo "  --num-nodes N   Number of nodes (default: 2)"
  echo "  --n-tests T     Number of tests (default: 1)"
  echo "  --vec-len V     Vector length (default: 128)"
  echo "  --num-rows R    Total number of rows (default: NUM_NODES * 2)"
  echo "  -h, --help      Show this help message"
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --num-nodes)
      NUM_NODES="$2"; shift 2 ;;
    --n-tests)
      N_TESTS="$2"; shift 2 ;;
    --vec-len)
      VEC_LEN="$2"; shift 2 ;;
    --num-rows)
      NUM_ROWS_PARAM="$2"; shift 2 ;;
    -h|--help)
      print_help; exit 0 ;;
    *)
      echo "Error: Unknown argument '$1'"; print_help; exit 1 ;;
  esac
done

# If NUM_ROWS not specified, default to NUM_NODES * 2
if [[ -z "$NUM_ROWS_PARAM" ]]; then
  NUM_ROWS_PARAM=$((NUM_NODES * 2))
fi

# Validation
for val in "$NUM_NODES" "$N_TESTS" "$VEC_LEN" "$NUM_ROWS_PARAM"; do
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 1 ]]; then
    echo "Error: values must be positive integers"
    exit 1
  fi
done

# NUM_ROWS must be a multiple of NUM_NODES
if (( NUM_ROWS_PARAM % NUM_NODES != 0 )); then
  echo "Error: --num-rows ($NUM_ROWS_PARAM) must be a multiple of --num-nodes ($NUM_NODES)"
  exit 1
fi

echo "Running MAC accelerator simulation with NUM_NODES=$NUM_NODES, N_TESTS=$N_TESTS, VEC_LEN=$VEC_LEN, NUM_ROWS=$NUM_ROWS_PARAM"

# --- Workflow inside oseda environment ---
oseda -2025.12 bash <<EOF
set -e
cd ..
bender update
cd sw
make clean
make test_mac_accel NUM_NODES=${NUM_NODES} N_TESTS=${N_TESTS} VEC_LEN=${VEC_LEN} NUM_ROWS=${NUM_ROWS_PARAM}
for i in \$(seq 1 ${NUM_NODES}); do
    ln -sf mac_accel_test_node\${i}.hex bin/serial_link_test_node\${i}.hex
done
cd ../verilator
./run_verilator.sh --flist
if [[ "${NUM_NODES}" -eq 1 ]]; then
    rm -rf obj_dir
    ./run_verilator.sh --build --run ../sw/bin/serial_link_test_node1.hex
else
    ./run_verilator.sh --ring --num-nodes ${NUM_NODES} --build --run ../sw/bin
fi
EOF