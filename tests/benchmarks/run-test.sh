#!/usr/bin/env bash
# =============================================================================
# bench_final.sh  --  Final benchmark with CLI options
#
# Features:
#   --suite|-s        compiler|cache|mixed|all
#   --compiler|-c     gcc|clang|... or full compiler command
#   --impl|-i         Comma-separated implementations to run:
#                     seq_std,seq_cache,threads,conc
#   --flags|-f        best|noopt|both
#   --reps|-r         Number of repetitions
#   --sizes|-n        Comma-separated matrix sizes
#   --threads|-t      Comma-separated thread counts for threaded runs
#   --cpu-single      CPU core for sequential/process runs
#   --cpu-set         CPU set for threaded runs
#   --no-optimize     Skip optimize_system / restore_system hooks
#   --help            Show usage
#
# Examples:
#   ./bench_final.sh --suite compiler --compiler gcc --flags best
#   ./bench_final.sh --suite mixed --impl seq_cache,threads --flags both
#   ./bench_final.sh -s all -c clang -i threads,conc -f noopt -r 5
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

cd "$(dirname "$0")/../.."

# shellcheck source=tests/benchmarks/bench_utils.sh
source "tests/benchmarks/bench_utils.sh"

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
BIN_DIR="bin"
MACHINE_NAME="machine1"
RESULTS_DIR="tests/benchmarks/${MACHINE_NAME}/results_final"

SUITE="all"
COMPILER_CMD="gcc"
RUN_IMPLS_CSV=""
RUN_FLAGS_MODE="suite"   # suite|best|noopt|both
REPETITIONS=10
MATRIX_SIZES_CSV="400,800,1600,3200,6400"
THREAD_COUNTS_CSV="2,4,6,8,12"
BENCH_CPUS="0,1,2,3,4,5,6,7,8,9,10,11"
BENCH_CPU_SINGLE="0"
SKIP_OPTIMIZE=0
FORCE_REBUILD=0
MACHINE_NAME="machine1"

# Best compiler config from bench_opt results
BEST_FLAGS="-O3 -Wall -march=native -funroll-loops -flto -ffast-math -fomit-frame-pointer"
NOOPT_FLAGS="-Wall"

# CSV columns: suite,impl,flags,threads,matrix_size,repetition,wall_time_ms
CSV_HEADER="suite,impl,flags,threads,matrix_size,repetition,wall_time_ms"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage:
  ./bench_final.sh [options]

Options:
  -s, --suite <compiler|cache|mixed|all>
  -c, --compiler <compiler command>
  -i, --impl <list>
  -f, --flags <suite|best|noopt|both>
  -r, --reps <n>
  -n, --sizes <csv>
  -t, --threads <csv>
      --cpu-single <core>
      --cpu-set <cpuset>
      --no-optimize
      --force-rebuild
      --machine <machine-name>
      --machine <name>
  -h, --help

Implementation list values:
  seq_std, seq_cache, threads, conc

Examples:
  ./bench_final.sh --suite compiler --compiler gcc
  ./bench_final.sh --suite mixed --impl seq_cache,threads --flags both
  ./bench_final.sh -s all -c clang -r 5 -n 400,800,1600
EOF
}

trim_csv() {
    local s="$1"
    s="${s#,}"
    s="${s%,}"
    echo "${s}"
}

csv_to_array() {
    local csv="$1"
    local -n out_arr=$2
    IFS=',' read -r -a out_arr <<< "$(trim_csv "${csv}")"
}

contains_item() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

flag_tag() {
    local flags="$1"
    if [[ "${flags}" == "${BEST_FLAGS}" ]]; then
        echo "best"
    else
        echo "noopt"
    fi
}

normalize_compiler_cmd() {
    local cmd="$1"
    if [[ -z "${cmd}" ]]; then
        echo "gcc"
        return
    fi
    echo "${cmd}"
}

compiler_name() {
    local cmd="$1"
    local first
    first="${cmd%% *}"
    basename "${first}"
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

declare -A MAKE_TARGET=(
    [seq_std]="bin/mul_seq"
    [seq_cache]="bin/mul_seq_cache"
    [threads]="bin/mul_threads"
    [conc]="bin/mul_conc"
)

# -----------------------------------------------------------------------------
# Parse CLI
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--suite)
            SUITE="${2:-}"
            shift 2
            ;;
        -c|--compiler)
            COMPILER_CMD="${2:-}"
            shift 2
            ;;
        -i|--impl)
            RUN_IMPLS_CSV="${2:-}"
            shift 2
            ;;
        -f|--flags)
            RUN_FLAGS_MODE="${2:-}"
            shift 2
            ;;
        -r|--reps)
            REPETITIONS="${2:-}"
            shift 2
            ;;
        -n|--sizes)
            MATRIX_SIZES_CSV="${2:-}"
            shift 2
            ;;
        -t|--threads)
            THREAD_COUNTS_CSV="${2:-}"
            shift 2
            ;;
        --cpu-single)
            BENCH_CPU_SINGLE="${2:-}"
            shift 2
            ;;
        --cpu-set)
            BENCH_CPUS="${2:-}"
            shift 2
            ;;
        --no-optimize)
            SKIP_OPTIMIZE=1
            shift
            ;;
        --force-rebuild)
            FORCE_REBUILD=1
            shift
            ;;
        --machine)
            MACHINE_NAME="${2:-}"
            RESULTS_DIR="tests/benchmarks/${MACHINE_NAME}/results_final"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! [[ "${REPETITIONS}" =~ ^[0-9]+$ ]] || [[ "${REPETITIONS}" -le 0 ]]; then
    echo "Invalid repetitions: ${REPETITIONS}" >&2
    exit 1
fi

# Arrays from CSV inputs
MATRIX_SIZES=()
ALL_THREAD_COUNTS=()
csv_to_array "${MATRIX_SIZES_CSV}" MATRIX_SIZES
csv_to_array "${THREAD_COUNTS_CSV}" ALL_THREAD_COUNTS

if [[ ${#MATRIX_SIZES[@]} -eq 0 ]]; then
    echo "No matrix sizes configured" >&2
    exit 1
fi

if [[ ${#ALL_THREAD_COUNTS[@]} -eq 0 ]]; then
    echo "No thread counts configured" >&2
    exit 1
fi

# Compiler integration
COMPILER_NAME="$(compiler_name "${COMPILER_CMD}")"
MAKE=(make CC="${COMPILER_CMD}" COMPILER="${COMPILER_CMD}")

# -----------------------------------------------------------------------------
# Compilation
# -----------------------------------------------------------------------------
compile_binary() {
    local src_key="$1"
    local flags="$2"
    local bin
    bin="$(bin_path "${src_key}" "${flags}")"

    if [[ ${FORCE_REBUILD} -eq 0 && -x "${bin}" ]]; then
        log_info "Already compiled: ${bin}"
        return 0
    fi

    local src="${SRC_FILE[${src_key}]}"
    local make_target="${MAKE_TARGET[${src_key}]}"

    if [[ ! -f "${src}" ]]; then
        log_error "Source not found: ${src}"
        return 1
    fi

    local flags_clean
    flags_clean="$(echo "${flags}" | tr -s ' ' | xargs)"

    log_info "Compiling [${src_key}/$(flag_tag "${flags}")] using ${COMPILER_CMD}: make -B ${make_target}"

    if "${MAKE[@]}" -B "${make_target}" OPT_FLAGS="${flags_clean}" >/dev/null 2>&1; then
        mv -f "${make_target}" "${bin}"
        log_ok "Binary: ${bin}"
    else
        log_error "Compilation failed: ${src_key}/$(flag_tag "${flags}")"
        return 1
    fi
}

compile_suite_binaries() {
    local suite="$1"
    log_section "Compiling binaries for suite: ${suite}"
    mkdir -p "${BIN_DIR}"

    local impls=()
    local flags_mode="${RUN_FLAGS_MODE}"

    case "${suite}" in
        compiler)
            [[ -z "${RUN_IMPLS_CSV}" ]] && impls=(seq_std threads conc) || csv_to_array "${RUN_IMPLS_CSV}" impls
            [[ "${flags_mode}" == "suite" ]] && flags_mode="both"
            ;;
        cache)
            [[ -z "${RUN_IMPLS_CSV}" ]] && impls=(seq_cache) || csv_to_array "${RUN_IMPLS_CSV}" impls
            [[ "${flags_mode}" == "suite" ]] && flags_mode="both"
            ;;
        mixed)
            [[ -z "${RUN_IMPLS_CSV}" ]] && impls=(seq_cache threads conc) || csv_to_array "${RUN_IMPLS_CSV}" impls
            [[ "${flags_mode}" == "suite" ]] && flags_mode="both"
            ;;
        *)
            log_error "Unknown suite: ${suite}"
            exit 1
            ;;
    esac

    local flags_list=()
    case "${flags_mode}" in
        best) flags_list=("${BEST_FLAGS}") ;;
        noopt) flags_list=("${NOOPT_FLAGS}") ;;
        both) flags_list=("${BEST_FLAGS}" "${NOOPT_FLAGS}") ;;
        suite)
            # suite default: preserve original behavior
            if [[ "${suite}" == "compiler" ]]; then
                flags_list=("${BEST_FLAGS}" "${NOOPT_FLAGS}")
            elif [[ "${suite}" == "cache" ]]; then
                flags_list=("${NOOPT_FLAGS}")
            else
                flags_list=("${BEST_FLAGS}")
            fi
            ;;
        *)
            log_error "Invalid flags mode: ${flags_mode}"
            exit 1
            ;;
    esac

    local impl flags
    for impl in "${impls[@]}"; do
        for flags in "${flags_list[@]}"; do
            compile_binary "${impl}" "${flags}"
        done
    done
}

# -----------------------------------------------------------------------------
# Benchmark helpers
# -----------------------------------------------------------------------------
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

run_entries() {
    local suite="$1"
    local csv="${RESULTS_DIR}/data_${suite}.csv"
    shift
    local entries=("$@")

    local entry
    for entry in "${entries[@]}"; do
        local impl flags threads
        IFS='|' read -r impl flags threads <<< "${entry}"

        local bin tag label
        bin="$(bin_path "${impl}" "${flags}")"
        tag="$(flag_tag "${flags}")"

        label="${impl}/${tag}"
        [[ "${threads}" -gt 0 ]] && label="${impl}_${threads}t/${tag}"

        log_section "Measuring: ${label}"

        for rep in $(seq 1 "${REPETITIONS}"); do
            for size in "${MATRIX_SIZES[@]}"; do
                if [[ "$(already_done "${csv}" "${suite}" "${impl}" \
                        "${threads}" "${size}" "${rep}")" -gt 0 ]]; then
                    log_info "  [SKIP] ${label} size=${size} rep=${rep}"
                    continue
                fi

                printf '  rep=%-2s  size=%-6s  ' "${rep}" "${size}"
                local ms
                ms=$(run_single "${bin}" "${size}" "${threads}")
                printf '%s ms\n' "${ms}"

                write_row "${csv}" "${suite}" "${impl}" "${flags}" \
                          "${threads}" "${size}" "${rep}" "${ms}"
            done
        done
    done
}

print_suite_summary() {
    local suite="$1"
    local csv="$2"
    local ref_impl="$3"
    local ref_flags="$4"
    local ref_threads="$5"

    local summary="${RESULTS_DIR}/summary_${suite}.txt"
    local tmpfile="${RESULTS_DIR}/.avgs_${suite}.tmp"

    awk -F',' '
    NR==1 { next }
    {
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

    declare -A REF_AVG
    while IFS='|' read -r impl flags threads size avg; do
        if [[ "${impl}" == "${ref_impl}" && "${threads}" == "${ref_threads}" && "${flags}" == "${ref_flags}" ]]; then
            REF_AVG["${size}"]="${avg}"
        fi
    done < "${tmpfile}"

    {
        echo ""
        echo "Suite     : ${suite}"
        echo "Date      : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host      : $(hostname)"
        echo "Compiler  : ${COMPILER_CMD}"
        echo "GCC/Clang : $(${COMPILER_CMD%% *} --version 2>/dev/null | head -1 || true)"
        echo "Sizes     : ${MATRIX_SIZES[*]}"
        echo "Reps      : ${REPETITIONS}"
        echo "Reference : ${ref_impl} (${ref_flags}, threads=${ref_threads})"
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

        declare -A ROW_SUM ROW_KEY_ORDER
        while IFS='|' read -r impl flags threads size avg; do
            local tag row_key
            tag="$(flag_tag "${flags}")"
            row_key="${impl}|${threads}|${tag}"
            ROW_SUM["${row_key}:${size}"]="${avg}"
            ROW_KEY_ORDER["${row_key}"]=1
        done < "${tmpfile}"

        local ordered_keys=()
        for k in "${!ROW_KEY_ORDER[@]}"; do
            ordered_keys+=("${k}")
        done
        IFS=$'\n' ordered_keys=($(printf '%s\n' "${ordered_keys[@]}" | sort -t'|' -k1,1 -k2,2n))
        unset IFS

        local row_key
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
    echo "   Compiler    : ${COMPILER_CMD}"
    echo "   Sizes       : ${MATRIX_SIZES[*]}"
    echo "   Repetitions : ${REPETITIONS}"
    echo "   Bench CPUs  : ${BENCH_CPUS}"
    echo "   Single CPU  : ${BENCH_CPU_SINGLE}"
    echo "   Flags mode   : ${RUN_FLAGS_MODE}"
    echo "   Impl filter  : ${RUN_IMPLS_CSV:-suite-default}"
    echo "   Date        : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo -e "${RESET}"
}

# -----------------------------------------------------------------------------
# Suites
# -----------------------------------------------------------------------------
selected_impls_for_suite() {
    local suite="$1"
    local -n out_impls=$2

    if [[ -n "${RUN_IMPLS_CSV}" ]]; then
        csv_to_array "${RUN_IMPLS_CSV}" out_impls
        return
    fi

    case "${suite}" in
        compiler) out_impls=(seq_std threads conc) ;;
        cache)    out_impls=(seq_cache) ;;
        mixed)    out_impls=(seq_cache threads conc) ;;
        *)        out_impls=() ;;
    esac
}

selected_flags_for_suite() {
    local suite="$1"
    local -n out_flags=$2

    case "${RUN_FLAGS_MODE}" in
        best) out_flags=("${BEST_FLAGS}") ;;
        noopt) out_flags=("${NOOPT_FLAGS}") ;;
        both) out_flags=("${BEST_FLAGS}" "${NOOPT_FLAGS}") ;;
        suite)
            case "${suite}" in
                compiler) out_flags=("${BEST_FLAGS}" "${NOOPT_FLAGS}") ;;
                cache)    out_flags=("${NOOPT_FLAGS}") ;;
                mixed)    out_flags=("${BEST_FLAGS}") ;;
            esac
            ;;
        *)
            log_error "Invalid flags mode: ${RUN_FLAGS_MODE}"
            exit 1
            ;;
    esac
}

run_suite_compiler() {
    local csv="${RESULTS_DIR}/data_compiler.csv"
    setup_csv "${RESULTS_DIR}" "${csv}" "${CSV_HEADER}"

    local impls flags entries=()
    selected_impls_for_suite "compiler" impls
    selected_flags_for_suite "compiler" flags

    local impl flag t
    for impl in "${impls[@]}"; do
        case "${impl}" in
            seq_std)
                for flag in "${flags[@]}"; do
                    entries+=("seq_std|${flag}|0")
                done
                ;;
            threads)
                for flag in "${flags[@]}"; do
                    for t in "${ALL_THREAD_COUNTS[@]}"; do
                        entries+=("threads|${flag}|${t}")
                    done
                done
                ;;
            conc)
                for flag in "${flags[@]}"; do
                    entries+=("conc|${flag}|0")
                done
                ;;
        esac
    done

    run_entries "compiler" "${entries[@]}"
    print_suite_summary "compiler" "${csv}" "seq_std" "${BEST_FLAGS}" 0
}

run_suite_cache() {
    local csv="${RESULTS_DIR}/data_cache.csv"
    setup_csv "${RESULTS_DIR}" "${csv}" "${CSV_HEADER}"

    local impls flags entries=()
    selected_impls_for_suite "cache" impls
    selected_flags_for_suite "cache" flags

    local impl flag
    for impl in "${impls[@]}"; do
        case "${impl}" in
            seq_cache)
                for flag in "${flags[@]}"; do
                    entries+=("seq_cache|${flag}|0")
                done
                ;;
        esac
    done

    run_entries "cache" "${entries[@]}"
    print_suite_summary "cache" "${csv}" "seq_cache" "${NOOPT_FLAGS}" 0
}

run_suite_mixed() {
    local csv="${RESULTS_DIR}/data_mixed.csv"
    setup_csv "${RESULTS_DIR}" "${csv}" "${CSV_HEADER}"

    local impls flags entries=()
    selected_impls_for_suite "mixed" impls
    selected_flags_for_suite "mixed" flags

    local impl flag t
    for impl in "${impls[@]}"; do
        case "${impl}" in
            seq_cache)
                for flag in "${flags[@]}"; do
                    entries+=("seq_cache|${flag}|0")
                done
                ;;
            threads)
                for flag in "${flags[@]}"; do
                    for t in "${ALL_THREAD_COUNTS[@]}"; do
                        entries+=("threads|${flag}|${t}")
                    done
                done
                ;;
            conc)
                for flag in "${flags[@]}"; do
                    entries+=("conc|${flag}|0")
                done
                ;;
        esac
    done

    run_entries "mixed" "${entries[@]}"
    print_suite_summary "mixed" "${csv}" "seq_cache" "${BEST_FLAGS}" 0
}

run_suite() {
    local suite="$1"
    print_banner "${suite}"
    compile_suite_binaries "${suite}"

    case "${suite}" in
        compiler) run_suite_compiler ;;
        cache)    run_suite_cache ;;
        mixed)    run_suite_mixed ;;
    esac
}

main() {
    mkdir -p "${RESULTS_DIR}" "${BIN_DIR}"

    if [[ ${SKIP_OPTIMIZE} -eq 0 ]]; then
        trap restore_system EXIT
        optimize_system
    fi

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
