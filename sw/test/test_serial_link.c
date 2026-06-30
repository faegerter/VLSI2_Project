// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Fabian Aegerter         <faegerter@ethz.ch>
// Llorenç Muela Hausmann  <lmuela@ethz.ch>


#include "util.h"
#include "serial_link.h"
#include "config.h"


#ifndef NUM_NODES
#define NUM_NODES 3
#endif

#ifndef NODE_ID
#error "NODE_ID not defined"
#endif

#if NUM_NODES < 2 || NUM_NODES > 15
#error "NUM_NODES must be between 2 and 15"
#endif

#if NODE_ID < 1 || NODE_ID > NUM_NODES
#error "NODE_ID must be in range [1, NUM_NODES]"
#endif

#ifndef N_TESTS
#define N_TESTS 5
#endif

#define SLINK_TX_CLK_DIV_4_START 1
#define SLINK_TX_CLK_DIV_4_END 3

#define STOP_NODE_TX 1
#define START_NODE_TX 0

#define ADDR_DEST_SHIFT  28U

#define TEST_ADDR(dst, src, j) (((uint32_t)(dst) << ADDR_DEST_SHIFT) | (SRAM_BANK_1_BASE_ADDR) + ((uint32_t)(src-1) * N_TESTS + (uint32_t)(j))*4U)

#define TEST_DATA(src, dst, j) ((uint32_t)((src) << 16 | (dst) << 8 | (j)))

#define GLOBAL_ADDRESS_START 0XF

void set_tx_clk_div(uint32_t clk_div, uint32_t clk_start, uint32_t clk_end){
    slink_set_ctrl_reg(STOP_NODE_TX); 
    slink_set_tx_clk_div(clk_div);
    slink_set_tx_clk_start(clk_start);
    slink_set_tx_clk_end(clk_end);
    slink_set_ctrl_reg(START_NODE_TX);
}


int main() {
    slink_set_node_id(NODE_ID);
    
    if(slink_get_node_id() != NODE_ID){
        return 1;
    }

    uint32_t new_clk_div = 4;
    set_tx_clk_div(new_clk_div, SLINK_TX_CLK_DIV_4_START, SLINK_TX_CLK_DIV_4_END);

    uint32_t compare_data[NUM_NODES-1][N_TESTS];

    uint32_t i_idx = 0;;
    for(int i = 1; i <= NUM_NODES; i++){ 
        if(i == NODE_ID){
            continue;
        }
        for(int j = 0; j < N_TESTS; j++){
            uint32_t addr = TEST_ADDR(i, NODE_ID, j);
            uint32_t data = TEST_DATA(NODE_ID, i, j);
            slink_send_data(addr, data);
            compare_data[i_idx][j] = data; 
        }
        i_idx++;
    }
    
    i_idx = 0;
    uint32_t errors = 0;

    for(int i = 1; i <= NUM_NODES; i++){
        if(i == NODE_ID){
            continue;
        }
        for(int j = 0; j < N_TESTS; j++){
            uint32_t addr = TEST_ADDR(i, NODE_ID, j);
            if(slink_read_data(addr) != compare_data[i_idx][j]){
                errors++;
            }
        }
        i_idx++;
    }

    uint32_t addr = TEST_ADDR(GLOBAL_ADDRESS_START, NODE_ID, N_TESTS);
    uint32_t data = TEST_DATA(NODE_ID, NUM_NODES, N_TESTS);
    
    i_idx = 0;

    slink_send_data(addr, data);

    for(int i = 1; i <= NUM_NODES; i++){
        if(i == NODE_ID){
            continue;
        }
        addr = TEST_ADDR(i, NODE_ID, N_TESTS);
        if(slink_read_data(addr) != data){
            errors++;
        }
        i_idx++;
    }

    if(errors > 0){ 
        return ((errors+1)>>2); //Due to testbench and JTAG configuration. Outputs the correct error value in the testbench.
    }

    return 0;
}

