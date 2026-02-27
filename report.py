import os
import sys
from typing import cast
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
from openpyxl.drawing.image import Image as XLImage

RESULTS_DIR = "results"
CHARTS_DIR  = os.path.join(RESULTS_DIR, "charts")
OUTPUT_FILE = os.path.join(RESULTS_DIR, "reporte_hpc.xlsx")
REPETITIONS = 10

MODE_ORDER = [
    ("sequential",  "Sequential"),
    ("threads_2t",  "2 Threads"),
    ("threads_4t",  "4 Threads"),
    ("threads_6t",  "6 Threads"),
    ("threads_8t",  "8 Threads"),
    ("threads_12t", "12 Threads"),
    ("concurrent",  "Processes"),
]

C_DARK_BLUE  = "1F4E79"
C_MID_BLUE   = "2E75B6"
C_LIGHT_BLUE = "D6E4F0"
C_ALT_ROW    = "F2F9FF"
C_WHITE      = "FFFFFF"
C_GREEN_BG   = "E2EFDA"
C_GREEN_FG   = "375623"
C_GREEN_ALT  = "EAF4E2"
C_BORDER     = "BDD7EE"
FONT_NAME    = "Arial"


def _border(color=C_BORDER):
    s = Side(style="thin", color=color)
    return Border(left=s, right=s, top=s, bottom=s)

def _col(ws, col, width):
    ws.column_dimensions[get_column_letter(col)].width = width

def _header_cell(cell, value, bg=C_DARK_BLUE, size=10):
    cell.value     = value
    cell.font      = Font(name=FONT_NAME, bold=True, color=C_WHITE, size=size)
    cell.fill      = PatternFill("solid", fgColor=bg)
    cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
    cell.border    = _border()

def load_csv(mode_key):
    path = os.path.join(RESULTS_DIR, f"data_{mode_key}.csv")
    if not os.path.exists(path):
        return None

    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]

    aliases = {
        "size": "matrix_size", "n": "matrix_size",
        "dim": "matrix_size",  "dimension": "matrix_size",
        "rep": "repetition",   "repeticion": "repetition",
        "time_ms": "wall_time_ms", "elapsed_ms": "wall_time_ms",
        "wall_time": "wall_time_ms", "time": "wall_time_ms",
    }
    df = df.rename(columns=aliases)

    required = {"matrix_size", "repetition", "wall_time_ms"}
    missing  = required - set(df.columns)
    if missing:
        print(f"  [WARN] {path}: missing columns {missing}. Skipping.")
        return None

    if "exit_code" in df.columns:
        bad = (df["exit_code"] != 0).sum()
        if bad:
            print(f"  [WARN] {path}: dropping {bad} failed row(s) (exit_code != 0)")
        df = df[df["exit_code"] == 0].copy()

    df["matrix_size"] = df["matrix_size"].astype(int)
    df["repetition"]  = df["repetition"].astype(int)
    df["wall_time_ms"] = df["wall_time_ms"].astype(float) / 1000.0  # convert to seconds

    return df

def collect_sizes(available_modes):
    """Read matrix sizes from all CSVs and return a sorted list of Python ints."""
    sizes = set()
    for mode_key, _ in available_modes:
        df = load_csv(mode_key)
        if df is not None:
            sizes.update(int(s) for s in df["matrix_size"].unique())
    return sorted(sizes)

def build_averages(available_modes, matrix_sizes):
    """
    Returns {mode_key: {size: avg_ms}} with all keys as Python ints/floats.
    """
    avgs = {}
    for mode_key, _ in available_modes:
        df = load_csv(mode_key)
        avgs[mode_key] = {}
        if df is None:
            continue
        for size in matrix_sizes:
            subset = df[df["matrix_size"] == size]["wall_time_ms"]
            if not subset.empty:
                avgs[mode_key][size] = float(subset.mean())
    return avgs

CHART_STYLE = {
    "figure.facecolor": "white",
    "axes.facecolor":   "white",
    "axes.grid":        True,
    "grid.color":       "#E0E0E0",
    "grid.linewidth":   0.8,
    "axes.spines.top":  False,
    "axes.spines.right":False,
    "font.family":      "DejaVu Sans",
}

COLORS = [
    "#1F4E79", "#2E75B6", "#70AD47", "#ED7D31",
    "#FFC000", "#C00000", "#7030A0",
]

def _save_fig(fig, name):
    path = os.path.join(CHARTS_DIR, name)
    fig.savefig(path, dpi=180, bbox_inches="tight")
    plt.close(fig)
    return path

def chart_execution_time(available_modes, avgs, matrix_sizes):
    """Execution time vs matrix size for all modes including sequential."""
    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(10, 6))

        for idx, (mode_key, label) in enumerate(available_modes):
            mode_data = avgs.get(mode_key, {})
            sizes = [s for s in matrix_sizes if s in mode_data]
            times = [mode_data[s] for s in sizes]
            if not sizes:
                continue
            ax.plot(sizes, times,
                    marker="o", linewidth=2,
                    color=COLORS[idx % len(COLORS)],
                    label=label)

        ax.set_title("Execution Time vs Matrix Dimension",
                     fontsize=14, fontweight="bold", pad=12)
        ax.set_xlabel("Matrix dimension N (NxN)", fontsize=11)
        ax.set_ylabel("Average wall time (s)", fontsize=11)
        ax.xaxis.set_major_formatter(
            ticker.FuncFormatter(lambda x, _: f"{int(x)}"))
        ax.legend(fontsize=9, loc="upper left")
        fig.tight_layout()

    return _save_fig(fig, "chart_execution_time.png")

def chart_speedup(available_modes, avgs, matrix_sizes):
    """Speedup vs matrix size for all parallel modes."""
    seq_avgs = avgs.get("sequential", {})
    if not seq_avgs:
        print("  [WARN] No sequential data found; skipping speedup chart.")
        return None

    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(10, 6))

        ax.axhline(y=1, color="#AAAAAA", linewidth=1,
                   linestyle="--", label="Baseline (seq = 1)")

        color_idx = 0
        for mode_key, label in available_modes:
            if mode_key == "sequential":
                continue
            mode_data = avgs.get(mode_key, {})
            sizes = [s for s in matrix_sizes
                     if s in mode_data and s in seq_avgs and mode_data[s] > 0]
            speedups = [seq_avgs[s] / mode_data[s] for s in sizes]
            if not sizes:
                continue
            ax.plot(sizes, speedups,
                    marker="o", linewidth=2,
                    color=COLORS[color_idx % len(COLORS)],
                    label=label)
            color_idx += 1

        ax.set_title("Speedup vs Matrix Dimension",
                     fontsize=14, fontweight="bold", pad=12)
        ax.set_xlabel("Matrix dimension N (NxN)", fontsize=11)
        ax.set_ylabel("Speedup  (T_seq / T_parallel)", fontsize=11)
        ax.xaxis.set_major_formatter(
            ticker.FuncFormatter(lambda x, _: f"{int(x)}"))
        ax.legend(fontsize=9, loc="upper left")
        fig.tight_layout()

    return _save_fig(fig, "chart_speedup.png")

def chart_per_mode(mode_key, label, df, matrix_sizes):
    """Scatter of all repetitions + average line for a single mode."""
    if df is None or df.empty:
        return None

    with plt.rc_context(CHART_STYLE):
        fig, ax = plt.subplots(figsize=(9, 5))

        x_pos     = list(range(len(matrix_sizes)))
        avg_vals  = []

        for xi, size in enumerate(matrix_sizes):
            subset = df[df["matrix_size"] == size]["wall_time_ms"]
            if subset.empty:
                avg_vals.append(None)
                continue
            ax.scatter([xi] * len(subset), subset.values,
                       color="#2E75B6", alpha=0.45, s=35, zorder=3)
            avg_vals.append(float(subset.mean()))

        valid_x = [x_pos[i] for i, v in enumerate(avg_vals) if v is not None]
        valid_y = [v for v in avg_vals if v is not None]
        ax.plot(valid_x, valid_y,
                color="#1F4E79", linewidth=2,
                marker="D", markersize=6,
                label="Average", zorder=4)

        ax.set_xticks(x_pos)
        ax.set_xticklabels([str(s) for s in matrix_sizes], fontsize=9)
        ax.set_title(f"{label}  —  Wall time per repetition",
                     fontsize=13, fontweight="bold", pad=10)
        ax.set_xlabel("Matrix dimension N", fontsize=10)
        ax.set_ylabel("Wall time (s)", fontsize=10)
        ax.legend(fontsize=9)
        fig.tight_layout()

    return _save_fig(fig, f"chart_{mode_key}.png")

def write_mode_sheet(wb, mode_key, label, seq_avgs, matrix_sizes,
                     chart_path=None):
    df  = load_csv(mode_key)
    ws  = wb.create_sheet(title=label)
    ws.freeze_panes = "B3"
    is_seq = (mode_key == "sequential")

    n_cols = REPETITIONS + 3   # dim + reps + avg + speedup

    ws.merge_cells(f"A1:{get_column_letter(n_cols)}1")
    t = ws["A1"]
    t.value     = f"Matrix Multiplication  |  {label}"
    t.font      = Font(name=FONT_NAME, bold=True, size=14, color=C_WHITE)
    t.fill      = PatternFill("solid", fgColor=C_DARK_BLUE)
    t.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[1].height = 28

    ws.row_dimensions[2].height = 22
    headers = (["Dimension (N)"]
               + [f"Rep {i}" for i in range(1, REPETITIONS + 1)]
               + ["Average (s)", "Speedup"])
    for col, h in enumerate(headers, start=1):
        _header_cell(ws.cell(row=2, column=col), h,
                     bg=C_MID_BLUE if col > 1 else C_DARK_BLUE)

    _col(ws, 1, 16)
    for col in range(2, REPETITIONS + 2):
        _col(ws, col, 13)
    _col(ws, REPETITIONS + 2, 15)
    _col(ws, REPETITIONS + 3, 12)

    first_rep_col = get_column_letter(2)
    last_rep_col  = get_column_letter(REPETITIONS + 1)
    avg_col_letter = get_column_letter(REPETITIONS + 2)

    for row_idx, size in enumerate(matrix_sizes, start=3):
        alt = (row_idx % 2 == 0)

        d = ws.cell(row=row_idx, column=1, value=f"{size} x {size}")
        d.font      = Font(name=FONT_NAME, bold=True, size=10)
        d.fill      = PatternFill("solid", fgColor=C_LIGHT_BLUE)
        d.alignment = Alignment(horizontal="center")
        d.border    = _border()

        for rep in range(1, REPETITIONS + 1):
            c = ws.cell(row=row_idx, column=rep + 1)
            if df is not None:
                mask = (df["matrix_size"] == size) & (df["repetition"] == rep)
                vals = cast(pd.Series, df.loc[mask, "wall_time_ms"])
                if not vals.empty:
                    c.value = round(float(vals.iloc[0]), 3)
            c.number_format = "0.000"
            c.font          = Font(name=FONT_NAME, size=10)
            c.fill          = PatternFill("solid",
                                          fgColor=C_ALT_ROW if alt else C_WHITE)
            c.alignment     = Alignment(horizontal="right")
            c.border        = _border()

        avg_c = ws.cell(row=row_idx, column=REPETITIONS + 2)
        avg_c.value         = (f"=IFERROR(AVERAGE("
                               f"{first_rep_col}{row_idx}:"
                               f"{last_rep_col}{row_idx}), \"N/A\")")
        avg_c.number_format = "0.000"
        avg_c.font          = Font(name=FONT_NAME, bold=True, size=10)
        avg_c.fill          = PatternFill("solid", fgColor=C_LIGHT_BLUE)
        avg_c.alignment     = Alignment(horizontal="right")
        avg_c.border        = _border()

        sp_c = ws.cell(row=row_idx, column=REPETITIONS + 3)
        if is_seq:
            sp_c.value = 1.0
        else:
            seq_avg = seq_avgs.get(size)
            if df is not None and seq_avg is not None:
                subset = df[df["matrix_size"] == size]["wall_time_ms"]
                if not subset.empty and subset.mean() > 0:
                    sp_c.value = round(seq_avg / float(subset.mean()), 4)
                else:
                    sp_c.value = "N/A"
            else:
                sp_c.value = "N/A"

        sp_c.number_format = "0.0000"
        sp_c.font          = Font(name=FONT_NAME, bold=True, size=10,
                                  color=C_GREEN_FG)
        sp_c.fill          = PatternFill("solid", fgColor=C_GREEN_BG)
        sp_c.alignment     = Alignment(horizontal="right")
        sp_c.border        = _border()

    if chart_path and os.path.exists(chart_path):
        img        = XLImage(chart_path)
        img.width  = 620
        img.height = 340
        ws.add_image(img, f"{get_column_letter(n_cols + 2)}2")

    return ws

def write_summary_sheet(wb, available_modes, avgs, seq_avgs, matrix_sizes,
                        time_chart_path, speedup_chart_path):
    ws = wb.create_sheet(title="Summary")
    ws.freeze_panes = "B3"

    n_modes  = len(available_modes)
    last_col = get_column_letter(1 + n_modes * 2)

    ws.merge_cells(f"A1:{last_col}1")
    t = ws["A1"]
    t.value     = "Comparative Summary  |  HPC Matrix Multiplication"
    t.font      = Font(name=FONT_NAME, bold=True, size=14, color=C_WHITE)
    t.fill      = PatternFill("solid", fgColor=C_DARK_BLUE)
    t.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[1].height = 28

    _header_cell(ws.cell(row=2, column=1), "Dimension (N)")
    _col(ws, 1, 16)
    ws.row_dimensions[2].height = 32

    for m_idx, (_, label) in enumerate(available_modes):
        avg_col = 2 + m_idx * 2
        sp_col  = avg_col + 1
        _header_cell(ws.cell(row=2, column=avg_col),
                     f"{label}\nAverage (s)", bg=C_MID_BLUE, size=9)
        _header_cell(ws.cell(row=2, column=sp_col),
                     f"{label}\nSpeedup",      bg=C_MID_BLUE, size=9)
        _col(ws, avg_col, 14)
        _col(ws, sp_col,  12)

    for row_idx, size in enumerate(matrix_sizes, start=3):
        alt = (row_idx % 2 == 0)

        d = ws.cell(row=row_idx, column=1, value=f"{size} x {size}")
        d.font      = Font(name=FONT_NAME, bold=True, size=10)
        d.fill      = PatternFill("solid", fgColor=C_LIGHT_BLUE)
        d.alignment = Alignment(horizontal="center")
        d.border    = _border()

        for m_idx, (mode_key, _) in enumerate(available_modes):
            avg_col = 2 + m_idx * 2
            sp_col  = avg_col + 1

            mode_avg = avgs.get(mode_key, {}).get(size)
            seq_avg  = seq_avgs.get(size)

            avg_c = ws.cell(row=row_idx, column=avg_col)
            avg_c.value = round(mode_avg, 3) if mode_avg is not None else "N/D"
            avg_c.number_format = "0.000"
            avg_c.font          = Font(name=FONT_NAME, size=10)
            avg_c.fill          = PatternFill("solid",
                                              fgColor=C_ALT_ROW if alt else C_WHITE)
            avg_c.alignment     = Alignment(horizontal="right")
            avg_c.border        = _border()

            sp_c = ws.cell(row=row_idx, column=sp_col)
            if mode_key == "sequential":
                sp_c.value = 1.0
            elif mode_avg and mode_avg > 0 and seq_avg:
                sp_c.value = round(seq_avg / mode_avg, 4)
            else:
                sp_c.value = "N/A"
            sp_c.number_format = "0.0000"
            sp_c.font          = Font(name=FONT_NAME, size=10, color=C_GREEN_FG)
            sp_c.fill          = PatternFill("solid",
                                             fgColor=C_GREEN_BG if not alt
                                             else C_GREEN_ALT)
            sp_c.alignment     = Alignment(horizontal="right")
            sp_c.border        = _border()

    chart_row = len(matrix_sizes) + 5
    if time_chart_path and os.path.exists(time_chart_path):
        img        = XLImage(time_chart_path)
        img.width  = 720
        img.height = 430
        ws.add_image(img, f"A{chart_row}")

    if speedup_chart_path and os.path.exists(speedup_chart_path):
        img        = XLImage(speedup_chart_path)
        img.width  = 720
        img.height = 430
        ws.add_image(img, f"M{chart_row}")

    return ws

def main():
    os.makedirs(CHARTS_DIR, exist_ok=True)

    available_modes = []
    for mode_key, label in MODE_ORDER:
        path = os.path.join(RESULTS_DIR, f"data_{mode_key}.csv")
        if os.path.exists(path):
            available_modes.append((mode_key, label))
            print(f"  [OK]  data_{mode_key}.csv")
        else:
            print(f"  [--]  data_{mode_key}.csv  (not found, skipping)")

    if not available_modes:
        print("\nNo CSVs found in results/. Run the benchmark first.")
        sys.exit(1)

    matrix_sizes = collect_sizes(available_modes)
    print(f"\n  Sizes detected: {matrix_sizes}")

    avgs     = build_averages(available_modes, matrix_sizes)
    seq_avgs = avgs.get("sequential", {})

    if not seq_avgs:
        print("  [WARN] Sequential data not found. Speedup will show N/A.")

    print("\n  Generating matplotlib charts...")

    per_mode_charts = {}
    for mode_key, label in available_modes:
        df   = load_csv(mode_key)
        path = chart_per_mode(mode_key, label, df, matrix_sizes)
        per_mode_charts[mode_key] = path
        if path:
            print(f"    Saved: {os.path.basename(path)}")

    time_chart_path    = chart_execution_time(available_modes, avgs, matrix_sizes)
    speedup_chart_path = chart_speedup(available_modes, avgs, matrix_sizes)
    if time_chart_path:
        print(f"    Saved: {os.path.basename(time_chart_path)}")
    if speedup_chart_path:
        print(f"    Saved: {os.path.basename(speedup_chart_path)}")

    print("\n  Building Excel workbook...")

    wb = Workbook()
    if wb.active is not None:
        wb.remove(wb.active)

    write_summary_sheet(wb, available_modes, avgs, seq_avgs, matrix_sizes,
                        time_chart_path, speedup_chart_path)

    for mode_key, label in available_modes:
        print(f"    Sheet: {label}")
        write_mode_sheet(wb, mode_key, label, seq_avgs, matrix_sizes,
                         chart_path=per_mode_charts.get(mode_key))

    wb.save(OUTPUT_FILE)
    print(f"\n  Excel report : {OUTPUT_FILE}")
    print(f"  Charts folder: {CHARTS_DIR}/")
    print("\nDone.")


if __name__ == "__main__":
    print("HPC Report Generator")
    print("=" * 40)
    main()