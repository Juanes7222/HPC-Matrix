import os
import sys
import statistics

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import pandas as pd
from openpyxl import Workbook
from openpyxl.drawing.image import Image as XLImage
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter


CSV_PATH    = sys.argv[1] if len(sys.argv) > 1 else "results_cache/data_cache.csv"
OUT_DIR     = os.path.dirname(os.path.abspath(CSV_PATH))
OUTPUT_PATH = os.path.join(OUT_DIR, "reporte_cache.xlsx")
CHARTS_DIR  = os.path.join(OUT_DIR, "charts_cache")

IMPLS_ORDER = ["std", "cache"]

IMPL_LABELS = {
    "std":   "Standard  (i-j-k)",
    "cache": "Transposed  (row × row)",
}

IMPL_COLORS = {
    "std":   "#C00000",
    "cache": "#2E75B6",
}

IMPL_DESC = {
    "std": (
        "Loop order i-k-j. matrix2[k][j] accesses row k sequentially — "
        "already cache-friendly. matrix1[i][k] is a scalar reused across "
        "all j iterations (register). One of the better naive orderings."
    ),
    "cache": (
        "Transposes matrix2 before multiplying. Inner loop accesses "
        "matrix2T[j][k] row-by-row, matching matrix1[i][k] access pattern. "
        "Both operands advance sequentially in memory on every inner step."
    ),
}

FN = "Arial"
C = {
    "dark":     "1F4E79",
    "mid":      "2E75B6",
    "light":    "D6E4F0",
    "alt":      "F2F9FF",
    "white":    "FFFFFF",
    "green_bg": "E2EFDA",
    "green_fg": "375623",
    "red_bg":   "FCE4D6",
    "red_fg":   "843C0C",
    "border":   "BDD7EE",
}


def _bd():
    s = Side(style="thin", color=C["border"])
    return Border(left=s, right=s, top=s, bottom=s)


def _cw(ws, col, w):
    ws.column_dimensions[get_column_letter(col)].width = w


def hcell(cell, value, bg="dark", size=10):
    cell.value     = value
    cell.font      = Font(name=FN, bold=True, color=C["white"], size=size)
    cell.fill      = PatternFill("solid", fgColor=C[bg])
    cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    cell.border    = _bd()


def dcell(cell, value, fmt=None, bg="white", fg="000000",
          bold=False, align="right"):
    cell.value     = value
    cell.font      = Font(name=FN, bold=bold, color=C.get(fg, fg), size=10)
    cell.fill      = PatternFill("solid", fgColor=C.get(bg, bg))
    cell.alignment = Alignment(horizontal=align, vertical="center")
    cell.border    = _bd()
    if fmt:
        cell.number_format = fmt


def title_row(ws, text, n_cols, row=1):
    ws.merge_cells(f"A{row}:{get_column_letter(n_cols)}{row}")
    c = ws.cell(row=row, column=1, value=text)
    c.font      = Font(name=FN, bold=True, size=13, color=C["white"])
    c.fill      = PatternFill("solid", fgColor=C["dark"])
    c.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[row].height = 24

# ---------------------------------------------------------------------------
# data loading
# ---------------------------------------------------------------------------

def load_data(path):
    df = pd.read_csv(path)
    df.columns         = [c.strip().lower() for c in df.columns]
    df["impl"]         = df["impl"].str.strip('"')
    df["matrix_size"]  = df["matrix_size"].astype(int)
    df["repetition"]   = df["repetition"].astype(int)
    df["wall_time_ms"] = df["wall_time_ms"].astype(float)
    return df

# ---------------------------------------------------------------------------
# charts
# ---------------------------------------------------------------------------

MSTYLE = {
    "figure.facecolor": "white",
    "axes.facecolor":   "white",
    "axes.grid":        True,
    "grid.color":       "#E8E8E8",
    "grid.linewidth":   0.7,
    "axes.spines.top":  False,
    "axes.spines.right":False,
    "font.family":      "DejaVu Sans",
}


def _save(fig, name):
    path = os.path.join(CHARTS_DIR, name)
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    return path


def chart_time_grouped(avgs, sizes, impls):
    """Grouped bar chart: time per size, one group per size."""
    with plt.rc_context(MSTYLE):
        fig, ax = plt.subplots(figsize=(10, 6))
        n       = len(impls)
        w       = 0.35
        x       = list(range(len(sizes)))

        for i, impl in enumerate(impls):
            vals    = [avgs[impl].get(s, 0) for s in sizes]
            offsets = [xi + (i - n / 2 + 0.5) * w for xi in x]
            bars    = ax.bar(offsets, vals, width=w * 0.9,
                             color=IMPL_COLORS[impl], label=IMPL_LABELS[impl],
                             edgecolor="white")
            for bar, val in zip(bars, vals):
                ax.text(bar.get_x() + bar.get_width() / 2,
                        bar.get_height() * 1.02,
                        f"{val:,.0f}", ha="center", va="bottom",
                        fontsize=8, fontweight="bold")

        ax.set_xticks(x)
        ax.set_xticklabels([f"N={s}" for s in sizes], fontsize=11)
        ax.set_title("Average Wall Time by Implementation and Matrix Size",
                     fontsize=13, fontweight="bold", pad=10)
        ax.set_ylabel("Avg wall time (ms)", fontsize=11)
        ax.legend(fontsize=10)
        fig.tight_layout()
    return _save(fig, "time_grouped.png")


def chart_time_line(avgs, sizes, impls):
    """Line chart on log scale for all implementations."""
    with plt.rc_context(MSTYLE):
        fig, ax = plt.subplots(figsize=(10, 6))
        for impl in impls:
            xs = [s for s in sizes if s in avgs[impl]]
            ys = [avgs[impl][s] for s in xs]
            ax.plot(xs, ys, marker="o", lw=2.5,
                    color=IMPL_COLORS[impl], label=IMPL_LABELS[impl])

        all_vals = [v for d in avgs.values() for v in d.values() if v > 0]
        ax.set_yscale("log")
        ax.set_ylim(bottom=min(all_vals) * 0.5)
        ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda y, _: f"{y:,.0f}"))
        ax.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{int(x)}"))
        ax.set_title("Execution Time vs Matrix Dimension  (log scale)",
                     fontsize=13, fontweight="bold", pad=10)
        ax.set_xlabel("Matrix dimension N", fontsize=11)
        ax.set_ylabel("Avg wall time (ms)", fontsize=11)
        ax.legend(fontsize=10)
        fig.tight_layout()
    return _save(fig, "time_line.png")


def chart_speedup(avgs, sizes, std_avgs):
    """Bar chart of speedup cache/std per size."""
    with plt.rc_context(MSTYLE):
        fig, ax = plt.subplots(figsize=(8, 5))
        speedups = [
            std_avgs.get(s, 1) / avgs["cache"].get(s, 1)
            for s in sizes
        ]
        bars = ax.bar(range(len(sizes)), speedups,
                      color=IMPL_COLORS["cache"], edgecolor="white")
        ax.axhline(1, color=IMPL_COLORS["std"], lw=1.5, ls="--",
                   label="std baseline")
        for bar, sp in zip(bars, speedups):
            ax.text(bar.get_x() + bar.get_width() / 2,
                    bar.get_height() + 0.01,
                    f"{sp:.2f}x", ha="center", va="bottom",
                    fontsize=10, fontweight="bold")
        ax.set_xticks(range(len(sizes)))
        ax.set_xticklabels([f"N={s}" for s in sizes], fontsize=11)
        ax.set_title("Speedup: Transposed vs Standard  (T_std / T_cache)",
                     fontsize=13, fontweight="bold", pad=10)
        ax.set_ylabel("Speedup factor", fontsize=11)
        ax.set_ylim(0, max(speedups) * 1.2)
        ax.legend(fontsize=10)
        fig.tight_layout()
    return _save(fig, "speedup.png")


def chart_cv(df, sizes, impls):
    """CV grouped bar per impl and size."""
    with plt.rc_context(MSTYLE):
        fig, ax = plt.subplots(figsize=(9, 5))
        w = 0.35
        x = list(range(len(sizes)))
        for i, impl in enumerate(impls):
            cv_vals = []
            for s in sizes:
                v = df[(df["impl"] == impl) & (df["matrix_size"] == s)]["wall_time_ms"]
                cv_vals.append(v.std() / v.mean() * 100 if len(v) > 1 else 0)
            offsets = [xi + (i - len(impls) / 2 + 0.5) * w for xi in x]
            ax.bar(offsets, cv_vals, width=w * 0.9,
                   label=IMPL_LABELS[impl], color=IMPL_COLORS[impl],
                   edgecolor="white", alpha=0.85)
        ax.set_xticks(x)
        ax.set_xticklabels([f"N={s}" for s in sizes], fontsize=11)
        ax.set_title("Coefficient of Variation  (lower = more stable)",
                     fontsize=12, fontweight="bold", pad=10)
        ax.set_ylabel("CV (%)", fontsize=11)
        ax.legend(fontsize=10)
        fig.tight_layout()
    return _save(fig, "cv.png")

# ---------------------------------------------------------------------------
# sheet: Raw Data
# ---------------------------------------------------------------------------

def write_raw_data(wb, df):
    ws = wb.create_sheet("Raw Data")
    ws.freeze_panes = "A3"

    headers = ["Implementation", "Matrix Size", "Repetition", "Wall Time (ms)"]
    widths  = [22, 14, 12, 16]
    title_row(ws, "Raw Measurements  |  Cache Line Optimization Benchmark", len(headers))

    for col, (h, w) in enumerate(zip(headers, widths), 1):
        hcell(ws.cell(2, col), h, bg="mid")
        _cw(ws, col, w)
    ws.row_dimensions[2].height = 20

    fmts = [None, "#,##0", "0", "0.000"]
    for ri, row in enumerate(df.itertuples(index=False), 3):
        bg = "alt" if ri % 2 == 0 else "white"
        vals = [row.impl, row.matrix_size, row.repetition, row.wall_time_ms]
        for col, (v, fmt) in enumerate(zip(vals, fmts), 1):
            dcell(ws.cell(ri, col), v, fmt=fmt, bg=bg,
                  align="left" if col == 1 else "right")

    ws.auto_filter.ref = f"A2:{get_column_letter(len(headers))}{len(df)+2}"

# ---------------------------------------------------------------------------
# sheet: Averages  (AVERAGEIFS formulas)
# ---------------------------------------------------------------------------

def write_averages(wb, sizes, impls):
    ws = wb.create_sheet("Averages")
    ws.freeze_panes = "B3"

    # columns: Impl | [avg_N, sp_N] * n_sizes | Avg Speedup
    n_cols = 1 + len(sizes) * 2 + 1
    title_row(ws, "Average Wall Time & Speedup  |  Speedup = T(std) / T(impl)", n_cols)

    hcell(ws.cell(2, 1), "Implementation", bg="dark")
    _cw(ws, 1, 22)
    ws.row_dimensions[2].height = 32

    for si, size in enumerate(sizes):
        ac = 2 + si * 2
        sc = ac + 1
        hcell(ws.cell(2, ac), f"N={size}\nAvg (ms)", bg="mid")
        hcell(ws.cell(2, sc), f"N={size}\nSpeedup",  bg="mid")
        _cw(ws, ac, 14)
        _cw(ws, sc, 12)

    avg_sp_col = 2 + len(sizes) * 2
    hcell(ws.cell(2, avg_sp_col), "Avg\nSpeedup", bg="dark")
    _cw(ws, avg_sp_col, 12)

    for ri, impl in enumerate(impls, 3):
        bg = "alt" if ri % 2 == 0 else "white"
        dcell(ws.cell(ri, 1), IMPL_LABELS[impl],
              bg="light", bold=True, align="left")

        sp_refs = []
        for si, size in enumerate(sizes):
            ac  = 2 + si * 2
            sc  = ac + 1
            al  = get_column_letter(ac)

            avg_c = ws.cell(ri, ac)
            avg_c.value = (
                f"=IFERROR(AVERAGEIFS('Raw Data'!D:D,"
                f"'Raw Data'!A:A,\"{impl}\","
                f"'Raw Data'!B:B,{size}),\"N/A\")"
            )
            avg_c.number_format = "0.000"
            avg_c.font      = Font(name=FN, size=10)
            avg_c.fill      = PatternFill("solid", fgColor=C[bg])
            avg_c.alignment = Alignment(horizontal="right")
            avg_c.border    = _bd()

            # std is always row 3 — speedup = std_avg / this_avg
            sp_c = ws.cell(ri, sc)
            sp_c.value = 1.0 if impl == "std" else f"=IFERROR(${al}$3/{al}{ri},\"N/A\")"
            sp_c.number_format = "0.0000"
            sp_c.font      = Font(name=FN, size=10, color=C["green_fg"])
            sp_c.fill      = PatternFill("solid", fgColor=C["green_bg"])
            sp_c.alignment = Alignment(horizontal="right")
            sp_c.border    = _bd()
            sp_refs.append(f"{get_column_letter(sc)}{ri}")

        avg_sp = ws.cell(ri, avg_sp_col)
        avg_sp.value         = f"=IFERROR(AVERAGE({','.join(sp_refs)}),\"N/A\")"
        avg_sp.number_format = "0.00"
        avg_sp.font      = Font(name=FN, bold=True, size=10, color=C["green_fg"])
        avg_sp.fill      = PatternFill("solid", fgColor=C["green_bg"])
        avg_sp.alignment = Alignment(horizontal="right")
        avg_sp.border    = _bd()

# ---------------------------------------------------------------------------
# sheet: Analysis
# ---------------------------------------------------------------------------

def write_analysis(wb, avgs, sizes, df):
    ws = wb.create_sheet("Analysis")
    title_row(ws, "Key Findings  |  Cache Line Optimization Benchmark", 4)

    for col, w in enumerate([28, 16, 16, 58], 1):
        _cw(ws, col, w)

    row = [3]

    def section(title):
        ws.merge_cells(f"A{row[0]}:D{row[0]}")
        c = ws.cell(row[0], 1, value=title)
        c.font      = Font(name=FN, bold=True, size=11, color=C["white"])
        c.fill      = PatternFill("solid", fgColor=C["mid"])
        c.alignment = Alignment(horizontal="left", vertical="center")
        ws.row_dimensions[row[0]].height = 20
        row[0] += 1

    def finding(label, value, note="", bg="white"):
        dcell(ws.cell(row[0], 1), label, bg=bg, align="left", bold=True)
        dcell(ws.cell(row[0], 2), value, bg=bg, align="center")
        dcell(ws.cell(row[0], 3), "",    bg=bg)
        dcell(ws.cell(row[0], 4), note,  bg=bg, align="left")
        row[0] += 1

    std_avgs = avgs["std"]

    section("1. Speedup por tamaño  (T_std / T_cache)")
    for s in sizes:
        if s not in avgs["cache"] or s not in std_avgs:
            continue
        sp = std_avgs[s] / avgs["cache"][s]
        bg = "alt" if row[0] % 2 == 0 else "white"
        direction = "cache mas rapido" if sp > 1.0 else "std igual o mas rapido"
        finding(f"N = {s}", f"{sp:.3f}x", direction, bg)

    row[0] += 1
    section("2. Comportamiento de cache por implementacion")
    for impl in IMPLS_ORDER:
        bg = "alt" if row[0] % 2 == 0 else "white"
        finding(IMPL_LABELS[impl], "", IMPL_DESC[impl], bg)

    row[0] += 1
    section("3. Estabilidad de mediciones  (Coeficiente de Variacion)")
    for impl in IMPLS_ORDER:
        for s in sizes:
            vals = df[(df["impl"] == impl) & (df["matrix_size"] == s)]["wall_time_ms"]
            cv   = vals.std() / vals.mean() * 100 if len(vals) > 1 else 0
            bg   = "alt" if row[0] % 2 == 0 else "white"
            label = "Excelente (<1%)" if cv < 1 else ("Buena (<3%)" if cv < 3 else "Revisar")
            finding(f"{impl}  N={s}", f"CV = {cv:.2f}%", label, bg)

    row[0] += 1
    section("4. Tendencia con el tamano de la matriz")
    prev_sp = None
    for s in sizes:
        if s not in avgs["cache"] or s not in std_avgs:
            continue
        sp  = std_avgs[s] / avgs["cache"][s]
        bg  = "alt" if row[0] % 2 == 0 else "white"
        note = ""
        if prev_sp is not None:
            if sp > prev_sp + 0.05:
                note = "Speedup crece: presion de cache aumenta con N, transpuesta beneficia mas"
            elif sp < prev_sp - 0.05:
                note = "Speedup decrece: ambas implementaciones sufren igualmente el LLC miss"
            else:
                note = "Speedup estable: patron de acceso consistente en este rango"
        finding(f"N = {s}", f"{sp:.3f}x", note, bg)
        prev_sp = sp

# ---------------------------------------------------------------------------
# sheet: Charts
# ---------------------------------------------------------------------------

def write_charts(wb, chart_paths):
    ws = wb.create_sheet("Charts")
    title_row(ws, "Visual Analysis  |  Cache Line Optimization Benchmark", 12)

    anchors = ["A2", "M2", "A28", "M28"]
    for anchor, path in zip(anchors, chart_paths):
        if path and os.path.exists(path):
            img        = XLImage(path)
            img.width  = 750
            img.height = 400
            ws.add_image(img, anchor)

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    os.makedirs(CHARTS_DIR, exist_ok=True)

    print(f"Reading: {CSV_PATH}")
    df     = load_data(CSV_PATH)
    impls  = [i for i in IMPLS_ORDER if i in df["impl"].unique()]
    sizes  = sorted(df["matrix_size"].unique().tolist())

    avgs = {}
    for impl in impls:
        sub       = df[df["impl"] == impl]
        avgs[impl] = {
            s: float(sub[sub["matrix_size"] == s]["wall_time_ms"].mean())
            for s in sizes
            if not sub[sub["matrix_size"] == s].empty
        }

    std_avgs = avgs.get("std", {})

    print("Generating charts...")
    chart_paths = [
        chart_time_grouped(avgs, sizes, impls),
        chart_speedup(avgs, sizes, std_avgs),
        chart_time_line(avgs, sizes, impls),
        chart_cv(df, sizes, impls),
    ]
    for p in chart_paths:
        print(f"  {os.path.basename(p)}")

    print("Building workbook...")
    wb = Workbook()
    wb.remove(wb.active)

    write_raw_data(wb, df)
    write_averages(wb, sizes, impls)
    write_analysis(wb, avgs, sizes, df)
    write_charts(wb, chart_paths)

    wb.save(OUTPUT_PATH)
    print(f"\nSaved: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()