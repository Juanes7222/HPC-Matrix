#!/usr/bin/env bash
# =============================================================================
# bench_omp.sh  --  OpenMP matrix multiplication benchmark
#
# Measures the performance of the OpenMP implementation across multiple matrix
# sizes and thread counts. Thread counts are derived automatically from the
# number of logical CPUs available on the current machine.
#
# Usage:
#   ./bench_omp.sh <machine_flag>
#
# Arguments:
#   machine_flag : label for the current machine (e.g. machine1, machine2).
#                  Controls the output directory and tags all CSV rows.
#
# Output:
#   tests/benchmarks/<machine_flag>/results_omp/data_omp.csv
#   tests/benchmarks/<machine_flag>/results_omp/summary_omp.txt
#
# Requires: bench_utils.sh in the same directory.
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

cd "$(dirname "$0")/../.."

# shellcheck source=tests/benchmarks/bench_utils.sh
source "tests/benchmarks/bench_utils.sh"

# ---------------------------------------------------------------------------
# ARGUMENT PARSING
# ---------------------------------------------------------------------------

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <machine_flag>" >&2
    exit 1
fi

MACHINE_FLAG="$1"

# ---------------------------------------------------------------------------
# CONFIGURATION
# ---------------------------------------------------------------------------

BIN_DIR="bin"
RESULTS_DIR="tests/benchmarks/${MACHINE_FLAG}/results_omp"

MATRIX_SIZES=(400 800 1600 3200 6400)
REPETITIONS=10

# Derive CPU count dynamically from the current machine
TOTAL_CPUS=$(nproc)
BENCH_CPUS=$(seq -s',' 0 $(( TOTAL_CPUS - 1 )))
BENCH_CPU_SINGLE="0"

# Build thread counts: powers of 2 up to TOTAL_CPUS, plus TOTAL_CPUS itself
ALL_THREAD_COUNTS=()
t=2
while [[ "${t}" -lt "${TOTAL_CPUS}" ]]; do
    ALL_THREAD_COUNTS+=("${t}")
    t=$(( t * 2 ))
done
ALL_THREAD_COUNTS+=("${TOTAL_CPUS}")

# NO COMPILER FLAGS FOR COMPILER OPTIMIZATION (we want to test the effect of threads, not flags)
BEST_FLAGS="-Wall"

# CSV columns: machine,impl,flags,threads,matrix_size,repetition,wall_time_ms
CSV_HEADER="machine,impl,flags,threads,matrix_size,repetition,wall_time_ms"

BIN_OMP="${BIN_DIR}/mul_omp"
SRC_OMP="src/openmp/mul_openmp.c"

# ---------------------------------------------------------------------------
# COMPILATION
# ---------------------------------------------------------------------------

compile_omp() {
    if [[ -x "${BIN_OMP}" ]]; then
        log_info "Already compiled: ${BIN_OMP}"
        return 0
    fi

    if [[ ! -f "${SRC_OMP}" ]]; then
        log_error "Source not found: ${SRC_OMP}"
        return 1
    fi

    local flags_clean
    flags_clean=$(echo "${BEST_FLAGS}" | tr -s ' ' | xargs)

    log_info "Compiling mul_omp via Makefile"

    if make -B bin/mul_omp OPT_FLAGS="${flags_clean}" >/dev/null 2>&1; then
        log_ok "Binary: ${BIN_OMP}"
    else
        log_error "Compilation failed: ${SRC_OMP}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# HELPERS
# ---------------------------------------------------------------------------

already_done() {
    local csv="$1" machine="$2" threads="$3" size="$4" rep="$5"
    awk -F',' \
        -v ma="${machine}" -v th="${threads}" \
        -v si="${size}"    -v re="${rep}" \
        'NR>1 && $1==ma && $4==th && $5==si && $6==re { found=1 }
         END { print found+0 }' \
        "${csv}" 2>/dev/null
}

run_single() {
    local bin="$1" size="$2" threads="$3"
    local exit_code=0 ms

    ms=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
        "${bin}" "${size}" "${threads}" 2>/dev/null) || exit_code=$?

    if [[ -z "${ms}" || "${exit_code}" -ne 0 ]]; then
        echo "0.000"
        return
    fi
    echo "${ms}"
}

write_row() {
    local csv="$1" machine="$2" threads="$3" size="$4" rep="$5" ms="$6"
    printf '%s,mul_omp,"%s",%s,%s,%s,%s\n' \
        "${machine}" "${BEST_FLAGS}" "${threads}" \
        "${size}" "${rep}" "${ms}" >> "${csv}"
    sync
}

# ---------------------------------------------------------------------------
# BENCHMARK LOOP
# ---------------------------------------------------------------------------

run_benchmark() {
    local csv="${RESULTS_DIR}/data_omp.csv"
    setup_csv "${RESULTS_DIR}" "${csv}" "${CSV_HEADER}"

    for threads in "${ALL_THREAD_COUNTS[@]}"; do
        log_section "Measuring: mul_omp  threads=${threads}  machine=${MACHINE_FLAG}"

        for rep in $(seq 1 "${REPETITIONS}"); do
            for size in "${MATRIX_SIZES[@]}"; do
                if [[ "$(already_done "${csv}" "${MACHINE_FLAG}" \
                        "${threads}" "${size}" "${rep}")" -gt 0 ]]; then
                    log_info "  [SKIP] threads=${threads} size=${size} rep=${rep}"
                    continue
                fi

                printf "  rep=%-2s  size=%-6s  threads=%-3s  " \
                    "${rep}" "${size}" "${threads}"
                local ms
                ms=$(run_single "${BIN_OMP}" "${size}" "${threads}")
                printf "%s ms\n" "${ms}"

                write_row "${csv}" "${MACHINE_FLAG}" "${threads}" \
                          "${size}" "${rep}" "${ms}"
            done
        done
    done
}

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------

print_summary() {
    local csv="${RESULTS_DIR}/data_omp.csv"
    local summary="${RESULTS_DIR}/summary_omp.txt"
    local tmpfile="${RESULTS_DIR}/.avgs_omp.tmp"

    # Compute averages per (threads, size)
    awk -F',' '
    NR==1 { next }
    {
        key = $4 SUBSEP $5
        sum[key] += $7
        cnt[key]++
    }
    END {
        for (k in sum) {
            split(k, a, SUBSEP)
            printf "%s|%s|%.3f\n", a[1], a[2], sum[k]/cnt[k]
        }
    }' "${csv}" | sort -t'|' -k1,1n -k2,2n > "${tmpfile}"

    # Reference: lowest thread count
    local ref_threads="${ALL_THREAD_COUNTS[0]}"
    declare -A REF_AVG
    while IFS='|' read -r threads size avg; do
        if [[ "${threads}" == "${ref_threads}" ]]; then
            REF_AVG["${size}"]="${avg}"
        fi
    done < "${tmpfile}"

    {
        echo ""
        echo "Machine   : ${MACHINE_FLAG}"
        echo "Date      : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host      : $(hostname)"
        echo "CPUs      : ${TOTAL_CPUS}  (taskset: ${BENCH_CPUS})"
        echo "Threads   : ${ALL_THREAD_COUNTS[*]}"
        echo "GCC       : $(gcc --version | head -1)"
        echo "Sizes     : ${MATRIX_SIZES[*]}"
        echo "Reps      : ${REPETITIONS}"
        echo "Reference : ${ref_threads} threads"
        echo ""
        echo "Average wall time (ms)"
        echo "======================================================================="
        printf "%-12s" "Threads"
        for size in "${MATRIX_SIZES[@]}"; do
            printf "  %9s" "N=${size}"
        done
        printf "  %10s\n" "Avg Speedup"
        printf "%-12s" "------------"
        for size in "${MATRIX_SIZES[@]}"; do
            printf "  %9s" "---------"
        done
        printf "  %10s\n" "----------"

        declare -A ROW
        while IFS='|' read -r threads size avg; do
            ROW["${threads}:${size}"]="${avg}"
        done < "${tmpfile}"

        for threads in "${ALL_THREAD_COUNTS[@]}"; do
            printf "%-12s" "${threads}t"
            local sp_sum=0 sp_cnt=0

            for size in "${MATRIX_SIZES[@]}"; do
                local avg="${ROW[${threads}:${size}]:-}"
                if [[ -z "${avg}" ]]; then
                    printf "  %9s" "N/A"
                    continue
                fi
                printf "  %9.1f" "${avg}"

                local ref="${REF_AVG[${size}]:-}"
                if [[ -n "${ref}" && "${avg}" != "0.000" ]]; then
                    local sp
                    sp=$(echo "scale=4; ${ref} / ${avg}" | bc 2>/dev/null || echo "0")
                    sp_sum=$(echo "scale=4; ${sp_sum} + ${sp}" | bc)
                    sp_cnt=$(( sp_cnt + 1 ))
                fi
            done

            if (( sp_cnt > 0 )); then
                local avg_sp
                avg_sp=$(echo "scale=3; ${sp_sum} / ${sp_cnt}" | bc)
                printf "  %10sx\n" "${avg_sp}"
            else
                printf "  %10s\n" "N/A"
            fi
        done

        echo ""
        echo "Speedup = T(${ref_threads}t) / T(row)  (>1 means row is faster than ${ref_threads} threads)"

    } | tee "${summary}"

    rm -f "${tmpfile}"
    log_ok "Summary : ${summary}"
    log_ok "Raw data: ${csv}"
}

# ---------------------------------------------------------------------------
# BANNER
# ---------------------------------------------------------------------------

print_banner() {
    echo -e "${BOLD}"
    echo "============================================================"
    echo "   OpenMP Matrix Multiplication Benchmark"
    echo "   Machine     : ${MACHINE_FLAG}"
    echo "   CPUs        : ${TOTAL_CPUS}  (taskset: ${BENCH_CPUS})"
    echo "   Threads     : ${ALL_THREAD_COUNTS[*]}"
    echo "   Sizes       : ${MATRIX_SIZES[*]}"
    echo "   Repetitions : ${REPETITIONS}"
    echo "   Flags       : ${BEST_FLAGS}"
    echo "   Date        : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo -e "${RESET}"
}

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

main() {
    mkdir -p "${RESULTS_DIR}" "${BIN_DIR}"
    trap restore_system EXIT
    optimize_system

    print_banner
    compile_omp
    run_benchmark
    print_summary
}

main