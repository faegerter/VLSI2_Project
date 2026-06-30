// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Fabian Aegerter         <faegerter@ethz.ch>
// Llorenç Muela Hausmann  <lmuela@ethz.ch>

#pragma once

#include <stdint.h>
#include "config.h"


#define SLINK_REG_CTRL_REG_OFFSET                        0x000
#define SLINK_REG_ERROR_REG_OFFSET                       0x004
#define SLINK_REG_NODE_ID_REG_OFFSET                     0x008
#define SLINK_REG_GLOBAL_ADDR_REG_OFFSET                 0x00C
#define SLINK_REG_RAW_MODE_EN_REG_OFFSET                 0x010
#define SLINK_REG_RAW_MODE_IN_DATA_REG_OFFSET            0x014
#define SLINK_REG_RAW_MODE_IN_CH_SEL_REG_OFFSET          0x018
#define SLINK_REG_RAW_MODE_OUT_DATA_FIFO_REG_OFFSET      0x01C
#define SLINK_REG_RAW_MODE_OUT_DATA_FIFO_CTRL_REG_OFFSET 0x020
#define SLINK_REG_RAW_MODE_OUT_EN_REG_OFFSET             0x024
#define SLINK_REG_FLOW_CONTROL_FIFO_CLEAR_REG_OFFSET     0x028
#define SLINK_REG_RAW_MODE_IN_DATA_VALID_0_REG_OFFSET    0x100
#define SLINK_REG_RAW_MODE_OUT_CH_MASK_0_REG_OFFSET      0x200
#define SLINK_REG_TX_PHY_CLK_DIV_0_REG_OFFSET            0x300
#define SLINK_REG_TX_PHY_CLK_START_0_REG_OFFSET          0x400
#define SLINK_REG_TX_PHY_CLK_END_0_REG_OFFSET            0x500
#define SLINK_REG_CHANNEL_ALLOC_TX_CFG_REG_OFFSET        0x600
#define SLINK_REG_CHANNEL_ALLOC_TX_CTRL_REG_OFFSET       0x604
#define SLINK_REG_CHANNEL_ALLOC_RX_CFG_REG_OFFSET        0x608
#define SLINK_REG_CHANNEL_ALLOC_RX_CTRL_REG_OFFSET       0x60C
#define SLINK_REG_CHANNEL_ALLOC_TX_CH_EN_0_REG_OFFSET    0x700
#define SLINK_REG_CHANNEL_ALLOC_RX_CH_EN_0_REG_OFFSET    0x800






#define SLINK_MAX_TX_CLK_DIV                             0x400

void slink_set_node_id(uint32_t id);
uint32_t slink_get_node_id();

void slink_set_ctrl_reg(uint32_t toggle_send); //When 1 Slink stops sending data to next node.
uint32_t slink_get_ctrl_reg();

uint32_t slink_get_err_reg();

void slink_set_global_addr(uint32_t address);
uint32_t slink_get_global_addr();

void slink_set_tx_clk_div(uint32_t clk_div);
uint32_t slink_get_tx_clk_div();

void slink_set_tx_clk_start(uint32_t clk_start);
uint32_t slink_get_tx_clk_start();

void slink_set_tx_clk_end(uint32_t clk_end);
uint32_t slink_get_tx_clk_end();

void slink_send_data(uint32_t address, uint32_t data);
uint32_t slink_read_data(uint32_t address);