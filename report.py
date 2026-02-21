import os
import glob
import pandas as pd
from openpyxl import Workbook
from openpyxl.styles import (Font, PatternFill, Alignment, Border, Side,
                              GradientFill)
from openpyxl.utils import get_column_letter
from openpyxl.chart import LineChart, Reference
from openpyxl.chart.series import DataPoint


RESULTS_DIR = "results"
OUTPUT_FILE = "results/reporte_hpc.xlsx"


MODE_ORDER = [
    ("sequential",    "Secuencial"),
    ("threads_2t",    "2 Hilos"),
    ("threads_4t",    "4 Hilos"),
    ("threads_8t",    "8 Hilos"),
    ("threads_16t",   "16 Hilos"),
    ("threads_32t",   "32 Hilos"),
    ("concurrent",    "Procesos"),
]

MATRIX_SIZES = [10, 100, 200, 400, 800, 1600, 3200]
REPETITIONS  = 10

FONT_NAME = "Arial"


COLOR_HEADER_BG   = "1F4E79"   # Azul oscuro
COLOR_HEADER_FG   = "FFFFFF"   # Blanco
COLOR_SUBHDR_BG   = "2E75B6"   # Azul medio
COLOR_SUBHDR_FG   = "FFFFFF"
COLOR_AVG_BG      = "D6E4F0"   # Azul muy claro
COLOR_SPEEDUP_BG  = "E2EFDA"   # Verde claro
COLOR_ALT_ROW     = "F2F9FF"   # Fila alternada
COLOR_TITLE_BG    = "1F4E79"
COLOR_BORDER      = "BDD7EE"


def header_style(bold=True, color=COLOR_HEADER_FG, bg=COLOR_HEADER_BG, size=11):
    return {
        "font":      Font(name=FONT_NAME, bold=bold, color=color, size=size),
        "fill":      PatternFill("solid", fgColor=bg),
        "alignment": Alignment(horizontal="center", vertical="center", wrap_text=True),
    }


def apply_style(cell, font=None, fill=None, alignment=None, border=None, number_format=None):
    if font:        cell.font        = font
    if fill:        cell.fill        = fill
    if alignment:   cell.alignment   = alignment
    if border:      cell.border      = border
    if number_format: cell.number_format = number_format


def thin_border(color=COLOR_BORDER):
    side = Side(style="thin", color=color)
    return Border(left=side, right=side, top=side, bottom=side)


def set_col_width(ws, col, width):
    ws.column_dimensions[get_column_letter(col)].width = width


def load_csv(mode_key):
    path = os.path.join(RESULTS_DIR, f"data_{mode_key}.csv")
    if not os.path.exists(path):
        return None

    df = pd.read_csv(path)


    df.columns = [c.strip().lower() for c in df.columns]


    rename_map = {
        "size":        "matrix_size",
        "n":           "matrix_size",
        "dim":         "matrix_size",
        "dimension":   "matrix_size",
        "rep":         "repetition",
        "repeticion":  "repetition",
        "time_ms":     "wall_time_ms",
        "time":        "wall_time_ms",
        "elapsed_ms":  "wall_time_ms",
        "wall_time":   "wall_time_ms",
        "exit":        "exit_code",
        "code":        "exit_code",
    }
    df = df.rename(columns=rename_map)


    required = {"matrix_size", "repetition", "wall_time_ms"}
    missing  = required - set(df.columns)
    if missing:
        print(f"  [WARN] Columnas encontradas en {path}: {list(df.columns)}")
        print(f"  [WARN] Faltan: {missing}. Ajusta rename_map en load_csv().")
        return None

    return df


def write_mode_sheet(wb, mode_key, label, df_seq):
    df = load_csv(mode_key)

    ws = wb.create_sheet(title=label)
    ws.freeze_panes = "B3"

    is_seq = (mode_key == "sequential")


    ws.merge_cells(f"A1:{get_column_letter(REPETITIONS + 3)}1")
    title_cell = ws["A1"]
    title_cell.value = f"Multiplicación de Matrices  |  {label}"
    title_cell.font  = Font(name=FONT_NAME, bold=True, size=14, color=COLOR_HEADER_FG)
    title_cell.fill  = PatternFill("solid", fgColor=COLOR_TITLE_BG)
    title_cell.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[1].height = 28


    ws.row_dimensions[2].height = 22
    headers = ["Dimensión (N)"] + [f"Rep {i}" for i in range(1, REPETITIONS + 1)] \
              + ["Promedio (ms)", "Speedup"]

    for col, h in enumerate(headers, start=1):
        c = ws.cell(row=2, column=col, value=h)
        bg = COLOR_SUBHDR_BG if col > 1 else COLOR_HEADER_BG
        c.font      = Font(name=FONT_NAME, bold=True, color=COLOR_HEADER_FG, size=10)
        c.fill      = PatternFill("solid", fgColor=bg)
        c.alignment = Alignment(horizontal="center", vertical="center")
        c.border    = thin_border()


    set_col_width(ws, 1, 16)
    for col in range(2, REPETITIONS + 2):
        set_col_width(ws, col, 13)
    set_col_width(ws, REPETITIONS + 2, 15)   # Promedio
    set_col_width(ws, REPETITIONS + 3, 12)   # Speedup


    for row_idx, size in enumerate(MATRIX_SIZES, start=3):
        alt = (row_idx % 2 == 0)


        dim_cell = ws.cell(row=row_idx, column=1, value=f"{size} x {size}")
        dim_cell.font      = Font(name=FONT_NAME, bold=True, size=10)
        dim_cell.fill      = PatternFill("solid", fgColor="D6E4F0")
        dim_cell.alignment = Alignment(horizontal="center")
        dim_cell.border    = thin_border()


        rep_cols = []
        for rep in range(1, REPETITIONS + 1):
            col = rep + 1
            c   = ws.cell(row=row_idx, column=col)

            if df is not None:

                mask = (df["matrix_size"] == size) & (df["repetition"] == rep)
                vals = df.loc[mask, "wall_time_ms"]
                if not vals.empty:
                    c.value = round(float(vals.iloc[0]), 3)

            c.number_format = "0.000"
            c.font          = Font(name=FONT_NAME, size=10)
            c.fill          = PatternFill("solid", fgColor=COLOR_ALT_ROW if alt else "FFFFFF")
            c.alignment     = Alignment(horizontal="right")
            c.border        = thin_border()
            rep_cols.append(get_column_letter(col))


        avg_col = REPETITIONS + 2
        first_rep_col = get_column_letter(2)
        last_rep_col  = get_column_letter(REPETITIONS + 1)
        avg_cell = ws.cell(row=row_idx, column=avg_col)
        avg_cell.value         = f"=AVERAGE({first_rep_col}{row_idx}:{last_rep_col}{row_idx})"
        avg_cell.number_format = "0.000"
        avg_cell.font          = Font(name=FONT_NAME, bold=True, size=10)
        avg_cell.fill          = PatternFill("solid", fgColor=COLOR_AVG_BG)
        avg_cell.alignment     = Alignment(horizontal="right")
        avg_cell.border        = thin_border()


        sp_col  = REPETITIONS + 3
        sp_cell = ws.cell(row=row_idx, column=sp_col)

        if is_seq:
            sp_cell.value = 1.0
        elif df_seq is not None:


            seq_avg_col = get_column_letter(REPETITIONS + 2)
            sp_cell.value = (
                f"=IFERROR(Secuencial!{seq_avg_col}{row_idx}"
                f"/{get_column_letter(avg_col)}{row_idx}, \"N/A\")"
            )
        else:
            sp_cell.value = "Sin datos seq."

        sp_cell.number_format = "0.0000"
        sp_cell.font          = Font(name=FONT_NAME, bold=True, size=10,
                                     color="375623")
        sp_cell.fill          = PatternFill("solid", fgColor=COLOR_SPEEDUP_BG)
        sp_cell.alignment     = Alignment(horizontal="right")
        sp_cell.border        = thin_border()

    return ws


def write_summary_sheet(wb, available_modes):
    ws = wb.create_sheet(title="Resumen")
    ws.freeze_panes = "B3"

    n_modes = len(available_modes)
    last_col = get_column_letter(1 + n_modes * 2)


    ws.merge_cells(f"A1:{last_col}1")
    t = ws["A1"]
    t.value     = "Resumen comparativo  |  Multiplicación de Matrices HPC"
    t.font      = Font(name=FONT_NAME, bold=True, size=14, color=COLOR_HEADER_FG)
    t.fill      = PatternFill("solid", fgColor=COLOR_TITLE_BG)
    t.alignment = Alignment(horizontal="center", vertical="center")
    ws.row_dimensions[1].height = 28


    ws.cell(row=2, column=1, value="Dimensión (N)").font = Font(name=FONT_NAME, bold=True, size=10, color=COLOR_HEADER_FG)
    ws.cell(row=2, column=1).fill      = PatternFill("solid", fgColor=COLOR_HEADER_BG)
    ws.cell(row=2, column=1).alignment = Alignment(horizontal="center")
    ws.cell(row=2, column=1).border    = thin_border()
    set_col_width(ws, 1, 16)

    for m_idx, (mode_key, label) in enumerate(available_modes):

        avg_col = 2 + m_idx * 2
        sp_col  = avg_col + 1

        for col, header in [(avg_col, f"{label}\nPromedio (ms)"),
                            (sp_col,  f"{label}\nSpeedup")]:
            c = ws.cell(row=2, column=col, value=header)
            c.font      = Font(name=FONT_NAME, bold=True, color=COLOR_HEADER_FG, size=9)
            c.fill      = PatternFill("solid", fgColor=COLOR_SUBHDR_BG)
            c.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
            c.border    = thin_border()
            set_col_width(ws, col, 14)

        ws.row_dimensions[2].height = 32


    avg_excel_col = get_column_letter(REPETITIONS + 2)   # columna promedio en hojas individuales
    sp_excel_col  = get_column_letter(REPETITIONS + 3)   # columna speedup en hojas individuales

    for row_idx, size in enumerate(MATRIX_SIZES, start=3):
        alt = (row_idx % 2 == 0)

        d = ws.cell(row=row_idx, column=1, value=f"{size} x {size}")
        d.font      = Font(name=FONT_NAME, bold=True, size=10)
        d.fill      = PatternFill("solid", fgColor="D6E4F0")
        d.alignment = Alignment(horizontal="center")
        d.border    = thin_border()

        for m_idx, (mode_key, label) in enumerate(available_modes):
            avg_col = 2 + m_idx * 2
            sp_col  = avg_col + 1
            sheet_row = row_idx  # misma posición de fila en todas las hojas

            avg_c = ws.cell(row=row_idx, column=avg_col)
            avg_c.value         = f"=IFERROR('{label}'!{avg_excel_col}{sheet_row}, \"N/D\")"
            avg_c.number_format = "0.000"
            avg_c.font          = Font(name=FONT_NAME, size=10)
            avg_c.fill          = PatternFill("solid", fgColor=COLOR_ALT_ROW if alt else "FFFFFF")
            avg_c.alignment     = Alignment(horizontal="right")
            avg_c.border        = thin_border()

            sp_c = ws.cell(row=row_idx, column=sp_col)
            sp_c.value         = f"=IFERROR('{label}'!{sp_excel_col}{sheet_row}, \"N/D\")"
            sp_c.number_format = "0.0000"
            sp_c.font          = Font(name=FONT_NAME, size=10, color="375623")
            sp_c.fill          = PatternFill("solid", fgColor=COLOR_SPEEDUP_BG if not alt else "EAF4E2")
            sp_c.alignment     = Alignment(horizontal="right")
            sp_c.border        = thin_border()

    return ws


def write_charts_sheet(wb, available_modes):
    ws = wb.create_sheet(title="Gráficas")


    ws["A1"] = "Tabla auxiliar para gráficas"
    ws["A1"].font = Font(name=FONT_NAME, bold=True, size=11, color=COLOR_HEADER_FG)
    ws["A1"].fill = PatternFill("solid", fgColor=COLOR_TITLE_BG)

    ws["A2"] = "Dimensión"
    for m_idx, (_, label) in enumerate(available_modes):
        ws.cell(row=2, column=2 + m_idx, value=label).font = Font(name=FONT_NAME, bold=True)

    for r, size in enumerate(MATRIX_SIZES, start=3):
        ws.cell(row=r, column=1, value=size)
        for m_idx, (_, label) in enumerate(available_modes):
            avg_col_summary = get_column_letter(2 + m_idx * 2)
            ws.cell(row=r, column=2 + m_idx,
                    value=f"=IFERROR(Resumen!{avg_col_summary}{r}, 0)")

    chart1 = LineChart()
    chart1.title  = "Tiempo de ejecución vs Dimensión de la matriz"
    chart1.style  = 10
    chart1.y_axis.title = "Tiempo promedio (ms)"
    chart1.x_axis.title = "Dimensión N (NxN)"
    chart1.width  = 22
    chart1.height = 14

    cats = Reference(ws, min_col=1, min_row=3, max_row=3 + len(MATRIX_SIZES) - 1)

    for m_idx in range(len(available_modes)):
        data = Reference(ws, min_col=2 + m_idx, min_row=2,
                         max_row=2 + len(MATRIX_SIZES))
        chart1.add_data(data, titles_from_data=True)

    chart1.set_categories(cats)
    ws.add_chart(chart1, "A12")

    sp_start_row = 3 + len(MATRIX_SIZES) + 2
    ws.cell(row=sp_start_row, column=1, value="Dimensión").font = Font(name=FONT_NAME, bold=True)
    for m_idx, (_, label) in enumerate(available_modes):
        if label == "Secuencial":
            continue
        ws.cell(row=sp_start_row, column=2 + m_idx, value=label).font = Font(name=FONT_NAME, bold=True)

    for r2, size in enumerate(MATRIX_SIZES, start=sp_start_row + 1):
        ws.cell(row=r2, column=1, value=size)
        for m_idx, (_, label) in enumerate(available_modes):
            sp_col_summary = get_column_letter(3 + m_idx * 2)
            ws.cell(row=r2, column=2 + m_idx,
                    value=f"=IFERROR(Resumen!{sp_col_summary}{3 + (r2 - sp_start_row - 1)}, 0)")

    chart2 = LineChart()
    chart2.title  = "Speedup vs Dimensión de la matriz"
    chart2.style  = 10
    chart2.y_axis.title = "Speedup (T_seq / T_paralelo)"
    chart2.x_axis.title = "Dimensión N (NxN)"
    chart2.width  = 22
    chart2.height = 14

    cats2 = Reference(ws, min_col=1, min_row=sp_start_row + 1,
                      max_row=sp_start_row + len(MATRIX_SIZES))

    for m_idx, (_, label) in enumerate(available_modes):
        if label == "Secuencial":
            continue
        data2 = Reference(ws, min_col=2 + m_idx,
                          min_row=sp_start_row,
                          max_row=sp_start_row + len(MATRIX_SIZES))
        chart2.add_data(data2, titles_from_data=True)

    chart2.set_categories(cats2)
    ws.add_chart(chart2, "L12")

    return ws


def main():
    os.makedirs(RESULTS_DIR, exist_ok=True)

    wb = Workbook()

    wb.remove(wb.active)

    available_modes = []
    for mode_key, label in MODE_ORDER:
        path = os.path.join(RESULTS_DIR, f"data_{mode_key}.csv")
        if os.path.exists(path):
            available_modes.append((mode_key, label))
            print(f"  [OK] Encontrado: data_{mode_key}.csv")
        else:
            print(f"  [--] No encontrado: data_{mode_key}.csv  (se omitirá)")

    if not available_modes:
        print("\nNo se encontraron CSVs en results/. Corre primero el benchmark.")
        return


    df_seq = load_csv("sequential")

    for mode_key, label in available_modes:
        print(f"  Generando hoja: {label}")
        write_mode_sheet(wb, mode_key, label, df_seq)

    write_summary_sheet(wb, available_modes)
    write_charts_sheet(wb, available_modes)


    wb.move_sheet("Resumen", offset=-len(wb.sheetnames) + 1)
    wb.move_sheet("Gráficas", offset=1)

    wb.save(OUTPUT_FILE)
    print(f"\nReporte generado: {OUTPUT_FILE}")

if __name__ == "__main__":
    print("Generando reporte Excel HPC...")
    main()