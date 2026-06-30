// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>

#include "user_rom.h"
#include "util.h"

uint32_t user_rom_read_word(uint32_t idx) {
    return *reg32(USER_ROM_BASE_ADDR, idx * 4);
}

uint32_t user_rom_read_string(char *buf) {
    uint32_t len = 0;

    for (uint32_t i = 0; i < USER_ROM_NUM_WORDS; i++) {
        uint32_t word = user_rom_read_word(i);

        // Words are stored little-endian: byte 0 is the first character.
        for (int b = 0; b < 4; b++) {
            char c = (char)((word >> (8 * b)) & 0xFF);
            if (c == '\0') {       // padding marks the end of the string
                buf[len] = '\0';
                return len;
            }
            buf[len++] = c;
        }
    }

    buf[len] = '\0';
    return len;
}
