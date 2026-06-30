// Authors:
//  - Maximilian Kocher <mkocher@ethz.ch>
//  - Fabian Aegerter   <faegerter@ethz.ch>

#pragma once

#include <stdint.h>
#include "config.h" // provides USER_ROM_BASE_ADDR

// Number of 32-bit words in the ROM (must match NumWords in user_rom.sv).
#define USER_ROM_NUM_WORDS 15

// Largest possible string length (4 bytes per word) plus the NUL terminator.
#define USER_ROM_MAX_CHARS (USER_ROM_NUM_WORDS * 4 + 1)

// Read the raw 32-bit word at word index `idx` (0 .. USER_ROM_NUM_WORDS-1).
uint32_t user_rom_read_word(uint32_t idx);

// Copy the credits string into `buf` as a NUL-terminated C string and return
// its length. `buf` must hold at least USER_ROM_MAX_CHARS bytes.
uint32_t user_rom_read_string(char *buf);
