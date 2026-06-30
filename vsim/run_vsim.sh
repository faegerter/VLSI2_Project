#!/bin/bash
# Copyright (c) 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Published with permission from Siemens. 
# Siemens QuestaSim is available through EDA Higher Education Software Program
# https://www.sw.siemens.com/en-US/academic/educators/eda-higher-education-software/
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

VSIM=${VSIM:-questa-2023.4 vsim}

mkdir -p reports

################
# Defaults
################
TESTBENCH="tb_croc_soc"
NUM_NODES=3
TEST_NAME="serial_link_test_node"
USE_SDF=0
SDF_FILE="../openroad/out/croc.sdf"

################
# Helpers
################

show_help() {
    cat << EOF
VSIM Coordinator

Usage:
    ./run_vsim.sh [OPTIONS]

Options:
    --help, -h          Show this help message
    --dry-run, -n       Only print commands instead of executing
    --verbose, -v       Print commands while executing
    --ring              Use the multi-node ring testbench (tb_croc_soc_ring)
    --num-nodes N       Number of ring nodes (default: 3, only used with --ring)
    --test-name NAME    Ring mode: per-node program base name; each node loads
                        <NAME><NODE_ID>.hex from the binary directory
                        (default: serial_link_test_node, only used with --ring)
    --sdf               Back-annotate SDF timing (../openroad/out/croc.sdf) per node
    --flist             Regenerate compile scripts (compile_rtl.tcl, compile_netlist.tcl)
    --build             Compile Croc RTL in VSIM
    --build-netlist     Compile Croc netlist (post-layout) in VSIM
    --run BINARY|DIR    Single-node: path to .hex binary
                        Ring mode:   path to binary directory (e.g. ../sw/bin)
    --run-gui BINARY|DIR  Same as --run but open the GUI

Example:
    # Build and run RTL simulation with given binary (CLI mode)
    ./run_vsim.sh --build --run ../sw/bin/helloworld.hex

    # Build and run a 4-node post-layout serial-link ring (netlist) simulation
    ./run_vsim.sh --ring --num-nodes 4 --build-netlist --run-gui ../sw/bin

    # Run the MAC accelerator ring test instead
    ./run_vsim.sh --ring --num-nodes 4 --test-name mac_accel_test_node --run ../sw/bin

EOF
    exit 0
}


run_cmd() {
    if [ "$DRYRUN" = 1 ]; then
        echo $1
    else
        eval $1
    fi
}


generate_rtl_flist() {
    run_cmd "echo [INFO][Bender] Generate compile_rtl.tcl"
    run_cmd "bender \
        script vsim \
        -t rtl \
        -t vsim \
        -t simulation \
        -t verilator \
        -DSYNTHESIS \
        -DSIMULATION \
        --vlog-arg=-svinputport=compat \
        > compile_rtl.tcl"

    run_cmd "echo [INFO][Bender] Remove absolute paths"
    run_cmd "sed -i 's|${CROC_ROOT}|..|g' compile_rtl.tcl"

    run_cmd "echo [INFO][Bender] File list generated: compile_rtl.tcl"
}


generate_netlist_flist() {
    run_cmd "echo [INFO][Bender] Generate compile_netlist.tcl"
    run_cmd "bender \
        script vsim \
        -t ihp13 \
        -t vsim \
        -t simulation \
        -t verilator \
        -t netlist_pnr \
        -DSYNTHESIS \
        -DSIMULATION \
        --vlog-arg=-svinputport=compat \
        > compile_netlist.tcl"

    run_cmd "echo [INFO][Bender] Remove absolute paths"
    run_cmd "sed -i 's|${CROC_ROOT}|..|g' compile_netlist.tcl"

    run_cmd "echo [INFO][Bender] File list generated: compile_netlist.tcl"
}


compile_rtl() {
    run_cmd "echo [INFO][VSIM] Compile"
    run_cmd "${VSIM} \
        -c \
        -do \"source compile_rtl.tcl; exit\" \
        > reports/compile_rtl.log"

    # Collect errors and warnings from compilation log and print summary
    run_cmd "echo [INFO][VSIM] Check reports/compile_rtl.log"
    run_cmd "echo --- QuestaSim compilation report ---  > reports/compile_rtl.rpt"
    run_cmd "echo Errors:                              >> reports/compile_rtl.rpt"
    run_cmd "grep Error: reports/compile_rtl.log       >> reports/compile_rtl.rpt || true"
    run_cmd "echo                                      >> reports/compile_rtl.rpt"
    run_cmd "echo Warnings:                            >> reports/compile_rtl.rpt"
    run_cmd "grep Warning: reports/compile_rtl.log     >> reports/compile_rtl.rpt || true"

    run_cmd "NUM_ERRORS=$(cat reports/compile_rtl.rpt | grep Error: | wc -l)"
    run_cmd "NUM_WARNINGS=$(cat reports/compile_rtl.rpt | grep Warning: | wc -l)"
    run_cmd "echo \"#######################################################\""
    run_cmd "echo \"############### Compilation report ####################\""
    run_cmd "echo \"#######################################################\""
    run_cmd "echo  Errors   : ${NUM_ERRORS}"
    run_cmd "echo  Warnings : ${NUM_WARNINGS}"
    run_cmd "echo See 'reports/compile_rtl.rpt' for more info"
    run_cmd "echo \"#######################################################\""
}


compile_netlist() {
    run_cmd "echo [INFO][VSIM] Compile post-synthesis netlist"
    run_cmd "${VSIM} \
        -c \
        -do \"source compile_netlist.tcl; source compile_tech.tcl; exit\" \
        > reports/compile_netlist.log"

    # Collect errors and warnings from compilation log and print summary
    run_cmd "echo [INFO][VSIM] Check reports/compile_netlist.log"
    run_cmd "echo --- QuestaSim compilation report ---  > reports/compile_netlist.rpt"
    run_cmd "echo Errors:                              >> reports/compile_netlist.rpt"
    run_cmd "grep Error: reports/compile_netlist.log       >> reports/compile_netlist.rpt || true"
    run_cmd "echo                                      >> reports/compile_netlist.rpt"
    run_cmd "echo Warnings:                            >> reports/compile_netlist.rpt"
    run_cmd "grep Warning: reports/compile_netlist.log     >> reports/compile_netlist.rpt || true"

    run_cmd "NUM_ERRORS=$(cat reports/compile_netlist.rpt | grep Error: | wc -l)"
    run_cmd "NUM_WARNINGS=$(cat reports/compile_netlist.rpt | grep Warning: | wc -l)"
    run_cmd "echo \"#######################################################\""
    run_cmd "echo \"############### Compilation report ####################\""
    run_cmd "echo \"#######################################################\""
    run_cmd "echo  Errors   : ${NUM_ERRORS}"
    run_cmd "echo  Warnings : ${NUM_WARNINGS}"
    run_cmd "echo See 'reports/compile_netlist.rpt' for more info"
    run_cmd "echo \"#######################################################\""
}


# Build the per-node SDF back-annotation arguments for the ring testbench.
# Each node's chip instance (gen_nodes[i]/i_croc_chip) gets the same croc.sdf.
# -sdfnoerror downgrades instance/cell mismatches to warnings instead of aborting.
build_sdf_args() {
    local args="-sdfnoerror"
    local n
    for (( n = 0; n < NUM_NODES; n++ )); do
        args="${args} -sdfmax /${TESTBENCH}/gen_nodes[${n}]/i_croc_chip=${SDF_FILE}"
    done
    printf '%s' "$args"
}


# $1 = .hex binary (single-node) or binary directory (ring mode).
# In ring mode the testbench reads +bin_dir and builds per-node paths itself,
# and NumNodes is overridden on the elaboration command line.
run_vsim() {
    local sdf=""
    [ "$USE_SDF" = 1 ] && [ "$TESTBENCH" = "tb_croc_soc_ring" ] && sdf=$(build_sdf_args)
    # With SDF, $setup/$hold checks fire where data that originated in the
    # asynchronous serial-link RX clock domain (ddr_rcv_clk_i, sourced from the
    # neighbour node) is captured into clk_i at the slink->crossbar boundary
    # (e.g. i_slink_mgr_obi_cut). STA treats the link RX clock as async, so
    # these are not real timing failures. Disable the timing checks while
    # keeping the SDF delays (functional gate-level sim; timing sign-off = STA).
    local notc=""
    [ "$USE_SDF" = 1 ] && notc="+notimingchecks"
    if [ "$TESTBENCH" = "tb_croc_soc_ring" ]; then
        run_cmd "${VSIM} \
            +bin_dir=$1 \
            +test_name=${TEST_NAME} \
            -gNumNodes=${NUM_NODES} \
            ${sdf} \
            ${notc} \
            -c \
            ${TESTBENCH} \
            -t 10ps \
            -suppress vsim-3009 \
            -suppress vsim-8683 \
            -suppress vsim-8386 \
            -suppress vsim-3819 \
            -do \"run -a; quit\""
    else
        run_cmd "${VSIM} \
            +binary=$1 \
            ${notc} \
            -c \
            ${TESTBENCH} \
            -t 10ps \
            -suppress vsim-3009 \
            -suppress vsim-8683 \
            -suppress vsim-8386 \
            -suppress vsim-3819 \
            -do \"run -a; quit\""
    fi
}


run_vsim_gui() {
    local sdf=""
    [ "$USE_SDF" = 1 ] && [ "$TESTBENCH" = "tb_croc_soc_ring" ] && sdf=$(build_sdf_args)
    # See run_vsim(): disable async-crossing timing checks under SDF.
    local notc=""
    [ "$USE_SDF" = 1 ] && notc="+notimingchecks"
    if [ "$TESTBENCH" = "tb_croc_soc_ring" ]; then
        run_cmd "${VSIM} \
            +bin_dir=$1 \
            +test_name=${TEST_NAME} \
            -gNumNodes=${NUM_NODES} \
            ${sdf} \
            ${notc} \
            -gui \
            ${TESTBENCH} \
            -t 10ps \
            -voptargs=+acc \
            -suppress vsim-3009 \
            -suppress vsim-8683 \
            -suppress vsim-8386 \
            -suppress vsim-3819"
    else
        run_cmd "${VSIM} \
            +binary=$1 \
            ${notc} \
            -gui \
            ${TESTBENCH} \
            -t 10ps \
            -voptargs=+acc \
            -suppress vsim-3009 \
            -suppress vsim-8683 \
            -suppress vsim-8386 \
            -suppress vsim-3819"
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

# check for global arguments
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
        --sdf)
            USE_SDF=1
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
            generate_rtl_flist
            generate_netlist_flist
            shift
            ;;
        --build)
            compile_rtl
            shift
            ;;
        --build-netlist)
            compile_netlist
            shift
            ;;
        --run)
            run_vsim $2
            shift 2
            ;;
        --run-gui)
            run_vsim_gui $2
            shift 2
            ;;
        # Error handling
        *)
            echo "[ERROR] Unknown option: $1 (use --help for usage)" >&2
            exit 1
            ;;
    esac
done
