# Trustformer Testbed

Simulates a Rocket SoC with a Trustformer-generated module attached as an MMIO
peripheral, under Verilator.

Everything below has been run end to end on a clean machine; the commands are the
ones that actually work, not the ones chipyard's documentation suggests.

## First-time setup

Two things differ from chipyard's own instructions, and both matter:

* **Do not pull all submodules.** `scripts/init-minimal.sh` initializes only the
  submodules the `chipyard` sbt project needs to compile, non-recursively and with
  `--filter=blob:none`. That is 34 repositories and a 185 MB tree, against several
  gigabytes for a full recursive init. The nested RTL (nvdla's hw, cva6's vsrc,
  ara, VexiiRiscv, radiance's vortex) is only needed to *elaborate* configs we
  never build.
* **Do not skip build-setup step 10.** It is the only thing that installs
  `firtool`, which is not in chipyard's conda lockfile and which `common.mk`
  invokes by bare name. Steps 3 and 5 are needed too (`libfesvr`, `spike-dasm`,
  libgloss's `htif_nano.specs`).

```bash
# 1. curated submodule init (~2 min)
./scripts/init-minimal.sh

# 2. conda, into the testbed directory (the FHS shell sets HOME=$(pwd))
nix run .#fhs -- -c '
  wget -q "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh" -O Miniforge3.sh
  bash Miniforge3.sh -b -p $HOME/conda'

# 3. chipyard setup: conda env, toolchain collateral, scala precompile, firtool
#    (skip 2 -- done above; 4 ctags; 6/7 FireSim; 8/9 FireMarshal). ~40 min.
nix run .#fhs -- -c 'cd chipyard && ./build-setup.sh riscv-tools -s 2 -s 4 -s 6 -s 7 -s 8 -s 9'
```

Sanity check:

```bash
./scripts/cy 'firtool --version | head -1; verilator --version; ls $RISCV/lib/libfesvr.a'
```

## Running things

`scripts/cy` runs a command inside the chipyard environment (FHS sandbox + conda +
`env.sh`). Use it for everything; `nix develop --command <cmd>` **silently does
nothing** for an FHS shell — the shellHook execs the sandbox and drops the command,
then exits 0.

```bash
# build the bare-metal test binaries
./scripts/cy 'cd tests && cmake -S ./ -B ./build/ -D CMAKE_BUILD_TYPE=Debug && cmake --build ./build/ --target all'

# build the simulator and run one binary on it
./scripts/cy 'cd sims/verilator && make -j$(nproc) CONFIG=TFLockboxTriesConfig'
./scripts/cy 'cd sims/verilator && make CONFIG=TFLockboxTriesConfig BINARY=$PWD/../../tests/build/lockbox.riscv run-binary'

# same, with a VCD (needs its own simulator build)
./scripts/cy 'cd sims/verilator && make CONFIG=TFLockboxTriesConfig BINARY=$PWD/../../tests/build/lockbox.riscv run-binary-debug'
```

`TFLockboxTriesConfig` is the paper's running example
(`coq/Examples/LockboxTries.v`) at `0x4000` next to one Rocket core;
`tests/lockbox.c` replays that file's `Example`s over MMIO and self-checks.

> **Config names must not contain `_`.** chipyard splits `CONFIG` on `_` to stack
> config fragments, so `TFExample_LockboxTriesConfig` is looked up as `TFExample`
> ++ `LockboxTriesConfig` and dies with `ClassNotFoundException`. The module and
> the wrapper may keep the underscore; the config class may not.

## Integrating a Trustformer-generated module

The wire protocol these modules speak is documented in
`chipyard-trustformer-module/INTERFACE.md` — read it before touching the wrapper.

1. Copy the generated Verilog into
   `chipyard-trustformer-module/src/main/resources/vsrc/`. The file name must match
   the module name inside it.
2. Optionally pin the register addresses in
   `chipyard-trustformer-module/src/main/resources/regmap/<Module>.json`; anything
   you leave out is assigned the next free 4-byte slot. Keys are the
   external-function names (`in_cmd`, `in_param_<x>`, `out_param_<y>`) plus
   `<status>`.
3. `./scripts/cy 'cd generators/trustformer && python3 GenerateWrappers.py'`
4. Mix `trustformer.CanHavePeriphery<Module>` into
   `chipyard/generators/chipyard/src/main/scala/DigitalTop.scala`.
5. Add a config (no `_` in the class name) to
   `chipyard/generators/chipyard/src/main/scala/config/TrustformerConfigs.scala`:
   ```scala
   class TF<Name>Config extends Config(
     new trustformer.With<Module>(address=0x4000) ++
     new freechips.rocketchip.rocket.WithNHugeCores(1) ++
     new chipyard.config.AbstractConfig)
   ```

## Local deviations from upstream chipyard

* `common.mk`: the include of `generators/radiance/radiance.mk` is guarded on the
  presence of radiance's vortex submodule. That fragment unconditionally puts two
  Vortex package sources on the Verilator command line, so *every* config fails to
  build without a ~500 MB checkout that nothing in our designs uses.

## Todo

Figure out the VLSI flow with OpenROAD, to run a static timing analysis on the
generated platform. That would give us a clock frequency for the design, a
comparison against a baseline platform without the Trustformer module (showing we
do not degrade the system clock), and — combined with the cycle counts — a
performance estimate for the module.
