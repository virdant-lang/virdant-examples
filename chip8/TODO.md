# TODO — CHIP-8 emulator

## Real-game bring-up (snake investigation)

- [x] **Framebuffer/data/stack started as random garbage — FIXED.** Real
      games do not `00E0`-clear at boot (snake jumps straight into its
      attract mode) and assume power-on zeroed RAM; every test ROM
      cleared first, masking this. `initial` on a memory is
      unsupported (`MemoryInitialUnsupported`) — memories initialize
      only via `@image`/`@image_hex`/`@image_inline` (one byte per
      `Word[1]` element). Fix: `@image_inline` zeros on
      `data_registers`/`call_stack`, `@image("images/frame_buffer_zero.image")`
      on `frame_buffer`. Snake's title screen reconstructs cleanly from
      the VGA scan after the fix (was: all 2048 pixels of noise).
      Full battery re-passed: box 12/12, shift 8/8, beep 5/5, fx0a
      11/11, mem 10/10.
- [x] **Games added.** `roms/games/` — br8kout, snake, tank, superpong,
      dodge, sweetcopter from the CHIP-8 Archive, converted by
      `tools/make_flash.py` (font baked at 0x000 + program at 0x200).
      Controls + caveats in `roms/games/README.md`. Snake plays with
      W/A/S/D (CHIP-8 keys 5/7/8/9) and starts via FX0A (press AND
      release = hit W twice; UART toggle keypad).
- [ ] **Playability: the board runs ~200x slower than wall time.**
      1 instruction per 100k board clocks (500/s sim) and a 60 Hz
      frame tick per 833k clocks, while the simulator manages only
      ~110k board cycles/wall-second → snake's attract mode alone runs
      ~143M cycles ≈ 21 wall minutes before FX0A, and a delay-timer
      tick is ~8 wall seconds. Options: shrink run_divider (more
      instr/s sim), shrink frame_divider (60 Hz sim → faster wall),
      and/or rescale VGA geometry (monitor mode adoption must be
      re-checked). All three scale together if games should feel
      real-time.
- [ ] Caution for long `--trace` runs: one mem sweep run exited 0 at
      5.5M cycles instead of its 6.2M limit (a rerun to 6.2M passed
      10/10) — never reproduced, suspect /tmp-tmpfs pressure (giant
      VCDs eat RAM). If a checker fails with a truncated trace, rerun
      before debugging the design.

## Simulator workarounds removed (upstream fixes verified)

- [x] **dontcare workaround reverted.** Upstream `aa357f6` accepts bare
      `dontcare` in arm bodies; both `else => 0w8` sites in `chip8.vir`
      are back to `else => dontcare`. `vir check` clean.
- [x] **Both write skid buffers removed.** Upstream `b6d3dde` (two-phase
      commit: every memory write site sampled once per edge against
      pre-edge values, writes staged and applied with the register
      transfers) fixes the re-fire/RMW artifact and the exit-edge
      dropped write. `frame_buffer` draws directly from
      `draw_new_pixel` again; FX0A commits Vx directly at the
      WaitKey→Fetch edge. Full battery re-run: box/shift/beep/fx0a all
      ALL CHECKS PASSED.
- [x] **bug3 wire indirection removed.** Same upstream fix; `call_stack`
      reads `cpu_state`/`stack_pointer`/`pc` directly in its write site
      again (the `call_stack_write_*` wires are gone). Verified by a
      NEW success-path `2NNN`/`00EE` roundtrip in `roms/test_mem.flash`
      (`oksub` draws the ok marker, sets V8 = 0x88, returns; caller
      checks V8) — previously the call_stack was only exercised on the
      fail path, which no passing run ever took. `mem` checker: ALL
      CHECKS PASSED.

## Functional bugs (all fixed)

- [x] **CXNN masking.** Fixed: writes `rand_lfsr[8..0] & kk`; verified in
      trace.
- [x] **data_registers write site unguarded.** Fixed: FX65 load guarded by
      `cpu_state == #MemSeq && inst_lo == 0x65`.
- [x] **Flash loader off-by-one.** Fixed: `write_addr := byte_count - 1`.
- [x] **SPI command misalignment (was blocking).** FIXED + verified:
      `cmd_shift` shift gated with `cmd_bits != 0`, CmdAddr→ReadData on
      `cmd_bits == 32`. Loader data now byte-exact (VCD checker: 0
      mismatches).
- [x] **8XY6/8XYE shift-in bit (was suspect).** FALSE ALARM: `0w1` is a
      1-bit zero literal; Verilog shows `{1'd0, vx[7:1]}` / `{vx[6:0],
      1'd0}`. Simulation-verified via `roms/test_shift.flash` +
      `tools/check_vcd_shift.py` (0x78 / 0x1E commits, box at (8,8)).
- [x] **8XY7 never reached WriteVf.** FOUND + FIXED + verified: added
      `with 0x7 => #WriteVf`; VF latches 1 after 8027 in the shift ROM.
- [x] **frame_buffer write re-fire hazard.** Draw write read the same
      memory it wrote; sim re-fired the write (first pixel poisoned,
      last pixel's write dropped at the Draw→WriteVf edge). Fixed with a
      write skid (`draw_wb_en/addr/data`); framebuffer reconstruction now
      matches exactly. See HANDOFF.md.
- [x] **FX0A Vx commit dropped at the WaitKey→Fetch edge.** Same artifact;
      Vx kept garbage (drew at y=27 instead of key=5). Was fixed with a
      skid (`waitkey_wb_en/data`); the skid has since been REMOVED —
      the upstream two-phase commit fix makes the direct write exact
      (see "Simulator workarounds removed" above).

## Bring-up

- [x] Test ROMs written and run under `vir run --cycles ... --trace`:
      `test_box` (main), `test_shift`, `test_fx0a`, `test_beep`.
- [x] Full VCD checker passes: loader data byte-exact, 10-instruction
      stream in order, 24-pixel draw walk, CXNN, FX15 delay-timer load,
      frame_tick, **and 64x32 framebuffer reconstruction from the VGA
      scan** (`tools/check_vcd.py`).
- [x] Shift/8XY7 checker passes (`tools/check_vcd_shift.py`).
- [x] Beep checker passes (`tools/check_vcd_io.py beep`): FX18 load,
      beep follows sound_timer, decays to 0.
- [x] Keypad decoder unit test passes (`test/keydec.poke`, poke
      testbench on `top::Top`): press / release / move / ignore-non-key.
- [x] **FX0A end-to-end run** (`tools/check_vcd_io.py fx0a`):
      **ALL CHECKS PASSED (11/11)** with the skid removed. Load it with
      the deterministic stimulus `tools/fx0a_keys.py` (file-redirect to
      stdin): wall-clock sleep pipes are nondeterministic — the press
      landed before WaitKey even started (cycle 87690 < 200000). The
      checker's commit subcheck now observes the direct Vx commit at
      the WaitKey→Fetch edge (the old `waitkey_wb_en` check targeted
      the removed skid signal).
- [x] `mem` checker (`tools/check_vcd_io.py mem` + `roms/test_mem.flash`,
      regenerated by `tools/make_test_mem.py`): ALL CHECKS PASSED
      (10/10). Needs ~6.2M cycles with `--trace` so one complete frame
      follows the last draw.
- [ ] Confirm the VGA monitor locks 640x480@60 visually in a windowed
      run (headless verification of sync geometry/duty cycle already
      implicit in the framebuffer reconstruction; visual check needs a
      display).
- [x] Trace-verified sequencing: Execute pulses every 100_000 cycles
      (500 instr/s), loader Done at cycle ~65_598, one-hot CpuState
      encodings confirmed.

## Quirks / policy (decided — documented in HANDOFF.md)

- [x] DXYN `N == 0`: 16 rows (classic VIP behavior) — kept.
- [x] 8XY6/8XYE shift-vs-VY and FX55/FX65 I-increment quirks: "modern"
      (VX shifts, I unchanged).
- [x] Sprite XOR clipping: wraps x mod 64 / y mod 32 — kept, documented.
- [x] FX0A: classic press-and-release.
- [x] UART keypad semantics (no release signal over UART): character
      presses, same character again releases, different character moves
      the press; one key held at a time. Classic CHIP-8 ASCII layout.

## Stub development

- [x] **Input: `input::KeyStub` replaced by `input::KeyDecoder`** —
      UART 115200 8N1 → classic-layout ASCII → `keypad.key`; glitch gate
      + mid-bit sampler; verified by poke testbench. Socket wiring in
      `top::Top` unchanged.
- [ ] **Sound: `sound::SoundStub`** — VirtVga has no audio pins, so
      there is nothing to drive on this board; the core-side behavior
      (FX18 → sound_timer → `audio.beep`) is implemented and verified.
      Revisit only when targeting a board with audio pins (square wave
      gated by beep → speaker/PWM). Optionally remove the stub's
      `unused` warnings.
- [x] Remove the `else => 0w8` workaround — upstream fixed (see
      "Simulator workarounds removed" above).

## Nice to have

- [x] `vir build` flow check — clean; Verilog output used to verify
      slice/literal lowering.
- [ ] Sprite draw is one pixel/cycle (up to 1024 cycles worst case) —
      consider multi-pixel/cycle if frame rate matters.
- [x] VCD checker in-tree: `tools/` (`check_vcd.py`, `check_vcd_shift.py`,
      `check_vcd_io.py`) + poke testbench `test/keydec.poke`.
- [x] Sim write-site findings reported upstream — FIXED upstream:
      `b6d3dde` (two-phase memory commit, write sites sampled against
      pre-edge values; see virdant/bug3/REPORT.md for the mechanism
      analysis) and `aa357f6` (bare `dontcare`). All workarounds in
      this project have been removed and re-verified.
