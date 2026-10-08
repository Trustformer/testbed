# SoC programs comparing the firmware MARS (../mars) with the MarsV2 hardware.
#
#   make build/<variant>/fuzz-s<SEED>-n<COUNT>-p<PRE>.riscv   [SEED=1 COUNT=200 PRE=20+SEED%6]
#   make build/<variant>/perf-r<REPS>.riscv                   [REPS=7]
#   make spike-check   the tiny builds of the fork's differential driver on spike
#
# Variants: huge-core, huge-core-gate, huge-testbed (TFMarsV2Config: the current
# Rocket, firmware built for everything it supports or for the testbed's default
# flags), tiny, tiny-gate (TFMarsV2TinyConfig: TinyRocket, RV32IMAC, 128 KiB).
# "-gate" runs the caller in user mode and the firmware behind the PMP gate.
# Run inside the chipyard environment: scripts/cy 'make -C ../marsfw ...'.

FW    := ../mars/firmware
EMU   := ../mars/emulator/c
B     := build
SEED  ?= 1
COUNT ?= 200
PRE   ?= $(shell echo $$((20 + $(SEED) % 6)))
REPS  ?= 7

RV64 := riscv64-unknown-elf-gcc -mabi=lp64d -mcmodel=medany -O2 -std=gnu99
RV32 := riscv32-none-elf-gcc -march=rv32imac_zicsr -mabi=ilp32 -mcmodel=medany -O2 -std=gnu99
# libgloss-htif for RV32 (scripts/build-rv32-libgloss.sh), and the 128 KiB scratchpad.
LG32     := $(abspath ../.rv32-libgloss)
TINY_MEM := -Wl,--defsym=__heap_size=0x2000 -Wl,--defsym=__stack_size_min=0x2000

CC_huge-core      := $(RV64) -march=rv64imafdc_zba_zbb_zbs
CC_huge-core-gate := $(CC_huge-core)
CC_huge-testbed   := $(RV64) -march=rv64imafd
CC_tiny           := $(RV32)
CC_tiny-gate      := $(RV32)

LD_huge-core      := -specs=htif.specs -static -T htif.ld
LD_huge-core-gate := -specs=htif.specs -static -T $(FW)/gate/gate.ld
LD_huge-testbed   := -specs=htif_nano.specs -static -T htif.ld
LD_tiny           := -specs=$(LG32)/lib/htif_nano.specs -L$(LG32)/lib -static -T $(LG32)/lib/htif.ld $(TINY_MEM)
LD_tiny-gate      := -specs=$(LG32)/lib/htif_nano.specs -L$(LG32)/lib -static -T $(FW)/gate/gate.ld $(TINY_MEM)

gate = $(findstring gate,$(1))
ar   = $(if $(findstring tiny,$(1)),riscv32-none-elf-ar,riscv64-unknown-elf-ar)
INC  := -I. -I$(EMU) -I$(FW)/gate -I../chipyard/tests

.PHONY: FORCE clean
.SECONDARY:

$(B)/%/libmarsfw.a: FORCE
	$(MAKE) -s -C $(FW) lib NAME=$* B=$(abspath $(B)) LIBAR=$(call ar,$*) $(if $(call gate,$*),GATE=1) \
	    LIBCC='$(CC_$*) -DMARS_BAREMETAL -DMARS_QUIET'

$(B)/%/fuzz-s$(SEED)-n$(COUNT)-p$(PRE).riscv: fuzz.c hw.h $(B)/%/libmarsfw.a
	$(CC_$*) $(INC) $(if $(call gate,$*),-DMARS_GATE) -DSEED=$(SEED) -DCOUNT=$(COUNT) -DPRE=$(PRE) $(LD_$*) -o $@ \
	    fuzz.c $(if $(call gate,$*),$(FW)/gate/gate_user.c) $(B)/$*/libmarsfw.a

$(B)/%/perf-r$(REPS).riscv: perf.c hw.h $(B)/%/libmarsfw.a
	$(CC_$*) $(INC) $(if $(call gate,$*),-DMARS_GATE) '-DBUILD="$*"' -DREPS=$(REPS) $(LD_$*) -o $@ \
	    perf.c $(if $(call gate,$*),$(FW)/gate/gate_user.c) $(B)/$*/libmarsfw.a

# The tiny builds on spike, with TinyRocket's ISA, modes and memory, against the host.
SPIKE32 := spike --isa=rv32imac_zicsr_zicntr --priv=mu -m0x80000000:0x20000
CALLS   ?= 5000

fw_test = $(CC_$*) -I$(EMU) $(if $(call gate,$*),-I$(FW)/gate -DMARS_GATE) -DNCALLS=$(CALLS) -DSEED=$(SEED) \
    $(LD_$*) -o $@ $< $(if $(call gate,$*),$(FW)/gate/gate_user.c) $(B)/$*/libmarsfw.a
$(B)/%/mars_diff.riscv: $(FW)/test/mars_diff.c $(B)/%/libmarsfw.a
	$(fw_test)
$(B)/%/gate_pmp.riscv: $(FW)/test/gate_pmp.c $(B)/%/libmarsfw.a
	$(fw_test)

.PHONY: spike-check
spike-check: $(B)/tiny/mars_diff.riscv $(B)/tiny-gate/mars_diff.riscv $(B)/tiny-gate/gate_pmp.riscv
	@$(MAKE) -s -C $(FW) build/host/ref-mars_diff
	@$(FW)/build/host/ref-mars_diff $(CALLS) $(SEED) | grep '^@' > $(B)/spike.ref
	@for v in tiny tiny-gate; do \
	  $(SPIKE32) $(B)/$$v/mars_diff.riscv | grep '^@' > $(B)/spike.$$v; \
	  cmp -s $(B)/spike.ref $(B)/spike.$$v || { echo "FAIL: spike ($$v) differs from the host"; exit 1; }; \
	  echo "$$v: $$(grep -c '^@[0-9]' $(B)/spike.$$v) calls on spike == host"; \
	done
	@$(SPIKE32) $(B)/tiny-gate/gate_pmp.riscv > $(B)/spike.pmp; \
	  grep -q '^PASS gate_pmp' $(B)/spike.pmp || { cat $(B)/spike.pmp; echo "FAIL: gate_pmp"; exit 1; }
	@echo "tiny-gate: user-mode loads and stores into the firmware fault; pointers into it are refused"
	@echo "PASS spike-check"

clean:
	rm -rf $(B)
