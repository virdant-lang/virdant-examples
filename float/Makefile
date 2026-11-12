# Smoke-test battery: the deterministic corner/historical batteries in
# all five rounding modes plus a modest seeded random fuzz. Sized to
# finish in a couple of minutes; crank FUZZ/DIVFUZZ for deeper runs.

FUZZ   ?= 500
DIVFUZZ ?= 200

.PHONY: test fuzz div model check clean

test: fuzz div

fuzz:
	python3 fuzz.py $(FUZZ)

div:
	python3 divmodel.py $(DIVFUZZ) 777

# Datapath-model cross-check only (no simulation).
model:
	python3 divmodel.py model

check:
	vir check src/*.vir

clean:
	rm -f add_mult.img
