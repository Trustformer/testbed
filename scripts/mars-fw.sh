#!/usr/bin/env bash
# The firmware MARS (mars/) against the MarsV2 hardware, on the SoC simulators.
#
#   scripts/mars-fw.sh build                          both simulators, every variant's firmware
#   scripts/mars-fw.sh perf [variant ...]             -> marsfw/results/perf.{csv,md}
#   scripts/mars-fw.sh fuzz <variant> <seed> <count>  -> marsfw/results/fuzz-<variant>-s<seed>-n<count>.log
#
# Variants (marsfw/Makefile): huge-core huge-core-gate huge-testbed tiny tiny-gate;
# perf defaults to all of them.  Each run builds what is missing and runs one
# simulator, without a cycle limit.  Run build once before starting runs in parallel.
set -euo pipefail

TESTBED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CY="$TESTBED/scripts/cy"
OUT="$TESTBED/marsfw/results"
ALL="huge-core huge-core-gate huge-testbed tiny tiny-gate"
mkdir -p "$OUT"

config() { case $1 in huge-*) echo TFMarsV2Config ;; tiny*) echo TFMarsV2TinyConfig ;; *) echo "unknown variant $1" >&2; exit 2 ;; esac; }
# TinyRocket has no DRAM, so its program loads into the scratchpad over TSI.
loadmem() { case $1 in huge-*) echo LOADMEM=1 ;; *) echo ;; esac; }

# run <variant> <program, relative to marsfw/> [make vars]: build and run; prints the log path
run() {
    local cfg; cfg=$(config "$1")
    "$CY" "make -C ../marsfw ${*:3} $2" >&2
    "$CY" "cd sims/verilator && make -j\$(nproc) CONFIG=$cfg" >&2
    "$CY" "cd sims/verilator && make CONFIG=$cfg BINARY=$TESTBED/marsfw/$2 $(loadmem "$1") \
           TIMEOUT_CYCLES=0 EXTRA_SIM_OUT_NAME=$1 BREAK_SIM_PREREQ=1 run-binary-fast" >&2 || true
    echo "$TESTBED/chipyard/sims/verilator/output/chipyard.harness.TestHarness.$cfg/$(basename "$2" .riscv).$1.log"
}

case ${1:-} in
build)
    [ -d "$TESTBED/.rv32-libgloss/lib" ] || "$CY" ../scripts/build-rv32-libgloss.sh >&2
    for cfg in TFMarsV2Config TFMarsV2TinyConfig; do
        "$CY" "cd sims/verilator && make -j\$(nproc) CONFIG=$cfg" >&2
    done
    for v in $ALL; do
        "$CY" "make -C ../marsfw build/$v/libmarsfw.a build/$v/perf-r7.riscv" >&2
    done
    echo "built: TFMarsV2Config, TFMarsV2TinyConfig, and the firmware for $ALL"
    ;;
perf)
    shift
    variants=${*:-$ALL}
    echo "build,shape,fw_min,fw_median,hw_min,hw_median" > "$OUT/perf.csv"
    for v in $variants; do
        log=$(run "$v" "build/$v/perf-r7.riscv")
        grep -q '^PASS perf' "$log" || { echo "perf failed for $v, see $log" >&2; exit 1; }
        grep '^PERF,' "$log" | cut -d, -f2- >> "$OUT/perf.csv"
    done
    # One row per shape; per variant the firmware median, then the hardware median.
    awk -F, 'NR > 1 {
        if (!($1 in seen)) { seen[$1] = 1; vs[++nv] = $1 }
        if (!($2 in row)) { row[$2] = 1; ss[++ns] = $2 }
        fw[$1, $2] = $4; hw[$1, $2] = $6
      } END {
        printf "| shape |"; for (i = 1; i <= nv; i++) printf " %s fw | %s hw |", vs[i], vs[i]; printf "\n|---|"
        for (i = 1; i <= nv; i++) printf "---:|---:|"; printf "\n"
        for (j = 1; j <= ns; j++) { printf "| %s |", ss[j]; for (i = 1; i <= nv; i++) printf " %s | %s |", fw[vs[i], ss[j]], hw[vs[i], ss[j]]; printf "\n" }
      }' "$OUT/perf.csv" > "$OUT/perf.md"
    cat "$OUT/perf.md"
    ;;
fuzz)
    [ $# -eq 4 ] || { echo "usage: ${0##*/} fuzz <variant> <seed> <count>" >&2; exit 2; }
    v=$2 seed=$3 count=$4
    pre=$((20 + seed % 6))
    log=$(run "$v" "build/$v/fuzz-s$seed-n$count-p$pre.riscv" SEED="$seed" COUNT="$count" PRE="$pre")
    cp "$log" "$OUT/fuzz-$v-s$seed-n$count.log"
    grep -E '^(compared|MISMATCH|PASS|FAIL|gate:)|FAILED' "$log" || true
    grep -q '^PASS fuzz' "$log"
    ;;
*)
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
