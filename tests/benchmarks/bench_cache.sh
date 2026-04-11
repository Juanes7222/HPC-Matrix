#!/usr/bin/env bash
# =============================================================================
# bench_cache.sh  --  Cache line optimization benchmark
#
# Compares two sequential matrix multiplication implementations:
#   mul_seq_std   : standard row x column  (column-major access on matrix2)
#   mul_seq_cache : row x row via transposed matrix2  (sequential cache access)
#
# Sizes: 1000, 2000, 3000
#
# Output:
#   results_cache/data_cache.csv      raw measurements
#   results_cache/summary_cache.txt   per-size table + speedup
#
# Usage:
#   ./bench_cache.sh
# =============================================================================

set -euo pipefail

BIN_DIR="bin"
RESULTS_DIR="results_cache"
CSV_FILE="${RESULTS_DIR}/data_cache.csv"
SUMMARY_FILE="${RESULTS_DIR}/summary_cache.txt"

SRC_COMMON="matrix_lib.c"
SRC_STD="mul_seq.c"
SRC_CACHE="mul_seq_cache.c"

BIN_STD="${BIN_DIR}/mul_seq_std"
BIN_CACHE="${BIN_DIR}/mul_seq_cache"

FLAGS="-Wall"

MATRIX_SIZES=(1000 2000 3000)
REPETITIONS=5
BENCH_CPU="0"

# shellcheck source=bench_utils.sh
source "$(dirname "$0")/bench_utils.sh"

setup() {
    setup_csv "${RESULTS_DIR}" "${CSV_FILE}" \
        "impl,matrix_size,repetition,wall_time_ms"
}

compile_all() {
    log_section "Compiling"

    if [[ ! -x "${BIN_STD}" ]]; then
        log_info "Compiling standard: gcc ${FLAGS} -o ${BIN_STD} ${SRC_STD} ${SRC_COMMON}"
        gcc ${FLAGS} -o "${BIN_STD}" "${SRC_STD}" "${SRC_COMMON}"
        log_ok "Binary: ${BIN_STD}"
    else
        log_info "Standard binary already exists, skipping."
    fi

    if [[ ! -x "${BIN_CACHE}" ]]; then
        log_info "Compiling cache-optimized: gcc ${FLAGS} -o ${BIN_CACHE} ${SRC_CACHE} ${SRC_COMMON}"
        gcc ${FLAGS} -o "${BIN_CACHE}" "${SRC_CACHE}" "${SRC_COMMON}"
        log_ok "Binary: ${BIN_CACHE}"
    else
        log_info "Cache binary already exists, skipping."
    fi
}

already_done() {
    local impl="$1" size="$2" rep="$3"
    awk -F',' -v i="${impl}" -v s="${size}" -v r="${rep}" \
        'NR>1 && $1==i && $2==s && $3==r { found=1 }
         END { print found+0 }' \
        "${CSV_FILE}" 2>/dev/null
}

run_single() {
    local bin="$1" size="$2"
    local ms exit_code=0

    ms=$(taskset -c "${BENCH_CPU}" "${bin}" "${size}" 2>/dev/null) || exit_code=$?

    if [[ -z "${ms}" || "${exit_code}" -ne 0 ]]; then
        echo "0.000"
        return
    fi
    echo "${ms}"
}

write_row() {
    printf '%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" >> "${CSV_FILE}"
    sync
}

run_benchmark() {
    local impls=("std" "cache")
    local bins=("${BIN_STD}" "${BIN_CACHE}")

    for idx in 0 1; do
        local impl="${impls[$idx]}"
        local bin="${bins[$idx]}"

        log_section "Implementation: ${impl}"

        for rep in $(seq 1 "${REPETITIONS}"); do
            for size in "${MATRIX_SIZES[@]}"; do
                if [[ "$(already_done "${impl}" "${size}" "${rep}")" -gt 0 ]]; then
                    log_info "  [SKIP] impl=${impl} size=${size} rep=${rep}"
                    continue
                fi

                printf "  impl=%-6s  rep=%-2s  size=%-6s  " "${impl}" "${rep}" "${size}"
                local ms
                ms=$(run_single "${bin}" "${size}")
                printf "%s ms\n" "${ms}"

                write_row "${impl}" "${size}" "${rep}" "${ms}"
            done
        done
    done
}

print_summary() {
    log_section "Results summary"

    local tmpfile="${RESULTS_DIR}/.avgs.tmp"

    # Compute averages: impl, size -> avg ms
    awk -F',' '
    NR==1 { next }
    {
        key = $1 SUBSEP $2
        sum[key] += $4
        cnt[key]++
    }
    END {
        for (k in sum) {
            split(k, a, SUBSEP)
            printf "%s,%s,%.3f\n", a[1], a[2], sum[k]/cnt[k]
        }
    }' "${CSV_FILE}" | sort -t',' -k1,1 -k2,2n > "${tmpfile}"

    # Collect std averages per size for speedup reference
    declare -A STD_AVG
    while IFS=',' read -r impl size avg; do
        if [[ "${impl}" == "std" ]]; then
            STD_AVG["${size}"]="${avg}"
        fi
    done < "${tmpfile}"

    {
        echo ""
        echo "Compiler flags: ${FLAGS}"
        echo "Repetitions   : ${REPETITIONS}"
        echo "CPU affinity  : core ${BENCH_CPU}"
        echo "Date          : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "GCC           : $(gcc --version | head -1)"
        echo ""
        echo "Per-size average wall time (ms)"
        echo "======================================================================="
        printf "%-10s" "Impl"
        for size in "${MATRIX_SIZES[@]}"; do
            printf "  %10s" "N=${size}"
        done
        printf "  %12s\n" "Avg Speedup"
        printf "%-10s" "----------"
        for size in "${MATRIX_SIZES[@]}"; do
            printf "  %10s" "----------"
        done
        printf "  %12s\n" "------------"

        for impl in "std" "cache"; do
            printf "%-10s" "${impl}"
            local sp_sum=0
            local sp_cnt=0

            for size in "${MATRIX_SIZES[@]}"; do
                local avg
                avg=$(awk -F',' -v i="${impl}" -v s="${size}" \
                    '$1==i && $2==s { print $3 }' "${tmpfile}")

                if [[ -z "${avg}" ]]; then
                    printf "  %10s" "N/A"
                    continue
                fi
                printf "  %10.1f" "${avg}"

                local ref="${STD_AVG[${size}]:-}"
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
                printf "  %11sx\n" "${avg_sp}"
            else
                printf "  %12s\n" "N/A"
            fi
        done

        echo ""
        echo "Note: Speedup = T(std) / T(cache)  (>1 means cache version is faster)"

    } | tee "${SUMMARY_FILE}"

    rm -f "${tmpfile}"
    echo ""
    log_ok "Summary : ${SUMMARY_FILE}"
    log_ok "Raw data: ${CSV_FILE}"
}

print_banner() {
    echo -e "${BOLD}"
    echo "============================================================"
    echo "   Cache Line Optimization Benchmark  --  Sequential MatMul"
    echo "   Implementations : std (row x col) | cache (row x row)"
    echo "   Sizes           : ${MATRIX_SIZES[*]}"
    echo "   Repetitions     : ${REPETITIONS}"
    echo "   Flags           : ${FLAGS}"
    echo "   CPU core        : ${BENCH_CPU}"
    echo "   Date            : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo -e "${RESET}"
}

main() {
    print_banner
    trap restore_system EXIT
    optimize_system
    setup
    compile_all
    run_benchmark
    print_summary
}

main