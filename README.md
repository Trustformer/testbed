# Trustformer Testbed

## First Time Setup

To setup [chipyard](https://chipyard.readthedocs.io/en/latest/index.html) for the first time follow the [inital repository setup instructions](https://chipyard.readthedocs.io/en/latest/Chipyard-Basics/Initial-Repo-Setup.html) within a nix dev shell.
At the time of writing this consists of the following steps:
> Todo: Check if these steps work on a clean repo

1. Enter the dev shell, this shell has the current folder set as home to keep all conda environments isolated.
```bash
nix develop
```

2. Download and install Miniforge
```bash
wget "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-$(uname)-$(uname -m).sh"
bash Miniforge3-$(uname)-$(uname -m).sh -b -p $HOME/conda
```

4. Activate the conda base environment
```bash
source ~/conda/etc/profile.d/conda.sh
conda activate base
```

5. Initialize the relevant submodules, the simplest way is to initialize all:
```bash
git submodule update --init --recursive
```

6. Initialize chipyard, (we skip setup of FireSim, FireMarshal and CIRCT for now, since we don't use them)
```bash
cd chipyard
./build-setup.sh riscv-tools -s 6 -s 7 -s 8 -s 9 -s 10
```

## Entering Dev environment

This is mostly dependent on the chipyard framework, so refer to the chipyard documentation for exact details.
In most cases the following suffices:

1. Entering the dev shell 
```bash
nix develop
```

2. Activate the chipyard conda environment
```bash
cd chipyard
source ./env.sh
```

## Running a simulation
```bash
cd tests/
cmake -S ./ -B ./build/ -D CMAKE_BUILD_TYPE=Debug
cmake --build ./build/ --target all
cd ../sims/verilator/
make CONFIG=TFCustomCounterConfig BINARY=../../tests/build/custom_ctr.riscv run-binary-debug
```

## Integrating a Trustformer generated module

1. Add the generated verilog file to `chipyard-trustformer-module/src/main/resources/vsrc`

2. Create a register map for the module in `chipyard-trustformer-module/src/main/resources/vsrc`, make sure it uses the same name with a `.json` extension:
The address is the offset from where the module will be mapped to (default: `0x4000`). For more information read `chipyard-trustformer-module/README.md`. 
```json
{
    "<status>": {
        "address": "0x00"
    },
    "read_command": {
        "address": "0x04"
    },
    "read_arg": {
        "address": "0x08"
    },
    "write_result": {
        "address": "0x0C"
    }
}
```

3. Generate the wrapper for this module by calling `chipyard-trustformer-module/GenerateWrappers.py`. This should produce a new file `chipyard-trustformer-module/src/main/scala/{ModuleName}Wrapper.scala`

4. Inform chipyard that designs may use this newly generated module by modifying `chipyard/generators/chipyard/src/main/scala/DigitalTop.scala`. Add the following line:
```scala
with trustformer.CanHavePeriphery{ModuleName}
```

5. Create a design that uses the newly generated Module, by add ing a config to `chipyard/generators/chipyard/src/main/scala/config/TrustformerConfigs.scala`, the minimal configuration would look like this:
```scala
class TF{ModuleName} extends Config(
  new trustformer.With{ModuleName}(address=0x4000) ++ // Your custom module at address 0x4000
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++ // with a single rocket core
  new chipyard.config.AbstractConfig)
```

6. Now you can use this config e.g, during simulation:
```bash
cd chipyard/sims/verilator/
make CONFIG=TF{ModuleName} ...
```

## Todo

Figure out VLSI flow with OpenROAD, in order to perform a Static Timing Analysis on the generated platform.
This allows us to:
    - get a value for the clock frequency our design can achieve
    - compare the timing results with a baseline platform without the trustformer module & show that we do not impact system clock frequency
    - with clk_freq + cycle measurements we can estimate the performance of our module