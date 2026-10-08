# Trustformer Testbed

Simulates a Rocket SoC with a Trustformer-generated module attached as an MMIO
peripheral, under Verilator.

`mars/` is the Trustformer fork of the TCG MARS reference emulator
(github.com/Trustformer/MARS, forked from TrustedComputingGroup at `63a59be`), the
source of the firmware MARS that runs on the Rocket core.

Requires `nix` with flakes enabled, on x86_64 Linux (chipyard's conda environment
is `linux-64` only).

## First-time setup

Steps 2 and 3 build into the checkout and bake its absolute path into conda, into
chipyard's `env.sh` and into the toolchain. They are gitignored rather than shared
for that reason: run them once per clone, and do not copy a `conda/` or `.conda-env/`
from another checkout or another machine. `scripts/cy` refuses to run against one
that was set up elsewhere.

```bash
# 1. Initialize the submodules the build needs (~2 min, 185 MB).
./scripts/init-minimal.sh

# 2. Install conda into the testbed directory.
nix run .#fhs -- -c '
  wget -q "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh" -O Miniforge3.sh
  bash Miniforge3.sh -b -p $HOME/conda'

# 3. Build the chipyard environment: conda packages, toolchain collateral
#    (spike, libfesvr, libgloss), the Scala precompile, and firtool. (~40 min)
nix run .#fhs -- -c 'cd chipyard && ./build-setup.sh riscv-tools -s 2 -s 4 -s 6 -s 7 -s 8 -s 9'

# 4. Check the result.
./scripts/cy 'firtool --version | tail -1; verilator --version; ls $RISCV/lib/libfesvr.a'
```

`scripts/init-minimal.sh` initializes only the submodules the `chipyard` sbt project
needs in order to compile, non-recursively and with `--filter=blob:none`: 34
repositories and a 185 MB tree. The nested RTL of the other generators (nvdla's hw,
cva6's vsrc, ara, VexiiRiscv, radiance's vortex) is only read when *elaborating*
those generators' configs, which this testbed never does.

The `-s` flags in step 3 drop the submodule init (step 1 above did it), ctags,
FireSim and FireMarshal. The steps that run are the conda environment, the toolchain
collateral, the Scala precompile and the firtool install — all four are load-bearing:
the simulator links `libfesvr`, `common.mk` pipes disassembly through `spike-dasm`,
`tests/` compiles against libgloss's `htif_nano.specs`, and `common.mk` invokes
`firtool` by bare name. `firtool` is not part of the conda environment; it comes from
step 10 of `build-setup.sh`.

## Running a simulation

`scripts/cy` runs a command inside the chipyard environment (the FHS sandbox, conda,
and `chipyard/env.sh`) and is how everything here should be invoked. It works from
any directory and from inside an already-running sandbox.

For an interactive shell, `nix develop` from anywhere inside the testbed gives the
same environment except for `chipyard/env.sh`, which you source yourself:

```bash
nix develop
cd chipyard && source ./env.sh
```

```bash
# Bare-metal test binaries.
./scripts/cy 'cd tests && cmake -S ./ -B ./build/ -D CMAKE_BUILD_TYPE=Debug && cmake --build ./build/ --target all'

# The simulator for one config.
./scripts/cy 'cd sims/verilator && make -j$(nproc) CONFIG=TFLockboxTriesConfig'

# Run a binary on it.
./scripts/cy 'cd sims/verilator && make CONFIG=TFLockboxTriesConfig BINARY=$PWD/../../tests/build/lockbox.riscv run-binary'

# Same, but building a simulator that writes a VCD.
./scripts/cy 'cd sims/verilator && make CONFIG=TFLockboxTriesConfig BINARY=$PWD/../../tests/build/lockbox.riscv run-binary-debug'
```

`TFLockboxTriesConfig` is the paper's running example (`coq/Examples/LockboxTries.v`)
at address `0x4000` next to one Rocket core. `tests/lockbox.c` drives it over MMIO,
replaying the `Example`s from that Coq file and checking each result.

`TFMarsConfig` is the one-action MARS (`coq/Examples/Mars/Spec.v`) at `0x4000`, with
its SHA-256 and HMAC IPs, Primary Seed and init request in
`chipyard-trustformer-module/src/main/scala/platform/Example_MarsPlatform.scala`.
`tests/mars.c` replays `sim/tb_mars_v4.sv`'s sequence and checks the reference
emulator's PCR and Quote values; run it as above with `CONFIG=TFMarsConfig` and
`mars.riscv`.

`marsfw/` compares MarsV2 with the firmware MARS on the same SoC (`scripts/mars-fw.sh`,
see `marsfw/README.md`).

`TFMarsV2Config` is MarsV2 (`coq/Examples/MarsV2/Spec.v`): nine of the thirteen MARS
commands, with the fault input tied low in `Example_MarsV2Platform.scala`.
`tests/mars_v2.c` replays `sim/tb_mars_v2.sv`'s sequence over MMIO (69 checks) and
prints each command's core cycles. `LOADMEM=1` loads the ELF straight into DRAM:

```bash
./scripts/cy 'cd sims/verilator && make CONFIG=TFMarsV2Config BINARY=$PWD/../../tests/build/mars_v2.riscv LOADMEM=1 run-binary-fast'
```

## Integrating a Trustformer-generated module

The wire protocol these modules speak is in
`chipyard-trustformer-module/INTERFACE.md`; read it before touching a wrapper.

1. Copy the generated Verilog into
   `chipyard-trustformer-module/src/main/resources/vsrc/`. The file name must match
   the module name declared inside it, so the `BlackBox` resource resolves.
2. If the module has `sec` ports or IP links, write its platform module, which
   drives them: `chipyard-trustformer-module/src/main/scala/platform/<Module>Platform.scala`
   (`INTERFACE.md`, "The platform module"). Only `pub` ports are memory-mapped.
3. Generate the wrapper:
   ```bash
   ./scripts/cy 'cd generators/trustformer && python3 GenerateWrappers.py'
   ```
   This writes `src/main/scala/<Module>Wrapper.scala` and records the register
   addresses it chose in `src/main/resources/regmap/<Module>.json`. To pin an address
   yourself, put it in that JSON before running the generator; keys are the names
   of the `pub` ports (`in_cmd`, `in_param_pub_<x>`, `out_param_pub_<y>`) plus
   `<status>`. Values wider than 32 bits occupy several consecutive 4-byte words.
4. Mix the peripheral into
   `chipyard/generators/chipyard/src/main/scala/DigitalTop.scala`:
   ```scala
   with trustformer.CanHavePeriphery<Module>
   ```
5. Add a config to
   `chipyard/generators/chipyard/src/main/scala/config/TrustformerConfigs.scala`.
   The config class name must not contain an underscore: chipyard splits `CONFIG` on
   `_` to stack config fragments, so `TFExample_FooConfig` is resolved as `TFExample`
   ++ `FooConfig`. The module, the wrapper class and the `CanHavePeriphery*` trait
   may all keep theirs.
   ```scala
   class TF<Name>Config extends Config(
     new trustformer.With<Module>(address=0x4000) ++
     new freechips.rocketchip.rocket.WithNHugeCores(1) ++
     new chipyard.config.AbstractConfig)
   ```
6. Build and run it as above, with `CONFIG=TF<Name>Config`.

## Local deviations from upstream chipyard

* `common.mk`: the include of `generators/radiance/radiance.mk` is guarded on
  radiance's vortex submodule being present. That fragment puts two Vortex package
  sources on the Verilator command line for every config, so without a ~500 MB
  checkout that nothing in our designs uses, no config builds.

## Todo

Figure out the VLSI flow with OpenROAD, to run a static timing analysis on the
generated platform. That would give us a clock frequency for the design, a
comparison against a baseline platform without the Trustformer module (showing we do
not degrade the system clock), and — combined with the cycle counts — a performance
estimate for the module.
