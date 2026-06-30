// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>
//

#include "uart.h"
#include "print.h"
#include "util.h"
#include "config.h"
#include "user_rom.h"

int main() {
    uart_init();

    printf("User ROM @ %x\n", (unsigned)USER_ROM_BASE_ADDR);

    char buf[USER_ROM_MAX_CHARS];
    uint32_t len = user_rom_read_string(buf);


    printf("String (%x chars): ", len);
    for (uint32_t i = 0; i < len; i++) putchar(buf[i]);
    putchar('\n');

    // Raw word dump for debugging / waveform cross-checking.
    for (uint32_t i = 0; i < USER_ROM_NUM_WORDS; i++) {
        printf("  word %x = %x\n", i, user_rom_read_word(i));
    }

    uart_write_flush();
    return 0;
}
