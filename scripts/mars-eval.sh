#!/usr/bin/env bash
# Benchmark and evaluate the firmware MARS against MarsV2: build everything, run the perf
# table and the differential fuzz runs in parallel, then the SKY130 area of both SoCs.
# Run it in tmux:
#
#   scripts/mars-eval.sh            [COUNT=500 SEEDS="1 2 3 4" VARIANTS=<all five>]
#
# Results in marsfw/results/: perf.md, perf.csv, fuzz-<variant>-s<seed>-n<count>.log,
# fw_vs_hw.pdf (marsfw/plot.py), area.txt (scripts/mars-fw-area.py), and one .out per run
# with its full output.
# The per-module Yosys reports land in area/.
set -euo pipefail
cd "$(dirname "$0")/.."

COUNT=${COUNT:-500}
SEEDS=${SEEDS:-"1 2 3 4"}
VARIANTS=${VARIANTS:-"huge-core huge-core-gate huge-testbed tiny tiny-gate"}
R=marsfw/results
rm -rf $R
mkdir -p $R

scripts/mars-fw.sh build

scripts/mars-fw.sh perf $VARIANTS > $R/perf.out 2>&1 &
for v in $VARIANTS; do
    for s in $SEEDS; do
        scripts/mars-fw.sh fuzz $v $s $COUNT > $R/fuzz-$v-s$s.out 2>&1 &
    done
done
wait

echo "== fuzz"
grep -H -E '^(compared|PASS|FAIL)|FAILED' $R/fuzz-*-n$COUNT.log || true
echo "== perf"
cat $R/perf.md || echo "no perf table, see $R/perf.out"
echo "== plot"
nix shell .#plot -c python3 marsfw/plot.py || echo "no plot, see $R/perf.out"

echo "== area"
nix shell .#python -c scripts/mars-area.py > $R/area.out 2>&1 || { echo "area synthesis failed, see $R/area.out"; exit 1; }
nix shell .#python -c scripts/mars-fw-area.py | tee $R/area.txt
