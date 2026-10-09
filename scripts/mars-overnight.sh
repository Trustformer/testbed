#!/usr/bin/env bash
# Overnight run: firmware MARS against the MarsV2 hardware on the SoC simulators.
# Start it once from anywhere in the testbed:
#
#   scripts/mars-overnight.sh
#
# In the foreground (~1 min) it pulls, initializes submodules and checks what it
# cannot fix itself (nix with flakes, x86_64, disk space, the firmware commits),
# then prints GO or NO-GO.  On GO it detaches (safe to log out) and runs: the
# README's first-time setup if this clone never had it, the build, the spike
# checks, the perf table, and the fuzz matrix (every variant x every seed) in
# parallel.  Everything ends up in mars-overnight/, overview in summary.txt.
#
# Knobs (environment): COUNT=500 commands per fuzz run, SEEDS="1 2 3 4",
# JOBS=<parallel simulators, default from cores and memory>, PULL=1, PERF=1,
# VARIANTS="huge-core huge-core-gate huge-testbed tiny tiny-gate".
set -uo pipefail

SELF="$(readlink -f "$0")"
TB="$(cd "$(dirname "$SELF")/.." && pwd)"
OUT="$TB/mars-overnight"
SETUP_OK="$TB/.mars-overnight-setup.ok"
cd "$TB" || exit 1

# -- foreground: preflight, then detach --------------------------------------------
if [ "${MARS_OVERNIGHT_BG:-}" != 1 ]; then
    nogo() { echo; echo "NO-GO: $*"; exit 1; }
    echo "== preflight"
    exec 9> "$TB/.mars-overnight.lock"   # held by the background run until it ends
    flock -n 9 || nogo "another mars-overnight run is still active (tail -f $OUT/run.log)"
    [ "$(uname -m)" = x86_64 ] || nogo "needs x86_64 Linux (chipyard's conda is linux-64 only)"
    command -v nix > /dev/null || nogo "nix is not on PATH"
    nix flake metadata "$TB" > /dev/null 2>&1 ||
        nogo "nix flakes do not work here: try 'nix flake metadata .' (flakes need experimental-features = nix-command flakes)"
    echo "ok   nix with flakes: $(nix --version)"
    if [ "${PULL:-1}" = 1 ]; then
        git pull --ff-only || nogo "git pull failed (local changes or no access?)"
        ./scripts/init-minimal.sh > /dev/null 2>&1 || nogo "scripts/init-minimal.sh failed; run it by hand to see why"
        echo "ok   git pull and submodules"
    fi
    grep -q '^build)' scripts/mars-fw.sh &&
        [ -f mars/third_party/mbedtls/include/mbedtls/md.h ] &&
        grep -q TFMarsV2TinyConfig chipyard/generators/chipyard/src/main/scala/config/TrustformerConfigs.scala ||
        nogo "this checkout lacks the firmware MARS commits: push the testbed (780fc0b) and rerun"
    echo "ok   firmware MARS commits present"
    freegb=$(df -Pk "$TB" | awk 'NR == 2 {print int($4 / 1048576)}')
    [ "$freegb" -ge 40 ] || nogo "only ${freegb} GB free under $TB; setup and simulators need about 40 GB"
    echo "ok   ${freegb} GB free"
    if [ -f "$SETUP_OK" ]; then echo "ok   first-time setup already done"
    elif [ -f chipyard/env.sh ]; then echo "ok   first-time setup present; checked again in the background"
    else echo "todo first-time setup (README steps 2-4): conda + build-setup.sh, about 1 h, unattended"; fi
    if [ -d "$OUT" ]; then rm -rf "$OUT.prev"; mv "$OUT" "$OUT.prev"; fi
    mkdir -p "$OUT"
    MARS_OVERNIGHT_BG=1 PULL=0 nohup setsid bash "$SELF" > "$OUT/run.log" 2>&1 < /dev/null &
    echo
    echo "GO: running in the background (pid $!); you can log out."
    echo "Progress: tail -f $OUT/run.log"
    echo "Results:  $OUT/summary.txt (written at the end, or wherever it stops)"
    exit 0
fi

# -- background: setup, build, runs ------------------------------------------------
COUNT=${COUNT:-500}
SEEDS=${SEEDS:-"1 2 3 4"}
VARIANTS=${VARIANTS:-"huge-core huge-core-gate huge-testbed tiny tiny-gate"}
cores=$(nproc)
memgb=$(awk '/MemAvailable/ {print int($2 / 1048576)}' /proc/meminfo)
auto=$(( cores - 1 < memgb * 2 / 3 ? cores - 1 : memgb * 2 / 3 ))
JOBS=${JOBS:-$auto}
[ "$JOBS" -ge 2 ] || JOBS=2
START=$(date '+%F %T')

log() { echo "[$(date '+%F %T')] $*"; }
# step <name> <command...>: run it, record OK/FAIL in steps.txt, return its status
step() {
    local name=$1 rc; shift
    log "start $name"
    "$@"; rc=$?
    if [ $rc -eq 0 ]; then echo "OK    $name" >> "$OUT/steps.txt"; else echo "FAIL  $name (exit $rc)" >> "$OUT/steps.txt"; fi
    log "end   $name (exit $rc)"
    return $rc
}

summary() {
    mkdir -p marsfw/results
    cp marsfw/results/* "$OUT/" 2>/dev/null
    {
        echo "MARS overnight: started $START, finished $(date '+%F %T')"
        echo "COUNT=$COUNT SEEDS=\"$SEEDS\" JOBS=$JOBS on $(hostname) ($cores cores, ${memgb} GB free at start)"
        echo
        echo "== steps"
        cat "$OUT/steps.txt" 2>/dev/null
        echo
        echo "== fuzz"
        if [ ! -f "$OUT/fuzz-status.txt" ]; then echo "not started"; else
        for s in $SEEDS; do for v in $VARIANTS; do
            f=marsfw/results/fuzz-$v-s$s-n$COUNT.log
            if [ ! -f "$f" ]; then
                printf '%-15s seed %s: NO RESULT, see fuzz-%s-s%s.out\n' "$v" "$s" "$v" "$s"
                continue
            fi
            verdict=FAIL; grep -q '^PASS fuzz' "$f" && verdict=PASS
            printf '%-15s seed %s: %s  %s\n' "$v" "$s" "$verdict" "$(grep -m1 '^compared' "$f")"
            [ $verdict = PASS ] || grep -m5 -E '^MISMATCH|^gate:|FAILED' "$f" | sed 's/^/    /'
        done; done; fi
        echo
        echo "== perf (core cycles, median of 7; fw = firmware MARS, hw = MarsV2)"
        if [ -f marsfw/results/perf.md ]; then cat marsfw/results/perf.md; else echo "no table, see perf.out"; fi
    } > "$OUT/summary.txt"
    log "summary written to $OUT/summary.txt"
}

fatal() { log "STOP: $*"; echo "STOP  $*" >> "$OUT/steps.txt"; summary; exit 1; }

log "testbed $TB, $cores cores, ${memgb} GB free, $JOBS parallel simulators"
rm -rf marsfw/results

# README "First-time setup", steps 2-4, verbatim; skipped once it has passed here.
if [ ! -f "$SETUP_OK" ]; then
    if [ ! -f conda/etc/profile.d/conda.sh ]; then
        step "setup: install conda (README step 2)" nix run .#fhs -- -c '
          wget -q "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh" -O Miniforge3.sh
          bash Miniforge3.sh -b -p $HOME/conda' || fatal "conda install failed; see run.log"
    fi
    if [ ! -f chipyard/env.sh ]; then
        step "setup: build-setup.sh (README step 3, ~40 min)" \
            nix run .#fhs -- -c 'cd chipyard && ./build-setup.sh riscv-tools -s 2 -s 4 -s 6 -s 7 -s 8 -s 9' ||
            fatal "chipyard build-setup.sh failed; see run.log"
    fi
    step "setup: check (README step 4)" \
        ./scripts/cy 'firtool --version | tail -1; verilator --version; ls $RISCV/lib/libfesvr.a' ||
        fatal "the chipyard environment is incomplete; see run.log"
    touch "$SETUP_OK"
fi

step "environment (first time: builds the 32-bit gcc)" \
    ./scripts/cy 'riscv32-none-elf-gcc -Q --help=target | grep -E "^\s+-m(arch|abi)="' ||
    fatal "the chipyard environment does not start; see run.log"
step "build (simulators, libgloss, firmware)" ./scripts/mars-fw.sh build || fatal "build failed; see run.log"
step "spike checks" ./scripts/cy 'make -C ../mars/firmware spike-check && make -C ../marsfw spike-check' \
    > "$OUT/spike.out" 2>&1

if [ "${PERF:-1}" = 1 ]; then
    step "perf table" timeout 12h ./scripts/mars-fw.sh perf > "$OUT/perf.out" 2>&1 &
fi

# The perf run holds one simulator; the fuzz runs share the rest.
fuzz_one() {
    timeout 10h ./scripts/mars-fw.sh fuzz "$1" "$2" "$COUNT" > "$OUT/fuzz-$1-s$2.out" 2>&1
    echo "$1 $2 exit $?" >> "$OUT/fuzz-status.txt"
}
export -f fuzz_one
export COUNT OUT
log "start fuzz: $(echo $VARIANTS | wc -w) variants x $(echo $SEEDS | wc -w) seeds x $COUNT commands"
for s in $SEEDS; do for v in $VARIANTS; do echo "$v $s"; done; done |
    xargs -P $(( JOBS - 1 )) -L1 bash -c 'fuzz_one "$0" "$1"'
log "end   fuzz"
wait
summary
log "done"
