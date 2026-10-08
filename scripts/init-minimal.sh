#!/usr/bin/env bash
# Initialize only the chipyard submodules needed to compile the `chipyard` sbt
# project and run a Verilator simulation of a Rocket + Trustformer-MMIO SoC.
#
# Rationale:
#   * generators/chipyard `.dependsOn` ~30 generator repos (build.sbt L156-170),
#     so their *Scala* sources are needed to compile -- but their nested RTL /
#     software submodules are elaboration-time inputs for configs we never build.
#     Hence: non-recursive, blobless clones.
#   * software/, fpga/, vlsi/, tools/{circt,DRAMSim2,axe,torture} are unused.
#   * toolchains/* are initialized on demand by scripts/build-toolchain-extra.sh
#     (build-setup step 3), so they are deliberately not listed here.
#   * sims/firesim is needed for one sbt project only:
#     hardfloat.dependsOn(midas_target_utils) = sims/firesim/sim/midas/targetutils.
set -euo pipefail

TESTBED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# chipyard and mars (the TCG MARS emulator) are submodules of the testbed,
# empty in a fresh clone.
echo "==> Initializing chipyard and mars"
git -C "$TESTBED" submodule update --init --filter=blob:none chipyard mars
cd "$TESTBED/chipyard"

MODULES=(
  generators/ara
  generators/bar-fetchers
  generators/boom
  generators/caliptra-aes-acc
  generators/compress-acc
  generators/constellation
  generators/cva6
  generators/diplomacy
  generators/fft-generator
  generators/gemmini
  generators/hardfloat
  generators/ibex
  generators/icenet
  generators/mempress
  generators/nvdla
  generators/radiance
  generators/rerocc
  generators/riscv-sodor
  generators/rocc-acc-utils
  generators/rocket-chip
  generators/rocket-chip-blocks
  generators/rocket-chip-inclusive-cache
  generators/saturn
  generators/shuttle
  generators/tacit
  generators/testchipip
  generators/trustformer
  generators/vexiiriscv
  sims/firesim
  tools/cde
  tools/dsptools
  tools/firrtl2
  tools/fixedpoint
  tools/rocket-dsp-utils
)

echo "==> Initializing ${#MODULES[@]} submodules (non-recursive, blobless)"
git submodule update --init --filter=blob:none "${MODULES[@]}"

# Keep later `git submodule update` invocations from pulling firesim's tree back in.
git config --local submodule.sims/firesim.update none

echo "==> Done. Not initialized (on purpose):"
git submodule status | grep '^-' | awk '{print "    " $2}' || true
