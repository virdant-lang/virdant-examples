PROG ?= hello.bf

list: programs

hello:
	@ln -sf programs/hello.bin program.bf
	@vir run
	@unlink program.bf

define RUN_TEMPLATE
run-$(1):
	@ln -sf programs/$(1) program.bf
	@vir run
	@unlink program.bf
endef

PROGRAMS := $(notdir $(wildcard programs/*.bf) $(wildcard programs/*.bin))

$(foreach prog,$(PROGRAMS),$(eval $(call RUN_TEMPLATE,$(prog))))

run: run-$(PROG)

# Run every example program in sequence.
examples: $(addprefix run-,$(PROGRAMS))

programs:
	@echo "Available programs (make run-<file> or make run PROG=<name>):"
	@echo $(PROGRAMS) | tr ' ' '\n' | sed 's/^/  /'


quine:
	@ln -sf programs/quine.bf program.bf
	@vir run
	@unlink program.bf
	@echo

test:
	@ln -sf programs/hello.bin program.bf
	vir poke test.poke --script
	@unlink program.bf

.PHONY: run examples programs list hello quine test $(addprefix run-,$(PROGRAMS))
