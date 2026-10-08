# Firmware MARS against the MarsV2 hardware

Programs that run on the SoC next to MarsV2 and compare it with the firmware MARS
(`../mars/firmware`: the TCG emulator on mbedTLS, optionally behind a PMP gate).

- `fuzz.c`: one seeded command stream to both, full public state compared after
  every command, Profile departures named as rules (listed in the file).
- `perf.c`: warm per-command core cycles on both sides, as CSV; fails if the two
  sides answer a command with different return codes.

`scripts/mars-fw.sh` builds and runs them; the `Makefile` lists the variants (core,
compiler flags, gate). The tiny variants run on `TFMarsV2TinyConfig` (TinyRocket,
RV32IMAC, 128 KiB scratchpad, user mode enabled for the gate) and need
`scripts/build-rv32-libgloss.sh` once. `make spike-check` runs the fork's
differential driver in both tiny builds on spike, with TinyRocket's ISA, privilege
modes and memory size, against the host build.
