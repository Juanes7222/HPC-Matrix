#!/usr/bin/env bash
# =============================================================================
# bench_profiling.sh -- CPU and memory profiling of the sequential implementation
#
# Tools used:
#   gprof         : time per function (-O2 -fno-inline -pg to prevent inlining
#                   from silencing hot functions)
#   perf stat     : hardware counters repeated PERF_STAT_REPEATS times (-r),
#                   including L1, LLC, TLB, and branch counters
#   perf record   : sampling-based hot-spot profiling with call-graph (-g)
#   valgrind      : heap memory (massif) and cache simulation (cachegrind)
#
# Timing is measured over TIMING_RUNS independent executions; mean and
# standard deviation are reported.
#
# Usage:
#   ./bench_profiling.sh [--force|-f]
#
# Options:
#   --force, -f   Overwrite existing raw reports and CSV rows (re-run all tools)
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

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
FORCE=0
for arg in "$@"; do
    case "${arg}" in
        --force|-f) FORCE=1 ;;
        *) log_warn "Unknown argument: ${arg}" ;;
    esac
done

SRC_FILES="src/sequential/mul_seq.c src/matrix_lib.c"
BIN_DIR="bin"
RESULTS_DIR="tests/benchmarks/machine1/results_profiling"
CSV_FILE="${RESULTS_DIR}/data_profiling.csv"
CSV_HEADER="matrix_size,time_mean_ms,time_std_ms,gflops,cycles,instructions,ipc,\
cache_refs,cache_misses,cache_miss_pct,\
l1_loads,l1_misses,l1_miss_pct,\
LLC_loads,LLC_misses,LLC_miss_pct,\
dTLB_loads,dTLB_misses,dTLB_miss_pct,\
branch_instructions,branch_misses,branch_miss_pct,\
peak_heap_mb"

MATRIX_SIZES=(128 256 512 1024)

# Number of independent timing runs for mean/std computation.
# For small N (128, 256) this matters most; for N=1024 even a few runs suffice,
# but keeping it uniform avoids statistical inconsistency across sizes.
TIMING_RUNS=10

# Number of repetitions passed to perf stat -r.  perf averages the hardware
# counters across runs and reports the coefficient of variation.
PERF_STAT_REPEATS=5

BIN_PERF="${BIN_DIR}/mul_seq_perf"
BIN_GPROF="${BIN_DIR}/mul_seq_gprof"

# ---------------------------------------------------------------------------
# should_skip <file>
#   Returns 0 (skip) if file exists, has content, and FORCE=0.
#   Returns 1 (run)  otherwise.
# ---------------------------------------------------------------------------
should_skip() {
    local file="$1"
    if [[ "${FORCE}" -eq 1 ]]; then
        [[ -f "${file}" ]] && log_info "  [FORCE] Overwriting: ${file}"
        rm -f "${file}"
        return 1
    fi
    if [[ -s "${file}" ]]; then
        log_info "  [SKIP] Already exists and non-empty: $(basename "${file}")"
        return 0
    fi
    [[ -f "${file}" ]] && log_warn "  [STALE] Empty file found, re-running: $(basename "${file}")"
    rm -f "${file}"
    return 1
}

# ---------------------------------------------------------------------------
compile_binaries() {
    log_section "Compiling"
    mkdir -p "${BIN_DIR}"

    if [[ "${FORCE}" -eq 1 ]] || [[ ! -x "${BIN_PERF}" ]]; then
        local cmd="gcc -O2 -g -I./src -o ${BIN_PERF} ${SRC_FILES}"
        log_info "perf/valgrind binary: ${cmd}"
        eval "${cmd}" && log_ok "${BIN_PERF}" || { log_error "Compilation failed"; exit 1; }
    else
        log_info "Already compiled: ${BIN_PERF}"
    fi

    # -fno-inline prevents the compiler from silencing hot leaf functions that
    # would otherwise be inlined and disappear from gprof's flat profile.
    if [[ "${FORCE}" -eq 1 ]] || [[ ! -x "${BIN_GPROF}" ]]; then
        local cmd="gcc -O2 -fno-inline -g -pg -I./src -o ${BIN_GPROF} ${SRC_FILES}"
        log_info "gprof binary: ${cmd}"
        eval "${cmd}" && log_ok "${BIN_GPROF}" || { log_error "Compilation failed"; exit 1; }
    else
        log_info "Already compiled: ${BIN_GPROF}"
    fi
}

# ---------------------------------------------------------------------------
# perf_extract <file> <event_keyword>
#   Extracts the integer counter value for the first line matching the keyword.
#   Lines are filtered to those that start with optional whitespace followed by
#   a digit, which avoids matching comment or header lines.
# ---------------------------------------------------------------------------
perf_extract() {
    local file="$1" keyword="$2"
    [[ ! -s "${file}" ]] && echo "0" && return
    # || echo "0" protege contra grep sin coincidencias (exit 1 con set -e)
    grep -iE "^[[:space:]]*[0-9,].*${keyword}" "${file}" \
        | grep -v "^#" \
        | head -1 \
        | awk '{gsub(",", "", $1); printf "%d", $1+0}' \
        || echo "0"
}

parse_peak_mb() {
    local file="$1"
    awk '
    /^-+$/ { in_table=1; next }
    in_table && /^[[:space:]]*[0-9]/ {
        gsub(",", "")
        if ($4+0 > peak) peak = $4+0
    }
    END { printf "%.3f", peak / 1024 / 1024 }
    ' "${file}"
}

already_done() {
    local size="$1"
    if [[ "${FORCE}" -eq 1 ]]; then
        echo 0; return
    fi
    awk -F',' -v s="${size}" 'NR>1 && $1==s { found=1 } END { print found+0 }' \
        "${CSV_FILE}" 2>/dev/null
}

# ---------------------------------------------------------------------------
run_gprof() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/gprof_report.txt"
    should_skip "${out}" && return

    log_info "  gprof N=${n}"
    "${BIN_GPROF}" "${n}" > /dev/null 2>&1 || true
    if [[ -f gmon.out ]]; then
        gprof "${BIN_GPROF}" gmon.out > "${out}" 2>&1 \
            || log_warn "gprof failed for N=${n}"
        rm -f gmon.out
    else
        log_warn "gmon.out not generated for N=${n}"
        touch "${out}"
    fi
}

# ---------------------------------------------------------------------------
# run_perf <n> <raw_dir>
#   Runs perf stat with -r PERF_STAT_REPEATS.  perf averages the counters
#   across repetitions and appends a coefficient of variation to each line.
#   Counter set covers L1, LLC, TLB, and branch predictors — the four
#   typical bottleneck categories for matmul.
# ---------------------------------------------------------------------------
run_perf() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/perf_stat.txt"
    should_skip "${out}" && return

    log_info "  perf stat (${PERF_STAT_REPEATS} repeats) N=${n}"
    if ! command -v perf &>/dev/null; then
        log_warn "perf not found — skipping hardware counters"
        touch "${out}"
        return
    fi

    perf stat \
        -r "${PERF_STAT_REPEATS}" \
        -e cycles,instructions,\
cache-references,cache-misses,\
L1-dcache-loads,L1-dcache-load-misses,\
LLC-loads,LLC-load-misses,\
dTLB-loads,dTLB-load-misses,\
branch-instructions,branch-misses \
        -o "${out}" \
        "${BIN_PERF}" "${n}" > /dev/null 2>&1 \
        || log_warn "perf stat failed for N=${n}"
}

# ---------------------------------------------------------------------------
# run_perf_mem <n> <raw_dir>
#   Samples memory load accesses and reports the distribution across the
#   memory hierarchy (L1, L2, L3, LFB, RAM).  --sort=mem groups samples by
#   access type so the output is directly comparable across sizes.
# ---------------------------------------------------------------------------
run_perf_mem() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/perf_mem_report.txt"
    should_skip "${out}" && return

    log_info "  perf mem N=${n}"
    if ! command -v perf &>/dev/null; then
        touch "${out}"
        return
    fi

    perf mem record \
        -o "${raw_dir}/perf_mem.data" \
        "${BIN_PERF}" "${n}" > /dev/null 2>&1 \
        || log_warn "perf mem record failed for N=${n}"

    perf mem -t load report \
        --stdio \
        --sort=mem \
        -i "${raw_dir}/perf_mem.data" > "${out}" 2>&1 || true

    rm -f "${raw_dir}/perf_mem.data"
}

# ---------------------------------------------------------------------------
# run_perf_record <n> <raw_dir>
#   Samples the binary at ~1000 Hz with full call-graph capture (-g).
#   The resulting report shows the real hot-spot hierarchy under -O2,
#   complementing gprof which uses instrumented counters.
# ---------------------------------------------------------------------------
run_perf_record() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/perf_record_report.txt"
    should_skip "${out}" && return

    log_info "  perf record N=${n}"
    if ! command -v perf &>/dev/null; then
        touch "${out}"
        return
    fi

    perf record \
        -g \
        -F 999 \
        -o "${raw_dir}/perf.data" \
        "${BIN_PERF}" "${n}" > /dev/null 2>&1 \
        || log_warn "perf record failed for N=${n}"

    perf report \
        --stdio \
        --no-children \
        -i "${raw_dir}/perf.data" > "${out}" 2>&1 || true

    rm -f "${raw_dir}/perf.data"
}

run_massif() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/massif_report.txt"
    should_skip "${out}" && return

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
    should_skip "${out}" && return

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

# ---------------------------------------------------------------------------
# run_timing_multi <n> <raw_dir>
#   Runs the binary TIMING_RUNS times and records each reported time (ms)
#   into timing_runs.txt, one value per line.
#   Warm-up: the first run is discarded to avoid cold-start cache effects.
# ---------------------------------------------------------------------------
run_timing_multi() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/timing_runs.txt"
    should_skip "${out}" && return

    log_info "  timing (${TIMING_RUNS} runs, 1 warm-up discarded) N=${n}"
    "${BIN_PERF}" "${n}" > /dev/null 2>&1 || true  # warm-up run, discarded

    rm -f "${out}"
    local i
    for i in $(seq 1 "${TIMING_RUNS}"); do
        "${BIN_PERF}" "${n}" >> "${out}" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# measure_timing_stats <raw_dir>
#   Reads timing_runs.txt and prints "<mean_ms> <std_ms>" using Python.
# ---------------------------------------------------------------------------
measure_timing_stats() {
    local raw_dir="$1"
    local timing_file="${raw_dir}/timing_runs.txt"

    if [[ ! -s "${timing_file}" ]]; then
        echo "0 0"
        return
    fi

    python3 - "${timing_file}" <<'EOF'
import sys, statistics

vals = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                vals.append(float(line))
            except ValueError:
                pass

if not vals:
    print("0 0")
elif len(vals) == 1:
    print(f"{vals[0]:.3f} 0.000")
else:
    print(f"{statistics.mean(vals):.3f} {statistics.stdev(vals):.3f}")
EOF
}

compute_gflops() {
    local n="$1" mean_ms="$2"
    python3 -c "
n, ms = ${n}, float('${mean_ms}')
if ms <= 0: print('0.000000')
else: print(f'{2 * n**3 / (ms / 1000) / 1e9:.6f}')
"
}

compute_ratio() {
    local num="$1" den="$2" decimals="${3:-4}"
    python3 -c "
n, d = int('${num}' or 0), int('${den}' or 1)
fmt = f'{{:.${decimals}f}}'
print(fmt.format(n / d * 100) if d > 0 else '0.' + '0'*${decimals})
"
}

write_row() {
    local csv="$1" row="$2"
    printf '%s\n' "${row}" >> "${csv}"
    sync
}

profile_size() {
    local n="$1"
    local raw_dir="${RESULTS_DIR}/raw/N${n}"

    if [[ "$(already_done "${n}")" -gt 0 ]]; then
        log_info "[SKIP] N=${n} already in CSV (use --force to re-run)"
        return
    fi

    log_section "Profiling N=${n}"
    mkdir -p "${raw_dir}"

    run_timing_multi "${n}" "${raw_dir}" || log_warn "timing phase failed for N=${n}"
    run_gprof        "${n}" "${raw_dir}" || log_warn "gprof phase failed for N=${n}"
    run_perf         "${n}" "${raw_dir}" || log_warn "perf stat phase failed for N=${n}"
    run_perf_mem "${n}" "${raw_dir}" || log_warn "perf mem phase failed for N=${n}"
    run_perf_record  "${n}" "${raw_dir}" || log_warn "perf record phase failed for N=${n}"
    run_massif       "${n}" "${raw_dir}" || log_warn "massif phase failed for N=${n}"
    run_cachegrind   "${n}" "${raw_dir}" || log_warn "cachegrind phase failed for N=${n}"

    local timing_stats
    timing_stats=$(measure_timing_stats "${raw_dir}") || timing_stats="0 0"
    local time_mean_ms time_std_ms
    time_mean_ms=$(echo "${timing_stats}" | awk '{print $1}')
    time_std_ms=$(echo  "${timing_stats}" | awk '{print $2}')

    local gflops
    gflops=$(compute_gflops "${n}" "${time_mean_ms}") || gflops="0.000000"

    local perf_file="${raw_dir}/perf_stat.txt"

    local cycles instructions
    cycles=$(perf_extract       "${perf_file}" "cycles")
    instructions=$(perf_extract "${perf_file}" "instructions")
    local ipc
    ipc=$(python3 -c "
c, i = int('${cycles}' or 0), int('${instructions}' or 0)
print(f'{i/c:.4f}' if c > 0 else '0.0000')
")

    local cache_refs cache_misses cache_miss_pct
    cache_refs=$(perf_extract    "${perf_file}" "cache-references")
    cache_misses=$(perf_extract  "${perf_file}" "cache-misses")
    cache_miss_pct=$(compute_ratio "${cache_misses}" "${cache_refs}")

    local l1_loads l1_misses l1_miss_pct
    l1_loads=$(perf_extract  "${perf_file}" "L1-dcache-loads")
    l1_misses=$(perf_extract "${perf_file}" "L1-dcache-load-misses")
    l1_miss_pct=$(compute_ratio "${l1_misses}" "${l1_loads}")

    local llc_loads llc_misses llc_miss_pct
    llc_loads=$(perf_extract  "${perf_file}" "LLC-loads")
    llc_misses=$(perf_extract "${perf_file}" "LLC-load-misses")
    llc_miss_pct=$(compute_ratio "${llc_misses}" "${llc_loads}")

    local dtlb_loads dtlb_misses dtlb_miss_pct
    dtlb_loads=$(perf_extract  "${perf_file}" "dTLB-loads")
    dtlb_misses=$(perf_extract "${perf_file}" "dTLB-load-misses")
    dtlb_miss_pct=$(compute_ratio "${dtlb_misses}" "${dtlb_loads}")

    local branch_instructions branch_misses branch_miss_pct
    branch_instructions=$(perf_extract "${perf_file}" "branch-instructions")
    branch_misses=$(perf_extract       "${perf_file}" "branch-misses")
    branch_miss_pct=$(compute_ratio "${branch_misses}" "${branch_instructions}")

    local massif_file="${raw_dir}/massif_report.txt"
    local peak_heap_mb
    peak_heap_mb=$(parse_peak_mb "${massif_file}") || peak_heap_mb="0.000"

    if [[ "${FORCE}" -eq 1 ]] && [[ -f "${CSV_FILE}" ]]; then
        local tmp
        tmp=$(mktemp)
        awk -F',' -v s="${n}" '$1!=s' "${CSV_FILE}" > "${tmp}"
        mv "${tmp}" "${CSV_FILE}"
    fi

    write_row "${CSV_FILE}" \
        "${n},${time_mean_ms},${time_std_ms},${gflops},\
${cycles},${instructions},${ipc},\
${cache_refs},${cache_misses},${cache_miss_pct},\
${l1_loads},${l1_misses},${l1_miss_pct},\
${llc_loads},${llc_misses},${llc_miss_pct},\
${dtlb_loads},${dtlb_misses},${dtlb_miss_pct},\
${branch_instructions},${branch_misses},${branch_miss_pct},\
${peak_heap_mb}"

    log_ok "N=${n}: ${time_mean_ms} ± ${time_std_ms} ms | ${gflops} GFLOPS | \
L1 miss ${l1_miss_pct}% | LLC miss ${llc_miss_pct}% | \
dTLB miss ${dtlb_miss_pct}% | heap ${peak_heap_mb} MB"
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
    echo " Sizes        : ${MATRIX_SIZES[*]}"
    echo " Timing runs  : ${TIMING_RUNS} (+ 1 warm-up discarded)"
    echo " perf repeats : ${PERF_STAT_REPEATS}"
    echo " Binaries     : ${BIN_PERF} | ${BIN_GPROF}"
    echo " Output       : ${CSV_FILE}"
    echo " Mode         : $([ "${FORCE}" -eq 1 ] && echo 'FORCE (overwrite)' || echo 'incremental')"
    echo " Date         : $(date '+%Y-%m-%d %H:%M:%S')"
    echo " GCC          : $(gcc --version | head -1)"
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