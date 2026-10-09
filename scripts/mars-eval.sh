#!/usr/bin/env bash
# Benchmark and evaluate the firmware MARS against MarsV2: build everything, then run
# the perf table and the differential fuzz runs in parallel.  Run it in tmux:
#
#   scripts/mars-eval.sh            [COUNT=500 SEEDS="1 2 3 4" VARIANTS=<all five>]
#
# Results in marsfw/results/: perf.md, perf.csv, fuzz-<variant>-s<seed>-n<count>.log,
# and one .out per run with its full output.
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
