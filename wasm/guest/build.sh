#!/bin/sh
# Builds the guest wasm module and the flash image used by the
# FakeFlash-based regression test. The main flow needs no image:
# program the raw .wasm directly with `vir run --flash assets/hello.wasm`.
set -e
cd "$(dirname "$0")/.."
rustc --target wasm32-unknown-unknown -O -C opt-level=z -C panic=abort \
      --crate-type cdylib -C link-arg=--allow-undefined \
      guest/hello.rs -o assets/hello.wasm
python3 tools/make_flash.py assets/hello.wasm assets/flash_image.bin
