#!/usr/bin/env python3
"""Run the WebAssembly spec test suite against the wasm machine.

`wast2json` (from WABT) converts each `.wast` script in `spec/test/core`
into a JSON command list plus one `.wasm` file per embedded module. Each
module is laid into its own SPI flash image (build/spec/<stem>/<n>/),
with a generated FakeFlash that reads that image, and executed standalone
by the machine, which auto-runs the `_start` export (function 0 if there
is no start export).

The machine's only observable is the interpreter's exit code, so the
harness classifies each module as:

    pass         exit 0   -- module ran to completion
    unsupported  exit 1   -- hit an opcode the machine doesn't implement
    trap         exit 2   -- module trapped
    timeout      no halt within the tick budget
    loadfail     loader failed to reach `#Done` (e.g. bad magic)

This is a conformance-by-execution subset: it cannot check `assert_return`
results or `assert_invalid` diagnostics, only whether the machine executes
the module without trapping or hitting an unsupported opcode.

Scripts the converter cannot handle at all (e.g. assert_invalid modules
whose immediates wabt's text parser rejects) are skipped, as are the
float-family tests while SKIP_FLOATS is set (the machine executes float
ops as unchecked stand-ins, so those tests carry no signal).
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC_DIR = ROOT / "spec" / "test" / "core"
BUILD_DIR = ROOT / "build" / "spec"
FLASH_WINDOW = 8 * 1024
# Simulated-tick budget per module, checked in 25k-tick checkpoints by
# tools/spec_run.poke so a halted module ends its run early.
TICK_BUDGET = 300000
# Wall-clock safety net around each tool invocation: the sim itself is
# bounded by the poke script's tick budget, but a hung tool must not
# stall the whole run.
TOOL_TIMEOUT = 120
WORKERS = 16
# Machines per generated test top: one `vir poke` compile covers a
# whole batch, and the per-machine flash fills simulate concurrently.
BATCH_SIZE = 16

# The machine executes float operations as shape-faithful 32-bit
# stand-ins (results unchecked), so the float-specific conformance
# tests are not meaningful for it. Set to False to run them anyway.
SKIP_FLOATS = True
FLOAT_PREFIXES = ("float", "f32", "f64")


def is_float_test(wast: Path) -> bool:
    return wast.stem.startswith(FLOAT_PREFIXES)


def run_wast2json(wast: Path) -> Path | None:
    """Convert a .wast script into a JSON command list."""
    out = BUILD_DIR / wast.stem
    out.mkdir(parents=True, exist_ok=True)
    json_path = out / (wast.stem + ".json")
    try:
        subprocess.run(
            ["wast2json", str(wast), "-o", str(json_path)],
            check=True,
            capture_output=True,
            timeout=TOOL_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        print(f"wast2json timed out for {wast.name}; skipping", file=sys.stderr)
        return None
    except subprocess.CalledProcessError as e:
        # Some scripts (e.g. align.wast) carry assert_invalid modules
        # whose immediates wabt's text parser rejects outright, so the
        # file cannot be converted at all. That is a toolchain
        # limitation, not a machine failure: skip the file.
        print(f"wast2json failed for {wast.name}; skipping:", file=sys.stderr)
        if e.stderr:
            print(e.stderr.decode(errors="replace"), file=sys.stderr)
        return None
    return json_path


def prepare_module(json_path: Path, module: Path, n: int) -> tuple[Path, int, int] | None:
    """Write a per-module flash image, sized to the module.

    The machine streams `window_size` bytes at boot; small modules wire
    a small window so boot costs one bit-pair per actual byte instead
    of always filling the 8 KiB window. The generated flash image holds
    the module plus an erased tail up to the next power-of-two size
    (minimum 64 bytes) so the FakeFlash memory can be equally small.

    Returns (module_dir, window, image_size), or None if the module is
    too large for the 8 KiB flash window.
    """
    image = module.read_bytes()
    if len(image) > FLASH_WINDOW:
        return None
    window = min(FLASH_WINDOW, len(image) + 8)
    image_size = 64
    while image_size < window:
        image_size *= 2
    module_dir = json_path.parent / str(n)
    module_dir.mkdir(parents=True, exist_ok=True)
    (module_dir / "flash.bin").write_bytes(image + b"\xff" * (image_size - len(image)))
    return module_dir, window, image_size


def build_batch(wast_stem: str, k: int, entries: list[tuple[Path, int, int]]) -> tuple[Path, Path]:
    """Generate a test top hosting one machine per module image.

    Every machine in the batch shares the simulation clock, so one
    compile covers the whole batch and the machines simulate
    concurrently. Each machine wires the window size its module needs.
    Returns the generated .vir file and the matching poke script.
    """
    b = len(entries)
    src = (ROOT / "src" / "test_flash.vir").read_text()
    flash_module = src[src.index("pub mod FakeFlash"):src.index("pub mod TestTop")]
    parts = [flash_module]
    for i, (module_dir, window, image_size) in enumerate(entries):
        bits = image_size.bit_length() - 1
        image_path = (module_dir / "flash.bin").relative_to(ROOT).as_posix()
        mod = flash_module.replace("pub mod FakeFlash", f"pub mod FakeFlash{i}")
        mod = mod.replace("assets/flash_image.bin", image_path)
        mod = mod.replace("memory image[8192] : Word[8]", f"memory image[{image_size}] : Word[8]")
        mod = mod.replace("image[dyn captured_addr]", f"image[dyn captured_addr[{bits}..0]]")
        mod = mod.replace(
            "image[dyn (out_byte_addr + 1)[13..0]]",
            f"image[dyn (out_byte_addr + 1)[{bits}..0]]",
        )
        parts.append(mod)
    top = ["//> Generated batch test top: one machine per module image.",
           "pub mod TestTop {",
           "    incoming clock : Clock", ""]
    for i, (_, window, _) in enumerate(entries):
        top += [
            f"    mod env{i} of exec_env::ExecutionEnvironment {{",
            "        it.clock := clock",
            f"        it.window_size := {window}w14",
            "    }",
            "",
            f"    mod flash{i} of test_flash::FakeFlash{i} {{",
            "        it.clock    := clock",
            f"        it.spi_ck   := env{i}.spi_ck",
            f"        it.spi_cs   := env{i}.spi_cs",
            f"        it.spi_mosi := env{i}.spi_mosi",
            "    }",
            "",
            f"    env{i}.spi_miso := flash{i}.spi_miso",
            "",
        ]
    top.append("}")
    parts.append("\n".join(top))

    batch_dir = BUILD_DIR / wast_stem / f"batch{k}"
    batch_dir.mkdir(parents=True, exist_ok=True)
    vir = batch_dir / "test_flash.vir"
    vir.write_text("\n".join(parts))

    checkpoints = TICK_BUDGET // 25000
    poke = ["#> Run a batch of spec test modules and report each exit code."]
    for _ in range(checkpoints):
        poke.append("tick 25000")
        for i in range(b):
            poke.append(f"print top.env{i}.machine.exec_state")
    poke.append("exit")
    poke_path = batch_dir / "run.poke"
    poke_path.write_text("\n".join(poke) + "\n")
    return vir, poke_path


def run_batch(vir: Path, poke_path: Path, b: int) -> list[tuple[str, str | None]]:
    """Run one batch and classify each machine's exit code.

    The poke script prints every machine's exec_state at each tick
    checkpoint, in a fixed order, so output lines are attributed to
    machines by position: line index mod batch size. A machine is
    classified at its first `#Halted` print; machines still running at
    the end of the budget are timeouts.
    """
    outcomes: list[tuple[str, str | None]] = [("timeout", None)] * b
    resolved = [False] * b
    remaining = b
    seen = 0
    with tempfile.TemporaryFile(mode="w+") as errf:
        proc = subprocess.Popen(
            [
                "vir", "poke",
                "-F", ",".join([
                    "src/exec_env.vir",
                    "src/wasm_machine.vir",
                    "src/wasm_types.vir",
                    "src/spi_flash.vir",
                    str(vir),
                ]),
                "--top", "test_flash::TestTop",
                "--script", str(poke_path),
            ],
            stdout=subprocess.PIPE,
            stderr=errf,
            text=True,
            bufsize=1,
            cwd=ROOT,
        )
        killer = threading.Timer(TOOL_TIMEOUT, proc.kill)
        killer.start()
        try:
            for line in proc.stdout:
                line = line.strip()
                if not line.startswith("#") or line.startswith("#>"):
                    continue
                m = seen % b
                seen += 1
                if resolved[m] or not line.startswith("#Halted(0b"):
                    continue
                bits = line[len("#Halted(0b"):-1]
                outcomes[m] = (classify_exit(int(bits, 2)), line)
                resolved[m] = True
                remaining -= 1
                if remaining == 0:
                    break
            if seen < b:
                # Not even one full checkpoint printed: the invocation
                # itself failed (e.g. a compile error).
                outcomes = [("loadfail", None)] * b
        finally:
            killer.cancel()
            proc.kill()
            proc.wait()
        if outcomes[0][0] == "loadfail":
            errf.seek(0)
            detail = errf.read().strip()
            outcomes = [("loadfail", detail)] * b
    return outcomes


def classify_exit(exit_code: int) -> str:
    if exit_code == 0:
        return "pass"
    if exit_code == 1:
        return "unsupported"
    return "trap"


def run_one(wast: Path) -> dict:
    """Convert one .wast script and run every embedded module."""
    json_path = run_wast2json(wast)
    if json_path is None:
        return {"skipped": 1}
    skipped_too_large = False
    script = json.loads(json_path.read_text())
    entries = []
    for i, command in enumerate(script["commands"]):
        if command.get("type") != "module":
            continue
        module = json_path.parent / command["filename"]
        entry = prepare_module(json_path, module, i)
        if entry is None:
            skipped_too_large = True
            continue
        entries.append(entry)
    built = [
        (*build_batch(wast.stem, k, entries[i:i + BATCH_SIZE]),
         len(entries[i:i + BATCH_SIZE]))
        for k, i in enumerate(range(0, len(entries), BATCH_SIZE))
    ]
    counts = {}
    with ThreadPoolExecutor(max_workers=WORKERS) as pool:
        for batch_outcomes in pool.map(lambda t: run_batch(*t), built):
            for outcome, _ in batch_outcomes:
                counts[outcome] = counts.get(outcome, 0) + 1
    if skipped_too_large:
        counts["skipped"] = counts.get("skipped", 0) + 1
    return counts


FAILURES = ("unsupported", "trap", "timeout", "loadfail")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-ff", "--fail-fast",
        action="store_true",
        help="stop at the first .wast with a failing outcome and exit 1",
    )
    parser.add_argument(
        "-s", "--start",
        metavar="TEST",
        default=None,
        help="begin at this .wast (name or 1-based index), skipping earlier files",
    )
    parser.add_argument(
        "-k", "--skip",
        metavar="TEST",
        action="append",
        default=[],
        help="skip this .wast (name or 1-based index); repeatable or comma-separated",
    )
    args = parser.parse_args()

    all_wast = sorted(SPEC_DIR.glob("*.wast"))
    if not all_wast:
        print(f"no .wast files under {SPEC_DIR}; run `git submodule update --init`", file=sys.stderr)
        return 1
    start = 1
    if args.start is not None:
        if args.start.isdigit():
            start = int(args.start)
        elif args.start in (w.stem for w in all_wast):
            start = [w.stem for w in all_wast].index(args.start) + 1
        else:
            print(f"no .wast named {args.start!r}", file=sys.stderr)
            return 1
        if not 1 <= start <= len(all_wast):
            print(f"start index {start} out of range 1..{len(all_wast)}", file=sys.stderr)
            return 1
    skip = set()
    for item in args.skip:
        for name in item.split(","):
            name = name.strip()
            if name.isdigit():
                skip.add(all_wast[int(name) - 1].stem)
            elif name in (w.stem for w in all_wast):
                skip.add(name)
            else:
                print(f"no .wast named {name!r}", file=sys.stderr)
                return 1
    wast_files = [
        w for w in all_wast[start - 1:]
        if w.stem not in skip
        and not (SKIP_FLOATS and is_float_test(w))
    ]
    skipped_floats = sum(
        1 for w in all_wast[start - 1:]
        if w.stem not in skip and SKIP_FLOATS and is_float_test(w)
    )
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    total = {}
    for i, wast in enumerate(wast_files, start):
        print(f"[{i}/{len(all_wast)}] {wast.stem} ...", end="", flush=True)
        counts = run_one(wast)
        summary = " ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "(no modules)"
        print(f" {summary}", flush=True)
        for key, value in counts.items():
            total[key] = total.get(key, 0) + value
        if args.fail_fast and any(counts.get(k) for k in FAILURES):
            print(f"fail-fast: stopping at {wast.stem} (resume with -s {wast.stem})", flush=True)
            break

    print()
    print("totals:")
    if skipped_floats:
        print(f"  skipped_float_files: {skipped_floats}")
    for key in ("pass", "unsupported", "trap", "timeout", "loadfail", "skipped"):
        print(f"  {key}: {total.get(key, 0)}")
    return 1 if args.fail_fast and any(total.get(k) for k in FAILURES) else 0


if __name__ == "__main__":
    sys.exit(main())
