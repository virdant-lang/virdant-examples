#!/usr/bin/env python3
"""Build a SPI flash image for the runtime's regression tests.

Takes a raw `.wasm` file and lays it into an erased flash window:
the module bytes at address 0, everything after them 0xFF (the erased
state of a real flash device, which the loader treats as the
end-of-module sentinel).

The main flow needs no image at all: `vir run --flash hello.wasm`
programs the raw file directly.
"""
import sys

FLASH_WINDOW = 8 * 1024


def main() -> None:
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as f:
        image = f.read()
    if len(image) > FLASH_WINDOW:
        sys.exit(f"{src} is {len(image)} bytes, exceeds flash window {FLASH_WINDOW}")
    with open(dst, "wb") as f:
        f.write(image)
        f.write(b"\xff" * (FLASH_WINDOW - len(image)))
    print(f"{dst}: raw {len(image)}-byte wasm at address 0, erased tail to {FLASH_WINDOW}")


if __name__ == "__main__":
    main()
