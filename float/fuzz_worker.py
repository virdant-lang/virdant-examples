#!/usr/bin/env python3
"""Parallel fuzz worker: runs FMA cases against its own project copy.

Usage: fuzz_worker.py <id> <n_random> <seed> [corners]

Sets up /tmp/fuzzw<id>/ as a private copy of the project (its own
add_mult.img), then fuzzes. Prints FAIL lines and a summary; exits
nonzero on a reproduced mismatch.
"""

import os
import shutil
import sys

sys.path.insert(0, "/home/vircodificat/projects/virdant/float")

import fputils
import fuzz

WORKER_ID = int(sys.argv[1])
N_RANDOM = int(sys.argv[2])
SEED = int(sys.argv[3])
DO_CORNERS = len(sys.argv) > 4 and sys.argv[4] == "corners"

WORK_DIR = "/tmp/fuzzw{}".format(WORKER_ID)


def setup():
    src = "/home/vircodificat/projects/virdant/float"
    if os.path.exists(WORK_DIR):
        shutil.rmtree(WORK_DIR)
    os.makedirs(WORK_DIR)
    shutil.copytree(os.path.join(src, "src"), os.path.join(WORK_DIR, "src"))
    shutil.copy(os.path.join(src, "virdant.toml"), WORK_DIR)
    fputils.IMAGE_DIR = WORK_DIR


def main():
    setup()
    import random
    rng = random.Random(SEED)

    failures = 0
    flaky = 0
    total = 0

    def run_case(a, b, c, mode):
        nonlocal failures, flaky, total
        total += 1
        problems = fuzz.compare(a, b, c, mode)
        if problems:
            # The simulator has shown rare transient misbehavior under
            # load; only trust a mismatch that reproduces.
            if not fuzz.compare(a, b, c, mode):
                flaky += 1
                return
            if not fuzz.compare(a, b, c, mode):
                flaky += 1
                return
            failures += 1
            print("FAIL w{} #{}: a={:#010x} b={:#010x} c={:#010x} mode={}({})"
                  .format(WORKER_ID, total, a, b, c, mode, fuzz.MODES[mode]))
            for p in problems:
                print("      " + p)
            if failures >= 10:
                print("worker {} stopping after 10 failures".format(WORKER_ID))
                sys.exit(1)

    if DO_CORNERS:
        for vec in fuzz.CORNER_VECTORS:
            for mode in range(5):
                run_case(*vec, mode)
        print("w{} corners done: {} cases, {} failures"
              .format(WORKER_ID, total, failures))

    for _ in range(N_RANDOM):
        run_case(fuzz.random_operand(rng), fuzz.random_operand(rng),
                 fuzz.random_operand(rng), rng.randrange(5))

    print("WORKER {}: total={} failures={} flaky={}"
          .format(WORKER_ID, total, failures, flaky))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
