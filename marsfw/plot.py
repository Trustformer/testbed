"""Per-command core cycles, firmware MARS vs the MarsV2 hardware, as the paper's bar chart.

    nix shell .#plot -c python3 marsfw/plot.py [perf.csv] [out.pdf]

Defaults: marsfw/results/perf.csv (from scripts/mars-eval.sh) -> marsfw/results/fw_vs_hw.pdf.
"""
import csv
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch

RESULTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results")
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(RESULTS, "perf.csv")
DST = sys.argv[2] if len(sys.argv) > 2 else os.path.join(RESULTS, "fw_vs_hw.pdf")

ROWS = [
    ("CapabilityGet", "CapabilityGet"),
    ("RegRead", "RegRead"),
    ("SelfTest", "SelfTest"),
    ("PcrExtend", "PcrExtend"),
    ("Derive", "Derive"),
    ("Quote-rs0", "Quote, no PCR"),
    ("Quote-rs3", "Quote, 2 PCRs"),
    ("Sign", "Sign"),
    ("SignatureVerify", "SignatureVerify"),
]
CORES = [("huge-core", "Rocket (RV64)"), ("tiny", "TinyRocket (RV32)")]

FW, HW = "#2a78d6", "#eb6834"
INK, MUTED, GRID = "#0b0b0b", "#52514e", "#dddcd7"
X0, XMAX = 10, 5e5

plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["STIXGeneral"],
    "mathtext.fontset": "stix",
    "font.size": 7.5,
    "pdf.fonttype": 42,
    "text.color": INK,
    "axes.labelcolor": INK,
    "xtick.color": MUTED,
    "ytick.color": INK,
})

with open(SRC) as f:
    perf = {(r["build"], r["shape"]): (int(r["fw_median"]), int(r["hw_median"])) for r in csv.DictReader(f)}

fig, axes = plt.subplots(1, 2, figsize=(3.5, 2.6), sharey=True)
for ax, (build, title) in zip(axes, CORES):
    for i, (shape, _) in enumerate(ROWS):
        fw, hw = perf[(build, shape)]
        ax.barh(i - 0.18, fw - X0, left=X0, height=0.32, color=FW, linewidth=0)
        ax.barh(i + 0.18, hw - X0, left=X0, height=0.32, color=HW, linewidth=0)
        ratio = fw / hw
        ax.text(fw * 1.3, i - 0.18, f"{ratio:.0f}×" if ratio >= 10 else f"{ratio:.1f}×",
                va="center", ha="left", fontsize=6.5, color=MUTED)
    ax.set_title(title, fontsize=7.5, pad=3)
    ax.set_xscale("log")
    ax.set_xlim(X0, XMAX)
    ax.set_xticks([10, 100, 1e3, 1e4, 1e5], ["10", "100", "1k", "10k", "100k"])
    ax.minorticks_off()
    ax.grid(axis="x", color=GRID, linewidth=0.5, linestyle="-")
    ax.set_axisbelow(True)
    ax.tick_params(length=0, pad=2)
    for side in ("top", "right", "bottom"):
        ax.spines[side].set_visible(False)
    ax.spines["left"].set_color(MUTED)
    ax.spines["left"].set_linewidth(0.6)

axes[0].set_yticks(range(len(ROWS)), [label for _, label in ROWS])
axes[0].invert_yaxis()
fig.legend(handles=[Patch(color=FW, label="Firmware (Baseline)"),
                    Patch(color=HW, label="Synthesized Module")],
           loc="upper center", ncol=2, frameon=False, fontsize=7, handlelength=1.2,
           columnspacing=1.2, bbox_to_anchor=(0.6, 1.0))
fig.text(0.6, 0.015, "Core cycles (log scale)", ha="center", fontsize=7.5)
fig.subplots_adjust(left=0.24, right=0.98, top=0.84, bottom=0.12, wspace=0.08)
fig.savefig(DST)
print(f"wrote {DST}")
