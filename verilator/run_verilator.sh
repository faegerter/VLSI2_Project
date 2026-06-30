#!/bin/bash
# Copyright (c) 2024 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Authors:
# - Thomas Benz     <tbenz@iis.ee.ethz.ch>

set -e  # Exit on error
set -u  # Error on undefined vars


################
# Setup
################
# Source environment
source "../env.sh"


################
# Defaults
################
TESTBENCH="tb_croc_soc"
NUM_NODES=3
TEST_NAME="serial_link_test_node"


################
# Helpers
################

show_help() {
    cat << EOF
Verilator Coordinator

Usage:
    ./run_verilator.sh [OPTIONS]

Options:
    --help, -h          Show this help message
    --dry-run, -n       Only print commands instead of executing
    --verbose, -v       Print commands while executing
    --ring              Use the multi-node ring testbench (tb_croc_soc_ring)
    --num-nodes N       Number of nodes for the ring testbench (default: 3,
                        only used with --ring)
    --test-name NAME    Ring mode: per-node program base name; each node loads
                        <NAME><NODE_ID>.hex from the binary directory
                        (default: serial_link_test_node, only used with --ring)
    --flist             Regenerate flist (croc.f)
    --build             Build croc_soc Verilator binary
    --run BINARY|DIR    Single-node: path to .hex binary
                        Ring mode:   path to binary directory (e.g. ../sw/bin)

Example:
    # Build and run single-node simulation
    ./run_verilator.sh --build --run ../sw/bin/helloworld.hex

    # Build and run 4-node ring simulation (serial-link test)
    ./run_verilator.sh --ring --num-nodes 4 --build --run ../sw/bin

    # Run the MAC accelerator ring test instead
    ./run_verilator.sh --ring --num-nodes 4 --test-name mac_accel_test_node --run ../sw/bin

EOF
    exit 0
}


run_cmd() {
    if [ "$DRYRUN" = 1 ]; then
        echo "$1"
    else
        eval "$1"
    fi
}


build_verilator() {
    # After:
    if [ "$TESTBENCH" = "tb_croc_soc_ring" ]; then
        run_cmd "echo [INFO][Verilator] Building testbench: ${TESTBENCH} \(NumNodes=${NUM_NODES}\)"
    else
        run_cmd "echo [INFO][Verilator] Building testbench: ${TESTBENCH}"
    fi
    # -GNumNodes is only meaningful for the ring testbench but is harmless
    # to pass for the single-node one (it simply has no such parameter).
    run_cmd "verilator \
        -Wno-fatal \
        -Wno-style \
        -Wno-BLKANDNBLK \
        -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC \
        -Wno-WIDTHCONCAT \
        -Wno-ASCRANGE \
        --binary \
        -j 0 \
        --timing \
        --autoflush \
        --trace-fst \
        --trace-threads 2 \
        --trace-structs \
        --unroll-count 1 \
        --unroll-stmts 1 \
        --x-assign fast \
        --x-initial fast \
        -O3 \
        --top ${TESTBENCH} \
        $( [ "$TESTBENCH" = "tb_croc_soc_ring" ] && echo "-GNumNodes=${NUM_NODES}" ) \
        -f croc.f 2>&1 | \
        tee ${PROJ_NAME}_build.log"
}


generate_flist() {
    run_cmd "echo [INFO][Bender] Generate croc.f"
    run_cmd "bender \
        script flist-plus \
        -t rtl \
        -t verilator \
        -t synthesis \
        -D VERILATOR=1 \
        -D COMMON_CELLS_ASSERTS_OFF=1 \
        > croc.f"

    run_cmd "echo [INFO][Bender] Remove absolute paths"
    run_cmd "sed -i 's|${CROC_ROOT}|..|g' croc.f"

    run_cmd "echo [INFO][Bender] File list generated: croc.f"
}


run_binary() {
    if [ "$TESTBENCH" = "tb_croc_soc_ring" ]; then
        # Ring mode: argument is a binary directory, not a single file.
        # The testbench reads +bin_dir and constructs per-node paths itself.
        run_cmd "echo [INFO][Verilator] Running ring simulation \(${NUM_NODES} nodes, program ${TEST_NAME}\) from $1"
        run_cmd "obj_dir/V${TESTBENCH} +bin_dir=\"$1\" +test_name=\"${TEST_NAME}\" | tee ${PROJ_NAME}.log"
    else
        # Single-node mode: argument is a .hex file path.
        run_cmd "echo [INFO][Verilator] Running $1"
        run_cmd "obj_dir/V${TESTBENCH} +binary=\"$1\" | tee ${PROJ_NAME}.log"
    fi
}


####################
# Parse Arguments
####################

DRYRUN=0

# default action if no argument is given
if [ $# -eq 0 ]; then
    show_help
    return 0
fi

# check for global arguments first (these don't consume positional args)
for arg in "$@"; do
    [[ "$arg" == -v || "$arg" == --verbose ]] && set -x
    [[ "$arg" == -n || "$arg" == --dry-run ]] && DRYRUN=1
done

# parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)
            show_help
            ;;
        --verbose|-v)
            shift
            ;;
        --dry-run|-n)
            shift
            ;;
        --ring)
            TESTBENCH="tb_croc_soc_ring"
            shift
            ;;
        --num-nodes)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "[ERROR] --num-nodes requires a value (e.g. --num-nodes 4)" >&2
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]] || (( $2 < 2 || $2 > 15 )); then
                echo "[ERROR] --num-nodes must be an integer in [2, 15], got '$2'" >&2
                exit 1
            fi
            NUM_NODES=$2
            shift 2
            ;;
        --test-name)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "[ERROR] --test-name requires a value (e.g. --test-name mac_accel_test_node)" >&2
                exit 1
            fi
            TEST_NAME=$2
            shift 2
            ;;
        # script-specific commands
        --flist)
            generate_flist
            shift
            ;;
        --build)
            build_verilator
            shift
            ;;
        --run)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "[ERROR] --run requires a path argument" >&2
                exit 1
            fi
            run_binary "$2"
            shift 2
            ;;
        # Error handling
        *)
            echo "[ERROR] Unknown option: $1 (use --help for usage)" >&2
            exit 1
            ;;
    esac
done