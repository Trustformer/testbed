#!/usr/bin/env bash
# Build chipyard's libgloss-htif for RV32 (TinyRocket: rv32imac, ilp32) into
# .rv32-libgloss/, for the tiny variants in marsfw/.  The conda toolchain ships
# libgloss for rv64 only; riscv32-none-elf-gcc comes from flake.nix.
#
#   scripts/cy ../scripts/build-rv32-libgloss.sh
set -euo pipefail

TESTBED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$TESTBED/chipyard/toolchains/libgloss"
OUT="$TESTBED/.rv32-libgloss"

rm -rf "$OUT"
mkdir -p "$OUT/build"
cd "$OUT/build"
"$SRC/configure" --prefix="$OUT" --host=riscv32-none-elf \
    CC=riscv32-none-elf-gcc AR=riscv32-none-elf-ar \
    CFLAGS="-march=rv32imac_zicsr -mabi=ilp32 -mcmodel=medany -O2"
make -j"$(nproc)"
# The install checks that libdir is in gcc's default search path; the marsfw builds
# pass it with -L and -specs instead.
make install searchdirs="$OUT/lib"
echo "==> libgloss-htif for RV32 in $OUT"
