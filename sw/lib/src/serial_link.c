// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Fabian Aegerter         <faegerter@ethz.ch>
// Llorenç Muela Hausmann  <lmuela@ethz.ch>

#include "serial_link.h"
#include "util.h"
#include "config.h"



void slink_set_node_id(uint32_t id){
    *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_NODE_ID_REG_OFFSET) = id;
}

uint32_t slink_get_node_id(){
    return *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_NODE_ID_REG_OFFSET);
}


void slink_set_ctrl_reg(uint32_t toggle_send){
    *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_CTRL_REG_OFFSET) = toggle_send;
}

uint32_t slink_get_ctrl_reg(){
    return *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_CTRL_REG_OFFSET);
}

uint32_t slink_get_err_reg(){
    return *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_ERROR_REG_OFFSET);
}

void slink_set_global_addr(uint32_t address){
    *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_GLOBAL_ADDR_REG_OFFSET) = address;
}

uint32_t slink_get_global_addr(){
    return *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_GLOBAL_ADDR_REG_OFFSET);
}

void slink_set_tx_clk_div(uint32_t clk_div){
    *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_TX_PHY_CLK_DIV_0_REG_OFFSET) = clk_div;
}

uint32_t slink_get_tx_clk_div(){
    return *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_TX_PHY_CLK_DIV_0_REG_OFFSET);
}

void slink_set_tx_clk_start(uint32_t clk_start){
    *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_TX_PHY_CLK_START_0_REG_OFFSET) = clk_start;
}

uint32_t slink_get_tx_clk_start(){
    return *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_TX_PHY_CLK_START_0_REG_OFFSET);
}

void slink_set_tx_clk_end(uint32_t clk_end){
    *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_TX_PHY_CLK_END_0_REG_OFFSET) = clk_end;
}

uint32_t slink_get_tx_clk_end(){
    return *reg32(SLINK_CFG_BASE_ADDR, SLINK_REG_TX_PHY_CLK_END_0_REG_OFFSET);
}

void slink_send_data(uint32_t address, uint32_t data){
    *reg32(address, 0) = data;
}

uint32_t slink_read_data(uint32_t address){
    return *reg32(address, 0);
}