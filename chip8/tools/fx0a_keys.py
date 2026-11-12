#!/usr/bin/env python3
"""Write the deterministic UART keystroke stream for the FX0A run.

usage: fx0a_keys.py > /tmp/fx0a_keys.bin
       vir run --flash roms/test_fx0a.flash ... < /tmp/fx0a_keys.bin

Why this is deterministic: the virt board queues every stdin byte and
shifts the queue out on `rx` back-to-back at the configured baud
(vir/src/run/virt.rs `UartRx`: 10 bits per byte, the next byte starts
one cycle after the previous stop bit).  With all bytes available up
front (a file redirect, not a slow pipe), key timing is fixed in
*simulated* cycles instead of depending on wall-clock sleeps.  The only
jitter is the board's stdin poll (every 1000 cycles), so the first byte
starts at cycle 0 or 1000 (+ a few thousand if the reader thread is
slow); the margins below are far larger than that.

Filler bytes are 0xFF, which `input::KeyDecoder` ignores (not a key
character).  0xFF also has no falling edge after its start bit, so the
very first byte cannot desynchronize the decoder even when it begins
before the decoder's 100-cycle idle gate has opened.

Timeline at 50 MHz, 115200 baud (434.03 cycles/bit, 4340.3/byte):
  - loader done ~65.6k; run_pulse at 99_999 + k*100_000
  - 00E0 at 100k (Clear, 2048 cycles), F20A at 200k -> WaitKey ~200_001
  - byte 51 'W' starts ~221.4k, decoded (mid data bit 8) ~225.1k: press
  - byte 56 'W' starts ~243.1k, decoded ~246.8k: release -> FX0A done,
    V2 := 5 ('W' is CHIP-8 key 5 on the classic layout)
  - A21E at 300k, 6108 at 400k, D123 at 500k (box at (8..15, 5..7)),
    120A (halt loop) from 600k on
  - VGA vsync rises at 784_000 + k*840_000, so --cycles 1_700_000 gives
    a complete vsync-to-vsync frame (784k..1624k) after the draw.
"""
import sys

FILLER = b'\xff'
PRESS_BYTE_INDEX = 51
RELEASE_BYTE_INDEX = 56

stream = bytearray(FILLER * (RELEASE_BYTE_INDEX + 1))
stream[PRESS_BYTE_INDEX] = ord('W')
stream[RELEASE_BYTE_INDEX] = ord('W')
sys.stdout.buffer.write(bytes(stream))
