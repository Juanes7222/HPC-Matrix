#!/usr/bin/env bash
# =============================================================================
# bench_profiling.sh -- CPU and memory profiling of the sequential implementation
#
# Tools used:
#   gprof       : time per function (requires -pg compile flag)
#   perf stat   : hardware counters (cycles, IPC, cache misses)
#   valgrind    : heap memory (massif) and cache simulation (cachegrind)
#
# Usage:
#   ./bench_profiling.sh
#
# Output:
#   results_profiling/data_profiling.csv   <- parsed metrics (input for Python)
#   results_profiling/raw/N<size>/         <- raw tool reports per size
#
# Requires: gcc, gprof, perf, valgrind, python3
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

cd "$(dirname "$0")/../.."

source "tests/benchmarks/bench_utils.sh"


SRC_FILES="src/sequential/mul_seq.c src/matrix_lib.c"
BIN_DIR="bin"
RESULTS_DIR="tests/benchmarks/machine1/results_profiling"
CSV_FILE="${RESULTS_DIR}/data_profiling.csv"
CSV_HEADER="matrix_size,time_ms,gflops,cycles,instructions,ipc,cache_refs,cache_misses,cache_miss_pct,l1_loads,l1_misses,l1_miss_pct,peak_heap_mb"

MATRIX_SIZES=(128 256 512 1024)

BIN_PERF="${BIN_DIR}/mul_seq_perf"       
BIN_GPROF="${BIN_DIR}/mul_seq_gprof"     


compile_binaries() {
    log_section "Compiling"
    mkdir -p "${BIN_DIR}"

    if [[ ! -x "${BIN_PERF}" ]]; then
        local cmd="gcc -O2 -g -I./src -o ${BIN_PERF} ${SRC_FILES}"
        log_info "perf/valgrind binary: ${cmd}"
        eval "${cmd}" && log_ok "${BIN_PERF}" || { log_error "Compilation failed"; exit 1; }
    else
        log_info "Already compiled: ${BIN_PERF}"
    fi

    if [[ ! -x "${BIN_GPROF}" ]]; then
        local cmd="gcc -O2 -g -pg -I./src -o ${BIN_GPROF} ${SRC_FILES}"
        log_info "gprof binary: ${cmd}"
        eval "${cmd}" && log_ok "${BIN_GPROF}" || { log_error "Compilation failed"; exit 1; }
    else
        log_info "Already compiled: ${BIN_GPROF}"
    fi
}

perf_extract() {
    local file="$1" keyword="$2"
    grep -i "${keyword}" "${file}" | head -1 \
        | awk '{gsub(",","",$1); printf "%d", $1+0}'
}

parse_peak_mb() {
    local file="$1"
    awk '
    /^-+$/ { in_table=1; next }
    in_table && /^[[:space:]]*[0-9]/ {
        gsub(",", "")
        # columns: index time total useful-heap extra-heap stacks
        if ($4+0 > peak) peak = $4+0
    }
    END { printf "%.3f", peak / 1024 / 1024 }
    ' "${file}"
}

already_done() {
    local size="$1"
    awk -F',' -v s="${size}" 'NR>1 && $1==s { found=1 } END { print found+0 }' \
        "${CSV_FILE}" 2>/dev/null
}

run_gprof() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/gprof_report.txt"
    [[ -f "${out}" ]] && return

    log_info "  gprof N=${n}"
    "${BIN_GPROF}" "${n}" > /dev/null 2>&1
    gprof "${BIN_GPROF}" gmon.out > "${out}" 2>&1 || log_warn "gprof failed for N=${n}"
    rm -f gmon.out
}

run_perf() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/perf_stat.txt"
    [[ -f "${out}" ]] && return

    log_info "  perf stat N=${n}"
    if ! command -v perf &>/dev/null; then
        log_warn "perf not found — skipping hardware counters"
        touch "${out}"
        return
    fi

    perf stat \
        -e cycles,instructions,cache-misses,cache-references,\
L1-dcache-load-misses,L1-dcache-loads \
        -o "${out}" \
        "${BIN_PERF}" "${n}" > "${raw_dir}/timing.txt" 2>&1 \
        || log_warn "perf stat failed for N=${n}"
}

run_massif() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/massif_report.txt"
    [[ -f "${out}" ]] && return

    log_info "  valgrind massif N=${n}"
    if ! command -v valgrind &>/dev/null; then
        log_warn "valgrind not found — skipping memory profiling"
        touch "${out}"
        return
    fi

    valgrind --tool=massif \
        --massif-out-file="${raw_dir}/massif.out" \
        "${BIN_PERF}" "${n}" > /dev/null 2>&1 \
        || log_warn "massif failed for N=${n}"

    ms_print "${raw_dir}/massif.out" > "${out}" 2>&1 || true
    rm -f "${raw_dir}/massif.out"
}

run_cachegrind() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/cachegrind_report.txt"
    [[ -f "${out}" ]] && return

    log_info "  valgrind cachegrind N=${n}"
    if ! command -v valgrind &>/dev/null; then
        touch "${out}"
        return
    fi

    valgrind --tool=cachegrind \
        --cachegrind-out-file="${raw_dir}/cachegrind.out" \
        "${BIN_PERF}" "${n}" > /dev/null 2>&1 \
        || log_warn "cachegrind failed for N=${n}"

    cg_annotate "${raw_dir}/cachegrind.out" > "${out}" 2>&1 || true
    rm -f "${raw_dir}/cachegrind.out"
}

measure_timing() {
    local n="$1" raw_dir="$2"
    local timing="${raw_dir}/timing.txt"

    if [[ -s "${timing}" ]]; then
        head -1 "${timing}"
        return
    fi

    "${BIN_PERF}" "${n}" 2>/dev/null | head -1
}

compute_gflops() {
    local n="$1" ms="$2"
    python3 -c "
n, ms = ${n}, float('${ms}')
if ms <= 0: print('0.000')
else: print(f'{2 * n**3 / (ms / 1000) / 1e9:.6f}')
"
}

write_row() {
    local csv="$1"
    shift
    printf '%s\n' "$*" >> "${csv}"
    sync
}

profile_size() {
    local n="$1"
    local raw_dir="${RESULTS_DIR}/raw/N${n}"

    if [[ "$(already_done "${n}")" -gt 0 ]]; then
        log_info "[SKIP] N=${n} already in CSV"
        return
    fi

    log_section "Profiling N=${n}"
    mkdir -p "${raw_dir}"

    run_gprof    "${n}" "${raw_dir}"
    run_perf     "${n}" "${raw_dir}"
    run_massif   "${n}" "${raw_dir}"
    run_cachegrind "${n}" "${raw_dir}"

    local time_ms
    time_ms=$(measure_timing "${n}" "${raw_dir}")
    local gflops
    gflops=$(compute_gflops "${n}" "${time_ms}")

    local perf_file="${raw_dir}/perf_stat.txt"
    local cycles instructions ipc cache_refs cache_misses cache_miss_pct
    local l1_loads l1_misses l1_miss_pct

    cycles=$(perf_extract "${perf_file}" "cycles")
    instructions=$(perf_extract "${perf_file}" "instructions")
    ipc=$(python3 -c "
c, i = int('${cycles}' or 0), int('${instructions}' or 0)
print(f'{i/c:.4f}' if c>0 else '0.0000')
")
    cache_refs=$(perf_extract "${perf_file}" "cache-references")
    cache_misses=$(perf_extract "${perf_file}" "cache-misses")
    cache_miss_pct=$(python3 -c "
r, m = int('${cache_refs}' or 1), int('${cache_misses}' or 0)
print(f'{m/r*100:.4f}' if r>0 else '0.0000')
")
    l1_loads=$(perf_extract "${perf_file}" "L1-dcache-loads")
    l1_misses=$(perf_extract "${perf_file}" "L1-dcache-load-misses")
    l1_miss_pct=$(python3 -c "
r, m = int('${l1_loads}' or 1), int('${l1_misses}' or 0)
print(f'{m/r*100:.4f}' if r>0 else '0.0000')
")

    local massif_file="${raw_dir}/massif_report.txt"
    local peak_heap_mb
    peak_heap_mb=$(parse_peak_mb "${massif_file}")

    write_row "${CSV_FILE}" \
        "${n},${time_ms},${gflops},${cycles},${instructions},${ipc}," \
        "${cache_refs},${cache_misses},${cache_miss_pct}," \
        "${l1_loads},${l1_misses},${l1_miss_pct},${peak_heap_mb}"

    log_ok "N=${n}: ${time_ms} ms | ${gflops} GFLOPS | ${cache_miss_pct}% cache miss | ${peak_heap_mb} MB"
}

print_summary() {
    log_section "Results"
    column -t -s',' "${CSV_FILE}"
    log_ok "CSV: ${CSV_FILE}"
    log_ok "Raw reports: ${RESULTS_DIR}/raw/"
}

print_banner() {
    echo -e "${BOLD}"
    echo "============================================================"
    echo " Sequential Matrix Multiplication — CPU & Memory Profiling"
    echo " Sizes      : ${MATRIX_SIZES[*]}"
    echo " Binaries   : ${BIN_PERF} | ${BIN_GPROF}"
    echo " Output     : ${CSV_FILE}"
    echo " Date       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo " GCC        : $(gcc --version | head -1)"
    echo "============================================================"
    echo -e "${RESET}"
}

main() {
    print_banner
    compile_binaries
    trap restore_system EXIT
    optimize_system
    setup_csv "${RESULTS_DIR}" "${CSV_FILE}" "${CSV_HEADER}"

    for n in "${MATRIX_SIZES[@]}"; do
        profile_size "${n}"
    done

    print_summary

    log_section "Generating report"
    python3 tests/benchmarks/report_profiling.py "${CSV_FILE}" \
        && log_ok "Report generated." \
        || log_warn "Python report failed — check report_profiling.py"
}

main