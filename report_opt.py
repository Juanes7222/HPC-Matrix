"""
analyze_opt.py  --  Compiler optimization benchmark report generator

Reads data_opt.csv and produces reporte_opt.xlsx with:
  Sheet 1 - Raw Data   : full measurements table
  Sheet 2 - Averages   : AVERAGEIFS per config/size + speedup formulas
  Sheet 3 - Ranking    : configs sorted by avg speedup
  Sheet 4 - Analysis   : key findings (level jumps, native impact, stability)
  Sheet 5 - Charts     : matplotlib charts embedded

Usage:
    python analyze_opt.py [path/to/data_opt.csv]
    Defaults to results_opt/data_opt.csv
"""

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

# ---------------------------------------------------------------------------
# paths
# ---------------------------------------------------------------------------

CSV_PATH    = sys.argv[1] if len(sys.argv) > 1 else "results_opt/data_opt.csv"
OUT_DIR     = os.path.dirname(os.path.abspath(CSV_PATH))
OUTPUT_PATH = os.path.join(OUT_DIR, "reporte_opt.xlsx")
CHARTS_DIR  = os.path.join(OUT_DIR, "charts_opt")

CONFIGS_ORDER = [
    "O0", "O1", "O2", "O3", "Ofast",
    "O2_native", "O3_native", "Ofast_native",
    "O3_unroll", "O3_lto", "O3_full",
]

CONFIG_FLAGS = {
    "O0":           "-O0 -Wall",
    "O1":           "-O1 -Wall",
    "O2":           "-O2 -Wall",
    "O3":           "-O3 -Wall",
    "Ofast":        "-Ofast -Wall",
    "O2_native":    "-O2 -Wall -march=native",
    "O3_native":    "-O3 -Wall -march=native",
    "Ofast_native": "-Ofast -Wall -march=native",
    "O3_unroll":    "-O3 -Wall -march=native -funroll-loops",
    "O3_lto":       "-O3 -Wall -march=native -flto",
    "O3_full":      "-O3 -Wall -march=native -funroll-loops -flto -ffast-math -fomit-frame-pointer",
}

CONFIG_COLORS = {
    "O0":           "#C00000",
    "O1":           "#FF6600",
    "O2":           "#FFC000",
    "O3":           "#70AD47",
    "Ofast":        "#00B050",
    "O2_native":    "#4472C4",
    "O3_native":    "#2E75B6",
    "Ofast_native": "#1F4E79",
    "O3_unroll":    "#7030A0",
    "O3_lto":       "#00B0F0",
    "O3_full":      "#FF0066",
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
    "gold_bg":  "FFF2CC",
    "gold_fg":  "7F6000",
    "grey_bg":  "D8D8D8",
    "grey_fg":  "404040",
    "border":   "BDD7EE",
}

# ---------------------------------------------------------------------------
# style helpers
# ---------------------------------------------------------------------------

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


def dcell(cell, value, fmt=None, bg="white", fg="000000", bold=False, align="right"):
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
    df["config"]       = df["config"].str.strip('"')
    df["flags"]        = df["flags"].str.strip('"')
    df["matrix_size"]  = df["matrix_size"].astype(int)
    df["repetition"]   = df["repetition"].astype(int)
    df["wall_time_ms"] = df["wall_time_ms"].astype(float)
    return df

# ---------------------------------------------------------------------------
# matplotlib charts
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


def chart_time_log(avgs, sizes, configs):
    with plt.rc_context(MSTYLE):
        fig, ax = plt.subplots(figsize=(11, 6))
        for cfg in configs:
            xs = [s for s in sizes if s in avgs[cfg]]
            ys = [avgs[cfg][s] for s in xs]
            if not xs:
                continue
            lw = 2.5 if cfg in ("O0", "O3_full") else 1.8
            ax.plot(xs, ys, marker="o", lw=lw,
                    color=CONFIG_COLORS.get(cfg, "#333"), label=cfg)
        all_vals = [v for d in avgs.values() for v in d.values() if v > 0]
        ax.set_yscale("log")
        ax.set_ylim(bottom=min(all_vals) * 0.4)
        ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda y, _: f"{y:,.3g}"))
        ax.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{int(x)}"))
        ax.set_title("Execution Time vs Matrix Dimension  (log scale)",
                     fontsize=13, fontweight="bold", pad=10)
        ax.set_xlabel("Matrix dimension N", fontsize=11)
        ax.set_ylabel("Avg wall time (ms)", fontsize=11)
        ax.legend(fontsize=8, ncol=2, loc="upper left")
        fig.tight_layout()
    return _save(fig, "time_log.png")


def chart_speedup(avgs, sizes, configs, o0_avgs):
    with plt.rc_context(MSTYLE):
        fig, ax = plt.subplots(figsize=(11, 6))
        ax.axhline(1, color="#AAAAAA", lw=1, ls="--", label="O0 baseline")
        for cfg in configs:
            if cfg == "O0":
                continue
            xs = [s for s in sizes if s in avgs[cfg] and s in o0_avgs]
            ys = [o0_avgs[s] / avgs[cfg][s] for s in xs]
            if not xs:
                continue
            ax.plot(xs, ys, marker="o", lw=2.5 if cfg == "O3_full" else 1.8,
                    color=CONFIG_COLORS.get(cfg, "#333"), label=cfg)
        ax.xaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{int(x)}"))
        ax.set_title("Speedup over -O0 vs Matrix Dimension",
                     fontsize=13, fontweight="bold", pad=10)
        ax.set_xlabel("Matrix dimension N", fontsize=11)
        ax.set_ylabel("Speedup  (T_O0 / T_config)", fontsize=11)
        ax.legend(fontsize=8, ncol=2, loc="upper left")
        fig.tight_layout()
    return _save(fig, "speedup.png")


def chart_bar_speedup(avg_speedups, configs):
    with plt.rc_context(MSTYLE):
        fig, ax = plt.subplots(figsize=(11, 5))
        vals   = [avg_speedups.get(c, 0) for c in configs]
        colors = [CONFIG_COLORS.get(c, "#333") for c in configs]
        bars   = ax.bar(range(len(configs)), vals, color=colors,
                        edgecolor="white", lw=0.5)
        for bar, val in zip(bars, vals):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.4,
                    f"{val:.1f}x", ha="center", va="bottom",
                    fontsize=8, fontweight="bold")
        ax.set_xticks(range(len(configs)))
        ax.set_xticklabels(configs, rotation=30, ha="right", fontsize=9)
        ax.set_title("Average Speedup over -O0  (all sizes)",
                     fontsize=13, fontweight="bold", pad=10)
        ax.set_ylabel("Speedup", fontsize=11)
        ax.set_ylim(0, max(vals) * 1.18)
        fig.tight_layout()
    return _save(fig, "bar_speedup.png")


def chart_cv(df, sizes, configs):
    with plt.rc_context(MSTYLE):
        fig, ax = plt.subplots(figsize=(11, 5))
        w = 0.8 / len(sizes)
        for si, size in enumerate(sizes):
            offsets = [x + (si - len(sizes) / 2 + 0.5) * w for x in range(len(configs))]
            cv_vals = []
            for cfg in configs:
                v = df[(df["config"] == cfg) & (df["matrix_size"] == size)]["wall_time_ms"]
                cv_vals.append(v.std() / v.mean() * 100 if len(v) > 1 else 0)
            ax.bar(offsets, cv_vals, width=w * 0.9, label=f"N={size}", alpha=0.85)
        ax.set_xticks(range(len(configs)))
        ax.set_xticklabels(configs, rotation=30, ha="right", fontsize=9)
        ax.set_title("Coefficient of Variation  (lower = more stable)",
                     fontsize=12, fontweight="bold", pad=10)
        ax.set_ylabel("CV (%)", fontsize=11)
        ax.legend(fontsize=9)
        fig.tight_layout()
    return _save(fig, "cv.png")


def chart_native_impact(avgs, sizes):
    pairs = [("O2","O2_native"), ("O3","O3_native"), ("Ofast","Ofast_native")]
    with plt.rc_context(MSTYLE):
        fig, ax = plt.subplots(figsize=(9, 5))
        w = 0.25
        for i, (base, native) in enumerate(pairs):
            gains   = [avgs[base][s] / avgs[native][s]
                       for s in sizes if s in avgs[base] and s in avgs[native]]
            offsets = [x + (i - 1) * w for x in range(len(sizes))]
            ax.bar(offsets, gains, width=w * 0.9, label=f"{base} → {native}",
                   color=CONFIG_COLORS.get(native, "#333"), edgecolor="white")
        ax.axhline(1, color="#AAAAAA", lw=1, ls="--")
        ax.set_xticks(range(len(sizes)))
        ax.set_xticklabels([f"N={s}" for s in sizes], fontsize=10)
        ax.set_title("Speedup gained by adding -march=native",
                     fontsize=12, fontweight="bold", pad=10)
        ax.set_ylabel("Speedup factor", fontsize=11)
        ax.legend(fontsize=9)
        fig.tight_layout()
    return _save(fig, "native_impact.png")

# ---------------------------------------------------------------------------
# sheet: Raw Data
# ---------------------------------------------------------------------------

def write_raw_data(wb, df):
    ws = wb.create_sheet("Raw Data")
    ws.freeze_panes = "A3"

    headers = ["Config", "Flags", "Matrix Size", "Repetition", "Wall Time (ms)", "Correct"]
    widths  = [14, 60, 13, 12, 16, 10]
    title_row(ws, "Raw Measurements  |  Compiler Optimization Benchmark", len(headers))

    for col, (h, w) in enumerate(zip(headers, widths), 1):
        hcell(ws.cell(2, col), h, bg="mid")
        _cw(ws, col, w)
    ws.row_dimensions[2].height = 20

    fmts = [None, None, "#,##0", "0", "0.000", "0"]
    for ri, row in enumerate(df.itertuples(index=False), 3):
        bg = "alt" if ri % 2 == 0 else "white"
        vals = [row.config, row.flags, row.matrix_size,
                row.repetition, row.wall_time_ms, int(row.correct)]
        for col, (v, fmt) in enumerate(zip(vals, fmts), 1):
            dcell(ws.cell(ri, col), v, fmt=fmt, bg=bg,
                  align="left" if col <= 2 else "right")

    ws.auto_filter.ref = f"A2:{get_column_letter(len(headers))}{len(df)+2}"

# ---------------------------------------------------------------------------
# sheet: Averages  (AVERAGEIFS formulas — recalc.py will evaluate them)
# ---------------------------------------------------------------------------

def write_averages(wb, sizes, configs):
    ws = wb.create_sheet("Averages")
    ws.freeze_panes = "B3"

    n_cols = 1 + len(sizes) * 2 + 2
    title_row(ws, "Average Wall Time & Speedup  |  Speedup = T(O0) / T(config)", n_cols)

    hcell(ws.cell(2, 1), "Config", bg="dark")
    _cw(ws, 1, 14)
    ws.row_dimensions[2].height = 32

    for si, size in enumerate(sizes):
        ac = 2 + si * 2
        sc = ac + 1
        hcell(ws.cell(2, ac), f"N={size}\nAvg (ms)", bg="mid")
        hcell(ws.cell(2, sc), f"N={size}\nSpeedup",  bg="mid")
        _cw(ws, ac, 13)
        _cw(ws, sc, 11)

    avg_sp_col  = 2 + len(sizes) * 2
    correct_col = avg_sp_col + 1
    hcell(ws.cell(2, avg_sp_col),  "Avg\nSpeedup", bg="dark")
    hcell(ws.cell(2, correct_col), "Correct",      bg="dark")
    _cw(ws, avg_sp_col, 12)
    _cw(ws, correct_col, 9)

    for ri, cfg in enumerate(configs, 3):
        bg = "alt" if ri % 2 == 0 else "white"
        dcell(ws.cell(ri, 1), cfg, bg="light", bold=True, align="center")

        sp_refs = []
        for si, size in enumerate(sizes):
            ac  = 2 + si * 2
            sc  = ac + 1
            al  = get_column_letter(ac)

            avg_c = ws.cell(ri, ac)
            avg_c.value = (
                f"=IFERROR(AVERAGEIFS('Raw Data'!E:E,"
                f"'Raw Data'!A:A,A{ri},"
                f"'Raw Data'!C:C,{size}),\"N/A\")"
            )
            avg_c.number_format = "0.000"
            avg_c.font      = Font(name=FN, size=10)
            avg_c.fill      = PatternFill("solid", fgColor=C[bg])
            avg_c.alignment = Alignment(horizontal="right")
            avg_c.border    = _bd()

            sp_c = ws.cell(ri, sc)
            # Speedup = O0 row (always row 3) avg / this config avg
            sp_c.value = 1.0 if cfg == "O0" else f"=IFERROR(${al}$3/{al}{ri},\"N/A\")"
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

        corr = ws.cell(ri, correct_col)
        corr.value = (
            f"=IFERROR(AVERAGEIFS('Raw Data'!F:F,'Raw Data'!A:A,A{ri}),\"N/A\")"
        )
        corr.number_format = "0"
        corr.font      = Font(name=FN, size=10)
        corr.fill      = PatternFill("solid", fgColor=C[bg])
        corr.alignment = Alignment(horizontal="center")
        corr.border    = _bd()

# ---------------------------------------------------------------------------
# sheet: Ranking
# ---------------------------------------------------------------------------

def write_ranking(wb, avg_speedups, configs, df):
    ws = wb.create_sheet("Ranking")
    title_row(ws, "Configuration Ranking by Average Speedup over -O0", 5)

    headers = ["Rank", "Config", "Avg Speedup", "Correct", "Flags"]
    widths  = [8, 14, 13, 9, 72]
    for col, (h, w) in enumerate(zip(headers, widths), 1):
        hcell(ws.cell(2, col), h, bg="mid")
        _cw(ws, col, w)
    ws.row_dimensions[2].height = 20

    ranked = sorted(configs, key=lambda c: avg_speedups.get(c, 0), reverse=True)
    medal  = {
        1: ("gold_bg", "gold_fg"),
        2: ("grey_bg", "grey_fg"),
        3: ("red_bg",  "red_fg"),
    }

    for ri, cfg in enumerate(ranked, 3):
        rank    = ri - 2
        sp      = avg_speedups.get(cfg, 0)
        correct = int(df[df["config"] == cfg]["correct"].mode()[0])
        bg, fg  = medal.get(rank, ("alt" if rank % 2 == 0 else "white", "000000"))

        dcell(ws.cell(ri, 1), f"#{rank}",      bg=bg, fg=fg, bold=(rank<=3), align="center")
        dcell(ws.cell(ri, 2), cfg,              bg=bg, fg=fg, bold=(rank<=3), align="center")
        dcell(ws.cell(ri, 3), f"{sp:.2f}x",    bg=bg, fg="green_fg", bold=(rank<=3), align="right")
        dcell(ws.cell(ri, 4), correct, fmt="0", bg=bg, align="center")
        dcell(ws.cell(ri, 5), CONFIG_FLAGS.get(cfg, ""), bg=bg, align="left")

# ---------------------------------------------------------------------------
# sheet: Analysis
# ---------------------------------------------------------------------------

def write_analysis(wb, avgs, avg_speedups, sizes, configs, df):
    ws = wb.create_sheet("Analysis")
    title_row(ws, "Key Findings  |  Compiler Optimization Benchmark", 4)

    for col, w in enumerate([32, 18, 18, 55], 1):
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

    def finding(label, value, note=""):
        bg = "alt" if row[0] % 2 == 0 else "white"
        dcell(ws.cell(row[0], 1), label, bg=bg, align="left", bold=True)
        dcell(ws.cell(row[0], 2), value, bg=bg, align="center")
        dcell(ws.cell(row[0], 3), "",    bg=bg)
        dcell(ws.cell(row[0], 4), note,  bg=bg, align="left")
        row[0] += 1

    o0_avgs = avgs["O0"]

    section("1. Baseline levels  (-O0 to -Ofast)")
    prev_sp, prev_cfg = 1.0, "O0"
    for cfg in ["O1", "O2", "O3", "Ofast"]:
        sp    = avg_speedups[cfg]
        delta = sp / prev_sp
        finding(f"{prev_cfg} → {cfg}",
                f"{sp:.2f}x total",
                f"{delta:.2f}x adicional respecto a {prev_cfg}")
        prev_sp, prev_cfg = sp, cfg

    row[0] += 1
    section("2. Impacto de -march=native")
    notes_native = {
        "O2": "A nivel O2 no hay vectorizacion; -march=native no cambia nada",
        "O3": "O3 activa vectorizacion SSE; native habilita AVX2 -> 8 int/ciclo",
        "Ofast": "Similar a O3_native; Ofast agrega fast-math sin beneficio en ints",
    }
    for base, native in [("O2","O2_native"),("O3","O3_native"),("Ofast","Ofast_native")]:
        gains = [avgs[base][s] / avgs[native][s]
                 for s in sizes if s in avgs[base] and s in avgs[native]]
        finding(f"{base} -> {native}", f"{statistics.mean(gains):.2f}x avg",
                notes_native[base])

    row[0] += 1
    section("3. Flags adicionales sobre O3_native")
    notes_extra = {
        "O3_unroll": "-funroll-loops: elimina branch del bucle interno; ganancia marginal sobre AVX2",
        "O3_lto":    "-flto: no hay TUs utiles que inlinear; overhead de layout > beneficio",
        "O3_full":   "Combinacion completa: mejor resultado global del benchmark",
    }
    for cfg in ["O3_unroll", "O3_lto", "O3_full"]:
        gains = [avgs["O3_native"][s] / avgs[cfg][s]
                 for s in sizes if s in avgs[cfg]]
        finding(f"O3_native -> {cfg}", f"{statistics.mean(gains):.2f}x avg",
                notes_extra[cfg])

    row[0] += 1
    section("4. Estabilidad  (Coeficiente de Variacion - menor es mejor)")
    for cfg in configs:
        vals = df[df["config"] == cfg]["wall_time_ms"]
        cv   = vals.std() / vals.mean() * 100
        label = "Excelente (<1%)" if cv < 1 else ("Buena (<3%)" if cv < 3 else "Revisar")
        finding(cfg, f"CV = {cv:.2f}%", label)

    row[0] += 1
    section("5. Correctitud  (verify_mul.c - 4x4 con valores conocidos)")
    all_ok = (df["correct"] == 1).all()
    finding("Todas las configuraciones",
            "PASS" if all_ok else "FAIL",
            "Aritmetica entera pura: las optimizaciones no alteran el resultado matematico")

# ---------------------------------------------------------------------------
# sheet: Charts
# ---------------------------------------------------------------------------

def write_charts(wb, chart_paths):
    ws = wb.create_sheet("Charts")
    title_row(ws, "Visual Analysis  |  Compiler Optimization Benchmark", 12)

    anchors = ["A2", "M2", "A28", "M28", "A54"]
    for anchor, path in zip(anchors, chart_paths):
        if path and os.path.exists(path):
            img        = XLImage(path)
            img.width  = 750
            img.height = 370
            ws.add_image(img, anchor)

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    os.makedirs(CHARTS_DIR, exist_ok=True)

    print(f"Reading: {CSV_PATH}")
    df      = load_data(CSV_PATH)
    configs = [c for c in CONFIGS_ORDER if c in df["config"].unique()]
    sizes   = sorted(df["matrix_size"].unique().tolist())

    avgs = {}
    for cfg in configs:
        sub       = df[df["config"] == cfg]
        avgs[cfg] = {
            s: float(sub[sub["matrix_size"] == s]["wall_time_ms"].mean())
            for s in sizes
            if not sub[sub["matrix_size"] == s].empty
        }

    o0_avgs      = avgs.get("O0", {})
    avg_speedups = {
        cfg: statistics.mean(
            [o0_avgs[s] / avgs[cfg][s]
             for s in sizes if s in avgs[cfg] and s in o0_avgs and avgs[cfg][s] > 0]
        )
        for cfg in configs
    }

    print("Generating charts...")
    chart_paths = [
        chart_time_log(avgs, sizes, configs),
        chart_speedup(avgs, sizes, configs, o0_avgs),
        chart_bar_speedup(avg_speedups, configs),
        chart_cv(df, sizes, configs),
        chart_native_impact(avgs, sizes),
    ]
    for p in chart_paths:
        print(f"  {os.path.basename(p)}")

    print("Building workbook...")
    wb = Workbook()
    wb.remove(wb.active)

    write_raw_data(wb, df)
    write_averages(wb, sizes, configs)
    write_ranking(wb, avg_speedups, configs, df)
    write_analysis(wb, avgs, avg_speedups, sizes, configs, df)
    write_charts(wb, chart_paths)

    wb.save(OUTPUT_PATH)
    print(f"\nSaved: {OUTPUT_PATH}")


if __name__ == "__main__":
    main()