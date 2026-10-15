#!/usr/bin/env python3
"""Area of the MarsV2 SoCs per module in SKY130: Yosys synthesis with the sky130_fd_sc_hd
cells at the typical corner and the clock of chipyard's SKY130 example (vlsi/).
The SRAMs in <config>.mems.conf stay black boxes.

    nix shell .#python -c scripts/mars-area.py [CONFIG ...]

Starts from the FIRRTL that a simulator build leaves in chipyard/sims/verilator/generated-src.
Results in area/: <config>.<module>.stat (Yosys `stat` of ChipTop, the MARS clock domain,
Example_MarsV2 and Example_MarsV2Platform), <config>.mems.conf and <config>.log.
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

TESTBED = Path(__file__).resolve().parent.parent
RESULTS = TESTBED / "area"
GENERATED = TESTBED / "chipyard/sims/verilator/generated-src"
VLSI_EXAMPLE = TESTBED / "chipyard/vlsi/example-sky130.yml"
CONFIGS = ["TFMarsV2Config", "TFMarsV2TinyConfig"]


def nix_build(attr):
    out = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", f".#{attr}^out"],
                         cwd=TESTBED, check=True, capture_output=True, text=True)
    return Path(out.stdout.strip())


def clock_period_ps():
    m = re.search(r'name: "clock_uncore", period: "(\d+)ns"', VLSI_EXAMPLE.read_text())
    return int(m.group(1)) * 1000


# OpenROAD's sky130hd dont-use cells (probe, lpflow) and the scan flops Hammer leaves out.
def dont_use_flags(lib):
    cells = re.findall(r'cell \("(sky130_fd_sc_hd__(?:probe|lpflow_|sdf)[a-z0-9_]*)"\)', lib.read_text())
    return " ".join(f"-dont_use {c}" for c in cells)


# The sim build's FIRRTL as Verilog for Yosys, the way chipyard's ENABLE_YOSYS_FLOW emits it.
def firtool(config, out_dir):
    gen = GENERATED / f"chipyard.harness.TestHarness.{config}"
    prefix = gen / f"chipyard.harness.TestHarness.{config}"
    lowering = (gen / ".mfc_lowering_options").read_text().strip()
    cmd = (f"firtool --format=fir --verify-each=true --disable-annotation-classless "
           f"--disable-annotation-unknown --lowering-options={lowering},disallowPackedArrays "
           f"--repl-seq-mem --repl-seq-mem-file={out_dir}.all.mems.conf "
           f"--annotation-file={prefix}.appended.anno.json --split-verilog -o {out_dir} {prefix}.fir")
    with open(RESULTS / f"{config}.firtool.log", "w") as log:
        subprocess.run([TESTBED / "scripts/cy", cmd], check=True, stdout=log, stderr=subprocess.STDOUT)
    shutil.copy(f"{prefix}.top.mems.conf", RESULTS / f"{config}.mems.conf")
    return gen / "gen-collateral" / f"chipyard.harness.TestHarness.{config}.top.mems.v"


# The clock domain that instantiates Example_MarsV2.
def mars_domain(out_dir):
    for f in sorted(out_dir.glob("*.sv")):
        if any(line.startswith("  Example_MarsV2 ") for line in f.read_text().splitlines()):
            return f.stem
    sys.exit(f"no module in {out_dir} instantiates Example_MarsV2")


def yosys_script(config, out_dir, mems_v, lib, dont_use, period):
    sources = sorted(list(out_dir.glob("*.sv")) + list(out_dir.glob("*.v")))
    # The test harness's simulation models (Sim*, ClockSourceAtFreqMHz) sit outside ChipTop.
    sources = [f for f in sources if not re.match(r"(Sim[A-Z]|ClockSourceAtFreqMHz)", f.name)]
    lines = [f"read_verilog -sv {f}" for f in sources]
    lines += [f"read_verilog -sv -lib {mems_v}",
              f"read_liberty -lib {lib}",
              "hierarchy -check -top ChipTop",
              "synth -top ChipTop",
              "opt -purge",
              f"dfflibmap -liberty {lib} {dont_use}",
              "opt",
              f"abc -D {period} -liberty {lib} {dont_use}",
              "setundef -zero",
              "splitnets",
              "opt_clean -purge",
              "hilomap -singleton -hicell sky130_fd_sc_hd__conb_1 HI -locell sky130_fd_sc_hd__conb_1 LO",
              "design -save mapped"]
    for m in ["ChipTop", mars_domain(out_dir), "Example_MarsV2", "Example_MarsV2Platform"]:
        lines += ["design -load mapped",
                  f"hierarchy -top {m}",
                  f"tee -q -o {RESULTS}/{config}.{m}.stat stat -top {m} -liberty {lib}"]
    return "\n".join(lines) + "\n"


def main():
    configs = sys.argv[1:] or CONFIGS
    yosys = nix_build("yosys") / "bin/yosys"
    lib = nix_build("sky130hd-lib")
    dont_use = dont_use_flags(lib)
    period = clock_period_ps()
    RESULTS.mkdir(exist_ok=True)

    for config in configs:
        out_dir = RESULTS / config
        shutil.rmtree(out_dir, ignore_errors=True)
        mems_v = firtool(config, out_dir)
        ys = RESULTS / f"{config}.ys"
        ys.write_text(yosys_script(config, out_dir, mems_v, lib, dont_use, period))
        subprocess.run([yosys, "-q", "-l", RESULTS / f"{config}.log", ys], check=True)

    for stat in sorted(RESULTS.glob("*.stat")):
        print(f"== {stat.relative_to(TESTBED)}")
        text = stat.read_text()
        print(text[text.index("=== design hierarchy ==="):] if "=== design hierarchy ===" in text else "")


if __name__ == "__main__":
    main()
