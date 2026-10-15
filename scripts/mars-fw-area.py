#!/usr/bin/env python3
"""SKY130 area of the MarsV2 hardware next to its SoC and the firmware MARS's memory.

    nix shell .#python -c scripts/mars-fw-area.py

Hardware: Example_MarsV2 and its IP platform, per SoC, from scripts/mars-area.py.
SoC: ChipTop's cells plus its SRAMs (area/<config>.mems.conf, instance counts from Yosys).
Firmware: the code and RAM that `size` reports for the marsfw build of the SoC that holds it on chip.
Every SRAM is costed as the cheapest set of OpenRAM single-port macros that holds it (areas from
their LEFs). The firmware counts its own objects only, a lower bound on its memory.
"""
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

TESTBED = Path(__file__).resolve().parent.parent
HARDWARE = ["Example_MarsV2", "Example_MarsV2Platform"]
SOC = "ChipTop"
# Each SoC with the firmware build whose memory is on its chip: TinyRocket runs the firmware from
# its scratchpad, Rocket from off-chip DRAM.
SOCS = {"TFMarsV2TinyConfig": TESTBED / "marsfw/build/tiny/libmarsfw.a",
        "TFMarsV2Config": None}


def nix_build(attr):
    out = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", f".#{attr}^out"],
                         cwd=TESTBED, check=True, capture_output=True, text=True)
    return Path(out.stdout.strip())


def need(path):
    if not path.exists():
        sys.exit(f"missing {path.relative_to(TESTBED)}: build it first (scripts/mars-eval.sh, scripts/mars-area.py)")
    return path


# {object: (text, data, bss)} in bytes, from binutils' `size` on the archive.
def firmware_objects(archive):
    size = nix_build("rv32-gcc") / "bin/riscv32-none-elf-size"
    out = subprocess.run([size, need(archive)], check=True, capture_output=True, text=True).stdout
    rows = [line.split() for line in out.splitlines()[1:]]
    return {r[5]: (int(r[0]), int(r[1]), int(r[2])) for r in rows}


# {macro: (bytes, um^2)}: capacity from the macro's <width>x<depth> name, area from its LEF SIZE.
def sram_macros():
    macros = {}
    for lef in sorted(nix_build("sky130-sram-lefs").glob("*.lef")):
        text = lef.read_text()
        name = re.search(r"^MACRO (\S+)", text, re.M).group(1)
        width, depth = map(int, re.search(r"_(\d+)x(\d+)_", name).groups())
        w, h = map(float, re.search(r"MACRO.*?SIZE ([\d.]+) BY ([\d.]+)", text, re.S).groups())
        macros[name] = (width * depth // 8, w * h)
    return macros


# cover(n): the cheapest multiset of macros holding at least n bytes, as (um^2, [macro, ...]).
def cover_table(macros):
    best, pick = [0.0], [None]

    def cover(n):
        while len(best) <= n:
            k = len(best)
            area, m = min((area + best[max(0, k - cap)], m) for m, (cap, area) in macros.items())
            best.append(area)
            pick.append(m)
        area, used = best[n], []
        while n > 0:
            used.append(pick[n])
            n = max(0, n - macros[pick[n]][0])
        return area, used
    return cover


def stat_text(config, module):
    return need(TESTBED / "area" / f"{config}.{module}.stat").read_text()


# The hierarchical cell area of a Yosys `stat -liberty` report, in um^2.
def stat_area(config, module):
    text = stat_text(config, module)
    m = (re.search(rf"Chip area for top module '\\{module}': ([\d.]+)", text)
         or re.search(rf"Chip area for module '\\{module}': ([\d.]+)", text))
    return float(m.group(1))


# {memory: (bytes, ports, instances)}: the SoC's SRAMs as firtool lists them, counted by Yosys.
def soc_memories(config):
    hierarchy = stat_text(config, SOC).split("=== design hierarchy ===")[1]
    mems = {}
    for line in need(TESTBED / "area" / f"{config}.mems.conf").read_text().splitlines():
        f = dict(zip(line.split()[::2], line.split()[1::2]))
        count = re.findall(rf"^\s+{re.escape(f['name'])}\s+(\d+)\s*$", hierarchy, re.M)[-1]
        mems[f["name"]] = (-(-int(f["depth"]) * int(f["width"]) // 8), f["ports"], int(count))
    return mems


def mm2(um2):
    return f"{um2 / 1e6:.3f} mm^2"


def macro_list(used):
    return " + ".join(f"{n} x {m}" for m, n in sorted(Counter(used).items()))


def report(config, firmware, cover):
    print(f"\n==== {config}")
    hw = {m: stat_area(config, m) for m in HARDWARE}
    print(f"MarsV2 hardware (Yosys cell area)")
    for m, area in hw.items():
        print(f"  {m:24} {mm2(area)}")
    print(f"  {'total':24} {mm2(sum(hw.values()))}")

    print(f"\n{SOC}: cells from Yosys, SRAMs as single-port macros")
    sram_bytes = sram_area = 0.0
    for name, (n, ports, count) in soc_memories(config).items():
        area, used = cover(n)
        sram_bytes += count * n
        sram_area += count * area
        print(f"  {name:40} {count} x {n:6} B {ports:4} {mm2(count * area)}  {count} x ({macro_list(used)})")
    logic = stat_area(config, SOC)
    soc = logic + sram_area
    print(f"  {'SRAM':40} {'':15} {mm2(sram_area)}")
    print(f"  {'cells':40} {'':15} {mm2(logic)}")
    print(f"  {'total':40} {'':15} {mm2(soc)}")
    print(f"\n  {'MarsV2 hardware share of the SoC':40} {'':15} {100 * sum(hw.values()) / soc:.1f}%")

    if firmware is None:
        return
    objects = firmware_objects(firmware)
    code = sum(t for t, _, _ in objects.values())
    ram = sum(d + b for _, d, b in objects.values())
    print(f"\nfirmware MARS, {firmware.relative_to(TESTBED)} (bytes)")
    print(f"  {'object':24} {'code':>6} {'ram':>6}")
    for name, (t, d, b) in objects.items():
        print(f"  {name:24} {t:6} {d + b:6}")
    print(f"  {'total':24} {code:6} {ram:6}")

    print("\nfirmware memory as SRAM macros")
    fw = 0.0
    for label, n in {"code": code, "ram": ram}.items():
        area, used = cover(n)
        fw += area
        print(f"  {label:6} {n:6} B  {mm2(area)}  {macro_list(used)}")
    print(f"  {'total':6} {'':8}  {mm2(fw)}")
    print(f"\n  hardware cell area / firmware memory area: {sum(hw.values()) / fw:.2f}")

    fw_slice = (code + ram) * sram_area / sram_bytes
    print(f"  firmware at the SoC's SRAM area per byte:  {mm2(fw_slice)}, {100 * fw_slice / soc:.1f}% of the SoC")


def main():
    macros = sram_macros()
    print("OpenRAM single-port SKY130 SRAM macros")
    for name, (cap, area) in macros.items():
        print(f"  {name:36} {cap:6} B  {mm2(area)}")

    cover = cover_table(macros)
    for config, firmware in SOCS.items():
        report(config, firmware, cover)


if __name__ == "__main__":
    main()
