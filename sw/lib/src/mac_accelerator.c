// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>

#include "mac_accelerator.h"
#include "util.h"

void mac_configure(uint32_t matrix_base_addr, uint32_t x_base_addr,
                   uint32_t vec_len, uint32_t num_row) {
    *reg32(MAC_BASE_ADDR, MAC_MATRIX_BASE_OFFSET) = matrix_base_addr;
    *reg32(MAC_BASE_ADDR, MAC_X_BASE_OFFSET)      = x_base_addr;
    *reg32(MAC_BASE_ADDR, MAC_VEC_LEN_OFFSET)     = vec_len;
    *reg32(MAC_BASE_ADDR, MAC_NUM_ROW_OFFSET)     = num_row;
}

void mac_start(void) {
    *reg32(MAC_BASE_ADDR, MAC_START_OFFSET) = 1;
}

uint32_t mac_get_result(void) {
    return *reg32(MAC_BASE_ADDR, MAC_RESULT_OFFSET);
}

uint32_t mac_ack_done(void) {
    return *reg32(MAC_BASE_ADDR, MAC_STATUS_OFFSET);
}

uint32_t mac_ack_start(void) {
    return *reg32(MAC_BASE_ADDR, MAC_START_OFFSET);
}
