#!/usr/bin/env bash
# =============================================================================
# bench_final.sh  --  Final benchmark: three experimental suites
#
# Suite 1 - compiler   : seq+O3_full  vs  threads(2,4,6,8,12)+noopt  vs  conc+noopt
#           Main question: can compiler optimization alone beat parallelism?
#
# Suite 2 - cache      : seq_std+noopt  vs  seq_cache+noopt
#           Isolates the cache line (transposed matrix) effect.
#
# Suite 3 - mixed      : seq_cache+O3_full  vs  threads(Nt)+O3_full  vs  conc+O3_full
#           Both optimizations combined: best vs best.
#
# Usage:
#   ./bench_final.sh [compiler|cache|mixed|all]
#   Defaults to: all
#
# Output:
#   results_final/data_<suite>.csv
#   results_final/summary_<suite>.txt
#
# Requires: bench_utils.sh in the same directory.
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

cd "$(dirname "$0")/../.."

# shellcheck source=tests/benchmarks/bench_utils.sh
source "tests/benchmarks/bench_utils.sh"


BIN_DIR="bin"
RESULTS_DIR="tests/benchmarks/machine1/results_final"

MATRIX_SIZES=(400 800 1600 3200 6400)
REPETITIONS=10
BENCH_CPUS="0,1,2,3,4,5,6,7,8,9,10,11"
BENCH_CPU_SINGLE="0"

# Best compiler config from bench_opt results
BEST_FLAGS="-O3 -Wall -march=native -funroll-loops -flto -ffast-math -fomit-frame-pointer"
NOOPT_FLAGS="-Wall"

ALL_THREAD_COUNTS=(2 4 6 8 12)

# CSV columns: suite,impl,flags,threads,matrix_size,repetition,wall_time_ms
CSV_HEADER="suite,impl,flags,threads,matrix_size,repetition,wall_time_ms"

# ---------------------------------------------------------------------------
# BINARY NAMING
# ---------------------------------------------------------------------------
# Binaries are tagged with their flag set to allow both variants to coexist:
#   bin/mul_seq_std_noopt
#   bin/mul_seq_std_best
#   bin/mul_seq_cache_noopt
#   bin/mul_seq_cache_best
#   bin/mul_threads_noopt
#   bin/mul_threads_best
#   bin/mul_conc_noopt
#   bin/mul_conc_best

flag_tag() {
    local flags="$1"
    if [[ "${flags}" == "${BEST_FLAGS}" ]]; then
        echo "best"
    else
        echo "noopt"
    fi
}

bin_path() {
    local src_key="$1"   # seq_std | seq_cache | threads | conc
    local flags="$2"
    echo "${BIN_DIR}/mul_${src_key}_$(flag_tag "${flags}")"
}

declare -A SRC_FILE=(
    [seq_std]="src/sequential/mul_seq.c"
    [seq_cache]="src/sequential/mul_seq_cache.c"
    [threads]="src/threads/mul_threads.c"
    [conc]="src/processes/mul_conc.c"
)

# Extra link flags needed per source key
declare -A EXTRA_FLAGS=(
    [seq_std]=""
    [seq_cache]=""
    [threads]="-lpthread"
    [conc]=""
)

compile_binary() {
    local src_key="$1"
    local flags="$2"
    local bin
    bin="$(bin_path "${src_key}" "${flags}")"

    if [[ -x "${bin}" ]]; then
        log_info "Already compiled: ${bin}"
        return 0
    fi

    local src="${SRC_FILE[${src_key}]}"
    if [[ ! -f "${src}" ]]; then
        log_error "Source not found: ${src}"
        return 1
    fi

    local tag
    tag="$(flag_tag "${flags}")"
    local extra="${EXTRA_FLAGS[${src_key}]}"
    local flags_clean
    flags_clean=$(echo "${flags}" | tr -s ' ' | xargs)

    local cmd="gcc ${flags_clean} ${extra} -o ${bin} ${src} src/matrix_lib.c"
    log_info "Compiling [${src_key}/${tag}]: ${cmd}"

    if eval "${cmd}" 2>/dev/null; then
        log_ok "Binary: ${bin}"
    else
        log_error "Compilation failed: ${src_key}/${tag}"
        return 1
    fi
}

compile_suite_binaries() {
    local suite="$1"
    log_section "Compiling binaries for suite: ${suite}"
    mkdir -p "${BIN_DIR}"

    case "${suite}" in
        compiler)
            compile_binary seq_std  "${BEST_FLAGS}"
            compile_binary threads  "${NOOPT_FLAGS}"
            compile_binary conc     "${NOOPT_FLAGS}"
            ;;
        cache)
            compile_binary seq_cache "${NOOPT_FLAGS}"
            ;;
        mixed)
            compile_binary seq_cache "${BEST_FLAGS}"
            compile_binary threads   "${BEST_FLAGS}"
            compile_binary conc      "${BEST_FLAGS}"
            ;;
    esac
}

already_done() {
    local csv="$1" suite="$2" impl="$3" threads="$4" size="$5" rep="$6"
    awk -F',' \
        -v su="${suite}" -v im="${impl}" -v th="${threads}" \
        -v si="${size}"  -v re="${rep}" \
        'NR>1 && $1==su && $2==im && $4==th && $5==si && $6==re { found=1 }
         END { print found+0 }' \
        "${csv}" 2>/dev/null
}

run_single() {
    local bin="$1" size="$2" threads="$3"
    local exit_code=0 ms

    if [[ "${threads}" -gt 0 ]]; then
        ms=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
            "${bin}" "${size}" "${threads}" 2>/dev/null) || exit_code=$?
    else
        ms=$(taskset -c "${BENCH_CPU_SINGLE}" \
            "${bin}" "${size}" 2>/dev/null) || exit_code=$?
    fi

    if [[ -z "${ms}" || "${exit_code}" -ne 0 ]]; then
        echo "0.000"
        return
    fi
    echo "${ms}"
}

write_row() {
    local csv="$1" suite="$2" impl="$3" flags="$4" threads="$5" \
          size="$6" rep="$7" ms="$8"
    printf '%s,%s,"%s",%s,%s,%s,%s\n' \
        "${suite}" "${impl}" "${flags}" "${threads}" \
        "${size}" "${rep}" "${ms}" >> "${csv}"
    sync
}

# ---------------------------------------------------------------------------
# BENCHMARK LOOP (generic)
# ---------------------------------------------------------------------------
# Accepts an array of entries: "impl|flags|threads"
# impl    : seq_std | seq_cache | threads | conc
# flags   : compiler flags
# threads : number of threads (0 = sequential/process)

run_entries() {
    local suite="$1"
    local csv="${RESULTS_DIR}/data_${suite}.csv"
    shift
    local entries=("$@")

    for entry in "${entries[@]}"; do
        local impl flags threads
        impl=$(echo    "${entry}" | cut -d'|' -f1)
        flags=$(echo   "${entry}" | cut -d'|' -f2)
        threads=$(echo "${entry}" | cut -d'|' -f3)

        local bin tag
        bin="$(bin_path "${impl}" "${flags}")"
        tag="$(flag_tag "${flags}")"

        local label="${impl}/${tag}"
        [[ "${threads}" -gt 0 ]] && label="${impl}_${threads}t/${tag}"

        log_section "Measuring: ${label}"

        for rep in $(seq 1 "${REPETITIONS}"); do
            for size in "${MATRIX_SIZES[@]}"; do
                if [[ "$(already_done "${csv}" "${suite}" "${impl}" \
                        "${threads}" "${size}" "${rep}")" -gt 0 ]]; then
                    log_info "  [SKIP] ${label} size=${size} rep=${rep}"
                    continue
                fi

                printf "  rep=%-2s  size=%-6s  " "${rep}" "${size}"
                local ms
                ms=$(run_single "${bin}" "${size}" "${threads}")
                printf "%s ms\n" "${ms}"

                write_row "${csv}" "${suite}" "${impl}" "${flags}" \
                          "${threads}" "${size}" "${rep}" "${ms}"
            done
        done
    done
}

run_suite_compiler() {
    local csv="${RESULTS_DIR}/data_compiler.csv"
    setup_csv "${RESULTS_DIR}" "${csv}" "${CSV_HEADER}"

    local entries=()
    entries+=("seq_std|${BEST_FLAGS}|0")
    for t in "${ALL_THREAD_COUNTS[@]}"; do
        entries+=("threads|${NOOPT_FLAGS}|${t}")
    done
    entries+=("conc|${NOOPT_FLAGS}|0")

    run_entries "compiler" "${entries[@]}"
    print_suite_summary "compiler" "${csv}" "seq_std" "${BEST_FLAGS}" 0
}

run_suite_cache() {
    local csv="${RESULTS_DIR}/data_cache.csv"
    setup_csv "${RESULTS_DIR}" "${csv}" "${CSV_HEADER}"

    local entries=(
        "seq_cache|${NOOPT_FLAGS}|0"
    )
    run_entries "cache" "${entries[@]}"
    print_suite_summary "cache" "${csv}" "seq_std" "${NOOPT_FLAGS}" 0
}

run_suite_mixed() {
    local csv="${RESULTS_DIR}/data_mixed.csv"
    setup_csv "${RESULTS_DIR}" "${csv}" "${CSV_HEADER}"

    local entries=()
    entries+=("seq_cache|${BEST_FLAGS}|0")
    for t in "${ALL_THREAD_COUNTS[@]}"; do
        entries+=("threads|${BEST_FLAGS}|${t}")
    done
    entries+=("conc|${BEST_FLAGS}|0")

    run_entries "mixed" "${entries[@]}"
    print_suite_summary "mixed" "${csv}" "seq_cache" "${BEST_FLAGS}" 0
}

print_suite_summary() {
    local suite="$1"
    local csv="$2"
    local ref_impl="$3"
    local ref_flags="$4"
    local ref_threads="$5"

    local summary="${RESULTS_DIR}/summary_${suite}.txt"
    local tmpfile="${RESULTS_DIR}/.avgs_${suite}.tmp"

    # Compute averages per (impl, flags, threads, size)
    awk -F',' '
    NR==1 { next }
    {
        # strip quotes from flags field
        gsub(/^"|"$/, "", $3)
        key = $2 SUBSEP $3 SUBSEP $4 SUBSEP $5
        sum[key] += $7
        cnt[key]++
    }
    END {
        for (k in sum)  {
            split(k, a, SUBSEP)
            printf "%s|%s|%s|%s|%.3f\n", a[1], a[2], a[3], a[4], sum[k]/cnt[k]
        }
    }' "${csv}" | sort > "${tmpfile}"

    # Get reference averages per size
    declare -A REF_AVG
    while IFS='|' read -r impl flags threads size avg; do
        if [[ "${impl}" == "${ref_impl}" && \
              "${threads}" == "${ref_threads}" ]]; then
            REF_AVG["${size}"]="${avg}"
        fi
    done < "${tmpfile}"

    {
        echo ""
        echo "Suite     : ${suite}"
        echo "Date      : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host      : $(hostname)"
        echo "GCC       : $(gcc --version | head -1)"
        echo "Sizes     : ${MATRIX_SIZES[*]}"
        echo "Reps      : ${REPETITIONS}"
        echo "Reference : ${ref_impl} (threads=${ref_threads})"
        echo ""
        echo "Average wall time (ms)"
        echo "======================================================================="
        printf "%-26s" "Impl/Threads/Tag"
        for size in "${MATRIX_SIZES[@]}"; do
            printf "  %9s" "N=${size}"
        done
        printf "  %10s\n" "Avg Speedup"
        printf "%-26s" "--------------------------"
        for size in "${MATRIX_SIZES[@]}"; do
            printf "  %9s" "---------"
        done
        printf "  %10s\n" "----------"

        while IFS='|' read -r impl flags threads size avg; do
            : # aggregate pass — handled in the display loop below
        done < /dev/null

        declare -A ROW_SUM ROW_CNT ROW_KEY_ORDER
        while IFS='|' read -r impl flags threads size avg; do
            local tag
            tag="$(flag_tag "${flags}")"
            local row_key="${impl}|${threads}|${tag}"
            ROW_SUM["${row_key}:${size}"]="${avg}"
            ROW_KEY_ORDER["${row_key}"]="${row_key}"
        done < "${tmpfile}"

        # Print in consistent order: seq first, then threads ascending, then conc
        local ordered_keys=()
        for k in "${!ROW_KEY_ORDER[@]}"; do
            ordered_keys+=("${k}")
        done
        IFS=$'\n' ordered_keys=($(printf '%s\n' "${ordered_keys[@]}" \
            | sort -t'|' -k1,1 -k2,2n))
        unset IFS

        for row_key in "${ordered_keys[@]}"; do
            IFS='|' read -r impl threads tag <<< "${row_key}"
            local label="${impl}"
            [[ "${threads}" -gt 0 ]] && label="${impl}_${threads}t"
            label="${label}/${tag}"

            printf "%-26s" "${label}"
            local sp_sum=0 sp_cnt=0

            for size in "${MATRIX_SIZES[@]}"; do
                local avg="${ROW_SUM[${row_key}:${size}]:-}"
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
        echo "Speedup = T(reference) / T(row)  (>1 means row is faster than reference)"

    } | tee "${summary}"

    rm -f "${tmpfile}"
    log_ok "Summary : ${summary}"
    log_ok "Raw data: ${csv}"
}

print_banner() {
    local suite="$1"
    echo -e "${BOLD}"
    echo "============================================================"
    echo "   Final HPC Benchmark  --  Suite: ${suite}"
    echo "   Sizes       : ${MATRIX_SIZES[*]}"
    echo "   Repetitions : ${REPETITIONS}"
    echo "   Bench CPUs  : ${BENCH_CPUS}"
    echo "   Best flags  : ${BEST_FLAGS}"
    echo "   Date        : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo -e "${RESET}"
}

SUITE="${1:-all}"

run_suite() {
    local suite="$1"
    print_banner "${suite}"
    compile_suite_binaries "${suite}"
    case "${suite}" in
        compiler) run_suite_compiler ;;
        cache)    run_suite_cache    ;;
        mixed)    run_suite_mixed    ;;
    esac
}

main() {
    mkdir -p "${RESULTS_DIR}" "${BIN_DIR}"
    trap restore_system EXIT
    optimize_system

    case "${SUITE}" in
        compiler|cache|mixed)
            run_suite "${SUITE}"
            ;;
        all)
            for s in compiler cache mixed; do
                run_suite "${s}"
                echo ""
            done
            ;;
        *)
            log_error "Unknown suite: '${SUITE}'"
            log_error "Options: compiler | cache | mixed | all"
            exit 1
            ;;
    esac
}

main