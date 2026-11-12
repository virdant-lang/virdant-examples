# WebAssembly spec test harness for the wasm machine.
#
# The spec suite lives in spec/test/core (a git submodule of
# https://github.com/WebAssembly/spec). `make test` converts every
# .wast script with wast2json (WABT), executes each embedded module
# on the machine, and classifies the exit code.
#
# The machine's only observable is the interpreter's exit code:
#   0 = pass (module ran to completion)
#   1 = unsupported opcode
#   2 = trap
# so this is a conformance-by-execution subset, not a full
# assert_return/assert_invalid conformance run.

SPEC_DIR := spec/test/core
PYTHON   := python3

.PHONY: test
test:
	$(PYTHON) tools/run_spec.py

.PHONY: test-one
# Usage: make test-one SPEC=block.wast
test-one:
	@test -n "$(SPEC)" || { echo "usage: make test-one SPEC=block.wast"; exit 1; }
	$(PYTHON) tools/run_spec.py $(SPEC_DIR)/$(SPEC)

.PHONY: update-spec
update-spec:
	git submodule update --init --remote spec
