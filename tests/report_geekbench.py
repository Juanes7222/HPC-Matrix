"""
report_geekbench.py -- Geekbench 6 comparison report for two machines.

Reads geekbench_result.json from two machine folders and generates:
  - Excel workbook with scores, workload breakdown and charts
  - PNG charts (single-core, multi-core, workload comparison)
  - LaTeX table snippet

Usage:
    python3 tests/benchmarks/report_geekbench.py
    python3 tests/benchmarks/report_geekbench.py machine1 machine2
"""

from __future__ import annotations

import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill


BASE_DIR   = "tests/benchmarks/results_geekbench"
LABELS     = sys.argv[1:3] if len(sys.argv) >= 3 else None
CHARTS_DIR = os.path.join(BASE_DIR, "charts_geekbench")
XLSX_PATH  = os.path.join(BASE_DIR, "reporte_geekbench.xlsx")


try:
    sys.path.insert(0, "tests/benchmarks")
    from report_utils import (
        C, CHART_STYLE, FONT_NAME,
        make_border, set_col_width, style_data_cell, style_header_cell,
        write_title_row, save_figure,
    )
    _HAS_UTILS = True
except ImportError:
    _HAS_UTILS = False
    FONT_NAME = "Arial"
    C = {
        "dark": "1F4E79", "mid": "2E75B6", "light": "D6E4F0",
        "alt": "F2F9FF", "white": "FFFFFF", "green_bg": "E2EFDA",
        "green_fg": "375623", "red_bg": "FCE4D6", "border": "BDD7EE",
    }
    CHART_STYLE = {
        "figure.facecolor": "white", "axes.facecolor": "white",
        "axes.grid": True, "grid.color": "#E8E8E8",
        "axes.spines.top": False, "axes.spines.right": False,
    }

    def save_figure(fig, charts_dir, name):
        path = os.path.join(charts_dir, name)
        fig.savefig(path, dpi=180, bbox_inches="tight")
        plt.close(fig)
        return path

    def make_border():
        from openpyxl.styles import Border, Side
        s = Side(style="thin", color=C["border"])
        return Border(left=s, right=s, top=s, bottom=s)

    def set_col_width(ws, col, width):
        from openpyxl.utils import get_column_letter
        ws.column_dimensions[get_column_letter(col)].width = width

    def style_header_cell(cell, value, bg="dark", size=10):
        cell.value = value
        cell.font = Font(name=FONT_NAME, bold=True, color=C["white"], size=size)
        cell.fill = PatternFill("solid", fgColor=C.get(bg, bg))
        cell.alignment = Alignment(horizontal="center", vertical="center",
                                   wrap_text=True)
        cell.border = make_border()

    def style_data_cell(cell, value, fmt=None, bg="white", fg="000000",
                        bold=False, align="right"):
        cell.value = value
        cell.font = Font(name=FONT_NAME, bold=bold, color=C.get(fg, fg), size=10)
        cell.fill = PatternFill("solid", fgColor=C.get(bg, bg))
        cell.alignment = Alignment(horizontal=align, vertical="center")
        cell.border = make_border()
        if fmt:
            cell.number_format = fmt

    def write_title_row(ws, text, n_cols, row=1):
        from openpyxl.utils import get_column_letter
        ws.merge_cells(f"A{row}:{get_column_letter(n_cols)}{row}")
        cell = ws.cell(row=row, column=1, value=text)
        cell.font = Font(name=FONT_NAME, bold=True, size=13, color=C["white"])
        cell.fill = PatternFill("solid", fgColor=C["dark"])
        cell.alignment = Alignment(horizontal="center", vertical="center")
        ws.row_dimensions[row].height = 24


MACHINE_COLORS = ["#2E75B6", "#C00000"]


def discover_machines() -> list[str]:
    """Return sorted list of machine label folders found in BASE_DIR."""
    if not os.path.isdir(BASE_DIR):
        return []
    return sorted(
        d for d in os.listdir(BASE_DIR)
        if os.path.isdir(os.path.join(BASE_DIR, d))
        and os.path.isfile(os.path.join(BASE_DIR, d, "geekbench_result.json"))
    )

def load_result(label: str) -> dict:
    path = os.path.join(BASE_DIR, label, "geekbench_result.json")
    with open(path) as f:
        return json.load(f)

def extract_scores(data: dict) -> dict:
    """Return {overall_single, overall_multi, workloads: [{name, sc, mc}]}."""
    sc = data.get("score", {})
    workloads = []
    for section in data.get("sections", []):
        for wb in section.get("workloads", []):
            sc_wb = wb.get("score", {})
            workloads.append({
                "section":     section.get("name", ""),
                "name":        wb.get("name", ""),
                "single_core": sc_wb.get("single_core", 0) or 0,
                "multi_core":  sc_wb.get("multi_core",  0) or 0,
            })
    return {
        "single_core": sc.get("single_core", 0) or 0,
        "multi_core":  sc.get("multi_core",  0) or 0,
        "workloads":   workloads,
    }

def load_machine_info(label: str) -> str:
    path = os.path.join(BASE_DIR, label, "machine_info.txt")
    if os.path.isfile(path):
        return open(path).read()
    return "No machine info available."


def chart_overall(machines: list[str], scores: dict[str, dict]) -> str:
    labels     = ["Single-Core Score", "Multi-Core Score"]
    bar_width  = 0.35
    x          = [0, 1]

    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(8, 5))
        for mi, machine in enumerate(machines):
            vals = [
                scores[machine]["single_core"],
                scores[machine]["multi_core"],
            ]
            offsets = [xi + (mi - len(machines) / 2 + 0.5) * bar_width
                       for xi in x]
            bars = ax.bar(offsets, vals, width=bar_width * 0.9,
                          color=MACHINE_COLORS[mi], label=machine,
                          edgecolor="white", alpha=0.88)
            for bar, val in zip(bars, vals):
                ax.text(bar.get_x() + bar.get_width() / 2,
                        bar.get_height() + max(
                            scores[m]["multi_core"] for m in machines) * 0.01,
                        f"{int(val):,}", ha="center", va="bottom",
                        fontsize=9, fontweight="bold")

        ax.set_xticks(x)
        ax.set_xticklabels(labels, fontsize=11)
        ax.set_ylabel("Geekbench 6 Score", fontsize=10)
        ax.set_title("Geekbench 6 — Overall Score Comparison",
                     fontsize=13, fontweight="bold", pad=10)
        ax.legend(fontsize=10)
        fig.tight_layout()
        return save_figure(fig, CHARTS_DIR, "overall_scores.png")

def chart_workloads(machines: list[str], scores: dict[str, dict],
                    metric: str, title: str, filename: str) -> str:
    """Grouped bar chart for all workloads, single or multi core."""
    all_names = []
    seen = set()
    for m in machines:
        for wb in scores[m]["workloads"]:
            if wb["name"] not in seen:
                all_names.append(wb["name"])
                seen.add(wb["name"])

    def get_score(machine, wname):
        for wb in scores[machine]["workloads"]:
            if wb["name"] == wname:
                return wb[metric]
        return 0

    bar_width = 0.35
    x = list(range(len(all_names)))

    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(max(12, len(all_names) * 1.2), 6))
        for mi, machine in enumerate(machines):
            vals = [get_score(machine, n) for n in all_names]
            offsets = [xi + (mi - len(machines) / 2 + 0.5) * bar_width
                       for xi in x]
            ax.bar(offsets, vals, width=bar_width * 0.9,
                   color=MACHINE_COLORS[mi], label=machine,
                   edgecolor="white", alpha=0.88)

        ax.set_xticks(x)
        ax.set_xticklabels(all_names, rotation=35, ha="right", fontsize=8)
        ax.set_ylabel("Score", fontsize=10)
        ax.set_title(title, fontsize=12, fontweight="bold", pad=8)
        ax.legend(fontsize=10)
        fig.tight_layout()
        return save_figure(fig, CHARTS_DIR, filename)

def chart_speedup_ratio(machines: list[str], scores: dict[str, dict]) -> str:
    """Bar chart: machine2 / machine1 ratio per workload (multi-core)."""
    if len(machines) < 2:
        return ""

    m1, m2 = machines[0], machines[1]
    names, ratios = [], []
    for wb in scores[m1]["workloads"]:
        sc1 = wb["multi_core"]
        sc2 = next(
            (w["multi_core"] for w in scores[m2]["workloads"]
             if w["name"] == wb["name"]), 0
        )
        if sc1 > 0 and sc2 > 0:
            names.append(wb["name"])
            ratios.append(sc2 / sc1)

    colors = ["#70AD47" if r >= 1 else "#C00000" for r in ratios]

    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(max(12, len(names) * 1.2), 5))
        bars = ax.bar(range(len(names)), ratios, color=colors, edgecolor="white")
        for bar, val in zip(bars, ratios):
            ax.text(bar.get_x() + bar.get_width() / 2,
                    bar.get_height() + 0.01,
                    f"{val:.2f}x", ha="center", va="bottom", fontsize=8)
        ax.axhline(1.0, color="#AAAAAA", lw=1.5, ls="--",
                   label=f"ref: {m1}")
        ax.set_xticks(range(len(names)))
        ax.set_xticklabels(names, rotation=35, ha="right", fontsize=8)
        ax.set_ylabel(f"Ratio ({m2} / {m1})", fontsize=10)
        ax.set_title(f"Multi-Core Performance Ratio: {m2} vs {m1}",
                     fontsize=12, fontweight="bold", pad=8)
        ax.legend(fontsize=9)
        fig.tight_layout()
        return save_figure(fig, CHARTS_DIR, "speedup_ratio.png")


def write_overview_sheet(wb: Workbook, machines: list[str],
                         scores: dict[str, dict]) -> None:
    ws = wb.create_sheet("Overview")
    write_title_row(ws, "Geekbench 6 — Machine Comparison", 4)

    headers = ["Metric", *machines, "Ratio (M2/M1)"]
    for ci, h in enumerate(headers, 1):
        style_header_cell(ws.cell(2, ci), h, bg="mid")
        set_col_width(ws, ci, 22)
    ws.row_dimensions[2].height = 22

    rows_data = [
        ("Single-Core Score",
         scores[machines[0]]["single_core"],
         scores[machines[1]]["single_core"] if len(machines) > 1 else "-"),
        ("Multi-Core Score",
         scores[machines[0]]["multi_core"],
         scores[machines[1]]["multi_core"] if len(machines) > 1 else "-"),
    ]

    for ri, (label, v1, v2) in enumerate(rows_data, 3):
        bg = "alt" if ri % 2 == 0 else "white"
        style_data_cell(ws.cell(ri, 1), label, bg="light",
                        bold=True, align="left")
        style_data_cell(ws.cell(ri, 2), v1, fmt="#,##0", bg=bg)
        style_data_cell(ws.cell(ri, 3), v2, fmt="#,##0", bg=bg)
        if isinstance(v1, (int, float)) and isinstance(v2, (int, float)) and v1 > 0:
            ratio = round(v2 / v1, 4)
            fg = "green_fg" if ratio >= 1 else "red_fg"
            bg_r = "green_bg" if ratio >= 1 else "red_bg"
            style_data_cell(ws.cell(ri, 4), ratio, fmt="0.0000",
                            bg=bg_r, fg=fg, bold=True)
        else:
            style_data_cell(ws.cell(ri, 4), "-", bg=bg, align="center")

def write_workloads_sheet(wb: Workbook, machines: list[str],
                          scores: dict[str, dict]) -> None:
    ws = wb.create_sheet("Workloads")
    n_cols = 1 + len(machines) * 2 + 1
    write_title_row(ws, "Geekbench 6 — Workload Breakdown", n_cols)

    headers = ["Workload"]
    for m in machines:
        headers += [f"{m}\nSingle", f"{m}\nMulti"]
    headers.append("Ratio MC\n(M2/M1)")

    for ci, h in enumerate(headers, 1):
        style_header_cell(ws.cell(2, ci), h, bg="mid")
        set_col_width(ws, ci, 20 if ci == 1 else 14)
    ws.row_dimensions[2].height = 28

    all_workloads = []
    seen = set()
    for m in machines:
        for wb_item in scores[m]["workloads"]:
            if wb_item["name"] not in seen:
                all_workloads.append(wb_item)
                seen.add(wb_item["name"])

    prev_section = None
    ri = 3
    for item in all_workloads:
        if item["section"] != prev_section:
            from openpyxl.utils import get_column_letter
            ws.merge_cells(f"A{ri}:{get_column_letter(n_cols)}{ri}")
            c = ws.cell(ri, 1, value=item["section"])
            c.font = Font(name=FONT_NAME, bold=True, size=10, color=C["white"])
            c.fill = PatternFill("solid", fgColor=C["dark"])
            c.alignment = Alignment(horizontal="left", vertical="center",
                                    indent=1)
            ws.row_dimensions[ri].height = 18
            ri += 1
            prev_section = item["section"]

        bg = "alt" if ri % 2 == 0 else "white"
        style_data_cell(ws.cell(ri, 1), item["name"],
                        bg="light", align="left", bold=True)

        sc1_mc = 0
        for mi, m in enumerate(machines):
            match = next(
                (w for w in scores[m]["workloads"] if w["name"] == item["name"]),
                None
            )
            sc_val = match["single_core"] if match else 0
            mc_val = match["multi_core"]  if match else 0
            if mi == 0:
                sc1_mc = mc_val
            style_data_cell(ws.cell(ri, 2 + mi * 2), sc_val, fmt="#,##0", bg=bg)
            style_data_cell(ws.cell(ri, 3 + mi * 2), mc_val, fmt="#,##0", bg=bg)

        if len(machines) >= 2:
            m2_match = next(
                (w for w in scores[machines[1]]["workloads"]
                 if w["name"] == item["name"]), None
            )
            sc2_mc = m2_match["multi_core"] if m2_match else 0
            ratio_col = 2 + len(machines) * 2
            if sc1_mc > 0 and sc2_mc > 0:
                ratio = round(sc2_mc / sc1_mc, 4)
                fg   = "green_fg" if ratio >= 1 else "red_fg"
                bg_r = "green_bg" if ratio >= 1 else "red_bg"
                style_data_cell(ws.cell(ri, ratio_col), ratio,
                                fmt="0.0000", bg=bg_r, fg=fg, bold=True)
            else:
                style_data_cell(ws.cell(ri, ratio_col), "-",
                                bg=bg, align="center")
        ri += 1

def write_machine_info_sheet(wb: Workbook, machines: list[str]) -> None:
    ws = wb.create_sheet("Machine Info")
    write_title_row(ws, "Hardware Specifications", 2)
    set_col_width(ws, 1, 40)
    set_col_width(ws, 2, 80)

    ri = 3
    for machine in machines:
        from openpyxl.utils import get_column_letter
        ws.merge_cells(f"A{ri}:B{ri}")
        c = ws.cell(ri, 1, value=f"=== {machine} ===")
        c.font = Font(name=FONT_NAME, bold=True, size=11, color=C["white"])
        c.fill = PatternFill("solid", fgColor=C["mid"])
        c.alignment = Alignment(horizontal="left", vertical="center", indent=1)
        ws.row_dimensions[ri].height = 20
        ri += 1

        info_text = load_machine_info(machine)
        for line in info_text.splitlines():
            if not line.strip():
                ri += 1
                continue
            bg = "alt" if ri % 2 == 0 else "white"
            style_data_cell(ws.cell(ri, 1), line, bg=bg, align="left")
            ri += 1
        ri += 1

def write_charts_sheet(wb: Workbook, paths: list[str]) -> None:
    from openpyxl.drawing.image import Image as XLImage
    ws = wb.create_sheet("Charts")
    write_title_row(ws, "Visual Comparison | Geekbench 6", 12)
    anchors = ["A2", "M2", "A28", "M28", "A54", "M54"]
    for anchor, path in zip(anchors, paths):
        if path and os.path.exists(path):
            img = XLImage(path)
            img.width  = 700
            img.height = 380
            ws.add_image(img, anchor)


def write_latex_table(machines: list[str], scores: dict[str, dict]) -> None:
    m1 = machines[0]
    m2 = machines[1] if len(machines) > 1 else None

    lines = [
        r"\begin{table}[h]",
        r"\centering",
        r"\caption{Comparativa de rendimiento Geekbench 6 entre máquinas}",
        r"\label{tab:geekbench}",
    ]

    if m2:
        lines += [
            r"\begin{tabular}{lrrr}",
            r"\toprule",
            f"Métrica & {m1} & {m2} & Ratio ($M_2/M_1$) \\\\",
            r"\midrule",
        ]
        sc1 = scores[m1]["single_core"]
        sc2 = scores[m2]["single_core"]
        mc1 = scores[m1]["multi_core"]
        mc2 = scores[m2]["multi_core"]
        lines += [
            f"Single-Core Score & {sc1:,} & {sc2:,} & {sc2/sc1:.3f} \\\\",
            f"Multi-Core Score  & {mc1:,} & {mc2:,} & {mc2/mc1:.3f} \\\\",
        ]
        lines += [
            r"\midrule",
            r"\multicolumn{4}{l}{\small Workloads (Multi-Core)} \\",
            r"\midrule",
        ]
        for wb_item in scores[m1]["workloads"]:
            name = wb_item["name"].replace("&", r"\&")
            v1 = wb_item["multi_core"]
            v2_item = next(
                (w for w in scores[m2]["workloads"]
                 if w["name"] == wb_item["name"]), None
            )
            v2 = v2_item["multi_core"] if v2_item else 0
            ratio = f"{v2/v1:.3f}" if v1 > 0 and v2 > 0 else "-"
            lines.append(f"\\quad {name} & {v1:,} & {v2:,} & {ratio} \\\\")
    else:
        lines += [
            r"\begin{tabular}{lr}",
            r"\toprule",
            f"Métrica & {m1} \\\\",
            r"\midrule",
            f"Single-Core Score & {scores[m1]['single_core']:,} \\\\",
            f"Multi-Core Score  & {scores[m1]['multi_core']:,} \\\\",
        ]

    lines += [r"\bottomrule", r"\end{tabular}", r"\end{table}"]
    out_path = os.path.join(BASE_DIR, "geekbench_table.tex")
    with open(out_path, "w") as f:
        f.write("\n".join(lines))
    print(f"LaTeX table: {out_path}")


def main() -> None:
    os.makedirs(CHARTS_DIR, exist_ok=True)

    machines = LABELS or discover_machines()
    if not machines:
        print(f"No machine result folders found in {BASE_DIR}/")
        print("Run bench_geekbench.sh on each machine first.")
        sys.exit(1)
    if len(machines) > 2:
        machines = machines[:2]
        print(f"Using first two machines: {machines}")

    print(f"Machines: {machines}")
    scores = {m: extract_scores(load_result(m)) for m in machines}

    for m in machines:
        sc = scores[m]
        print(f"  {m}: SC={sc['single_core']:,}  MC={sc['multi_core']:,}")

    print("Generating charts...")
    chart_paths = [
        chart_overall(machines, scores),
        chart_workloads(machines, scores, "single_core",
                        "Single-Core Workload Scores",
                        "workloads_single.png"),
        chart_workloads(machines, scores, "multi_core",
                        "Multi-Core Workload Scores",
                        "workloads_multi.png"),
        chart_speedup_ratio(machines, scores),
    ]
    chart_paths = [p for p in chart_paths if p]
    for p in chart_paths:
        print(f"  {os.path.basename(p)}")

    print("Building workbook...")
    wb = Workbook()
    if wb.active:
        wb.remove(wb.active)

    write_overview_sheet(wb, machines, scores)
    write_workloads_sheet(wb, machines, scores)
    write_machine_info_sheet(wb, machines)
    write_charts_sheet(wb, chart_paths)

    wb.save(XLSX_PATH)
    print(f"Saved: {XLSX_PATH}")

    write_latex_table(machines, scores)
    print("Done.")

if __name__ == "__main__":
    main()