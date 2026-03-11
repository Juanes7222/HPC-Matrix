#!/usr/bin/env bash
# =============================================================================
# run_tests.sh  --  HPC Benchmark: Matrix Multiplication
#
# Usage:
#   ./run_tests.sh [sequential|concurrent|threads|all] [num_threads]
#
#   Examples:
#     ./run_tests.sh all                  # runs every configuration in order
#     ./run_tests.sh sequential
#     ./run_tests.sh threads 4
#     ./run_tests.sh threads 8
#     ./run_tests.sh concurrent
#
# Passwordless sudo required (add with: sudo visudo):
#   your_user ALL=(ALL) NOPASSWD: /usr/bin/cpupower, /usr/bin/tee, /usr/bin/chrt
# =============================================================================

set -euo pipefail

MODE="${1:-sequential}"
NUM_THREADS="${2:-}"

declare -A SRC=(
    [sequential]="mul_seq.c"
    [concurrent]="mul_conc.c"
    [threads]="mul_threads.c"
)

BIN_DIR="bin"

declare -A EXEC=(
    [sequential]="${BIN_DIR}/mul_seq"
    [concurrent]="${BIN_DIR}/mul_conc"
    [threads]="${BIN_DIR}/mul_threads"
)
declare -A CFLAGS=(
    [sequential]="-O2 -Wall"
    [concurrent]="-O2 -Wall"
    [threads]="-O2 -Wall -lpthread"    # Add -fopenmp if using OpenMP
)

# CPU cores dedicated to the benchmark.
# Use cores reserved with isolcpus at boot, or any cores you want to pin to.
BENCH_CPUS="0,1,2,3,4,5,6,7,8,9,10,11"

# Matrix sizes to test
MATRIX_SIZES=(400 800 1600 3200 6400)

# Repetitions per size
REPETITIONS=10

# Thread counts used when MODE=all
# Ryzen 5 7600X: 6 physical cores, 12 logical threads (SMT)
ALL_THREAD_COUNTS=(2 4 6 8 12)

RESULTS_DIR="results"

# shellcheck source=bench_utils.sh
source "$(dirname "$0")/bench_utils.sh"

log_skip() { echo -e "  ${YELLOW}[SKIP]${RESET}  $*"; }


print_banner() {
    local label="${MODE}"
    [[ "${MODE}" == "threads" ]] && label="threads (${NUM_THREADS} threads)"

    echo -e "${BOLD}"
    echo "============================================================"
    echo "   HPC Benchmark  --  Matrix Multiplication"
    echo "   Mode      : ${label}"
    echo "   Date      : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "   Host      : $(hostname)"
    echo "   CPU(s)    : $(nproc) available cores"
    echo "   Bench CPUs: ${BENCH_CPUS}"
    echo "============================================================"
    echo -e "${RESET}"
}

validate_mode() {
    case "${MODE}" in
        sequential|concurrent|threads|all) ;;
        *)
            log_error "Unknown mode: '${MODE}'."
            log_error "Options: sequential | concurrent | threads | all"
            exit 1
            ;;
    esac

    if [[ "${MODE}" == "threads" && -z "${NUM_THREADS}" ]]; then
        log_error "Mode 'threads' requires the number of threads as a second argument."
        log_error "Example: ./run_tests.sh threads 8"
        exit 1
    fi
}

run_all() {
    local script
    script="$(realpath "$0")"

    local configs=("sequential")
    for t in "${ALL_THREAD_COUNTS[@]}"; do
        configs+=("threads:${t}")
    done
    configs+=("concurrent")

    local total=${#configs[@]}
    local passed=0
    local failed=0
    local failed_list=()

    echo -e "${BOLD}"
    echo "############################################################"
    echo "   ALL MODE  --  Running ${total} configurations"
    echo "   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "############################################################"
    echo -e "${RESET}"

    for config in "${configs[@]}"; do
        local mode_arg threads_arg=""
        if [[ "${config}" == *":"* ]]; then
            mode_arg="${config%%:*}"
            threads_arg="${config##*:}"
        else
            mode_arg="${config}"
        fi

        echo -e "\n${BOLD}${CYAN}>>> Starting: ${config}${RESET}"

        if bash "${script}" ${mode_arg} ${threads_arg}; then
            passed=$(( passed + 1 ))
            log_ok "Finished: ${config}"
        else
            failed=$(( failed + 1 ))
            failed_list+=("${config}")
            log_warn "Configuration failed: ${config}. Continuing with next."
        fi
    done

    echo -e "\n${BOLD}"
    echo "############################################################"
    echo "   ALL MODE COMPLETE"
    echo "   Passed : ${passed}/${total}"
    echo "   Failed : ${failed}/${total}"
    if (( failed > 0 )); then
        echo "   Failed configs: ${failed_list[*]}"
    fi
    echo "   $(date '+%Y-%m-%d %H:%M:%S')"
    echo "############################################################"
    echo -e "${RESET}"

    (( failed == 0 ))
}

compile_project() {
    log_section "Compilation"

    mkdir -p "${BIN_DIR}"

    local src="${SRC[${MODE}]}"
    local out="${EXEC[${MODE}]}"
    local flags="${CFLAGS[${MODE}]}"
    local cmd="gcc ${flags} -o ${out} ${src} matrix_lib.c"

    if [[ ! -f "${src}" ]]; then
        log_error "Source file not found: ${src}"
        exit 1
    fi

    log_info "Command: ${cmd}"

    if eval "${cmd}"; then
        log_ok "Compilation successful: ${out}"
    else
        log_error "Compilation failed. Check the errors above."
        exit 1
    fi
}

get_csv_path() {
    local label="${MODE}"
    [[ "${MODE}" == "threads" ]] && label="threads_${NUM_THREADS}t"
    echo "${RESULTS_DIR}/data_${label}.csv"
}

get_sequential_csv() {
    echo "${RESULTS_DIR}/data_sequential.csv"
}

init_report_csv() {
    REPORT_FILE="$(get_csv_path)"
    setup_csv "${RESULTS_DIR}" "${REPORT_FILE}" \
        "mode,threads,matrix_size,repetition,wall_time_ms,exit_code"
}

write_measurement() {
    local size="$1" rep="$2" elapsed_ms="$3" exit_code="$4"
    local mode_label="${MODE}"
    [[ "${MODE}" == "threads" ]] && mode_label="threads"
    local threads="${NUM_THREADS:-0}"

    printf "%s,%s,%s,%s,%s,%s\n" \
        "${mode_label}" "${threads}" "${size}" "${rep}" \
        "${elapsed_ms}" "${exit_code}" \
        >> "${REPORT_FILE}"

    sync
}

run_single_test() {
    local exec_bin="$1"
    local size="$2"
    local exit_code=0
    local elapsed_ms

    if [[ "${MODE}" == "threads" ]]; then
        elapsed_ms=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
            "${exec_bin}" "${size}" "${NUM_THREADS}" 2>/dev/null) || exit_code=$?
    else
        elapsed_ms=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
            "${exec_bin}" "${size}" 2>/dev/null) || exit_code=$?
    fi

    if [[ -z "${elapsed_ms}" ]]; then
        elapsed_ms="0.000"
        exit_code=1
    fi

    echo "${elapsed_ms} ${exit_code}"
}

run_benchmark() {
    local exec_bin="${EXEC[${MODE}]}"

    if [[ ! -x "${exec_bin}" ]]; then
        log_error "Executable not found or not executable: ${exec_bin}"
        exit 1
    fi

    local label="${MODE}"
    [[ "${MODE}" == "threads" ]] && label="threads (${NUM_THREADS} threads)"

    log_section "Tests  [${label}]"
    echo -e "${BOLD}Sizes       : ${MATRIX_SIZES[*]}"
    echo -e "Repetitions : ${REPETITIONS}"
    [[ "${MODE}" == "threads" ]] && echo -e "Threads     : ${NUM_THREADS}"
    echo -e "${RESET}"

    local total_runs=$(( ${#MATRIX_SIZES[@]} * REPETITIONS ))
    local current_run=0
    local mode_label="${MODE}"
    [[ "${MODE}" == "threads" ]] && mode_label="threads"
    local threads="${NUM_THREADS:-0}"

    # Initialize counter with already saved measurements
    if [[ -f "${REPORT_FILE}" ]]; then
        current_run=$(awk -F',' -v m="${mode_label}" -v t="${threads}" \
            'NR>1 && $1==m && $2==t { count++ } END { print count+0 }' \
            "${REPORT_FILE}")
    fi

    for rep in $(seq 1 "${REPETITIONS}"); do
        echo "============================================================"
        log_info "Round ${rep} of ${REPETITIONS}"

        for size in "${MATRIX_SIZES[@]}"; do

            local already
            already=$(awk -F',' -v m="${mode_label}" -v t="${threads}" \
                -v s="${size}" -v r="${rep}" \
                'NR>1 && $1==m && $2==t && $3==s && $4==r { count++ }
                 END { print count+0 }' \
                "${REPORT_FILE}" 2>/dev/null)

            if (( already > 0 )); then
                log_skip "Size=${size} Rep=${rep} already saved. Skipping."
                continue
            fi

            current_run=$(( current_run + 1 ))
            printf "  [%3d/%3d] Size=%-6s Rep=%-3d " \
                "${current_run}" "${total_runs}" "${size}" "${rep}"

            read -r elapsed_ms exit_code <<< "$(run_single_test "${exec_bin}" "${size}")"

            write_measurement "${size}" "${rep}" "${elapsed_ms}" "${exit_code}"

            printf "%s ms\n" "${elapsed_ms}"

            if [[ "${exit_code}" -ne 0 ]]; then
                log_warn "Exit code ${exit_code} at size=${size} rep=${rep}"
            fi
        done
    done
}

get_sequential_avg() {
    local size="$1"
    local seq_csv
    seq_csv="$(get_sequential_csv)"

    if [[ ! -f "${seq_csv}" ]]; then
        echo "N/A"
        return
    fi

    awk -F',' -v s="${size}" \
        'NR>1 && $1=="sequential" && $3==s { sum+=$5; count++ }
         END { if (count>0) printf "%.3f", sum/count; else print "N/A" }' \
        "${seq_csv}"
}

print_summary() {
    log_section "Results summary"

    local mode_label="${MODE}"
    [[ "${MODE}" == "threads" ]] && mode_label="threads"
    local threads="${NUM_THREADS:-0}"

    echo -e "CSV saved at: ${BOLD}${REPORT_FILE}${RESET}\n"

    printf "${BOLD}%-12s %-16s %-16s %-12s${RESET}\n" \
        "Size" "Average (ms)" "Seq avg (ms)" "Speedup"
    printf "%-12s %-16s %-16s %-12s\n" \
        "----------" "--------------" "--------------" "----------"

    for size in "${MATRIX_SIZES[@]}"; do
        local avg seq_avg speedup

        avg=$(awk -F',' -v s="${size}" -v m="${mode_label}" -v t="${threads}" \
            'NR>1 && $1==m && $2==t && $3==s { sum+=$5; count++ }
             END { if (count>0) printf "%.3f", sum/count; else print "N/A" }' \
            "${REPORT_FILE}")

        seq_avg=$(get_sequential_avg "${size}")

        if [[ "${MODE}" == "sequential" ]]; then
            speedup="1.000 (base)"
        elif [[ "${avg}" == "N/A" || "${seq_avg}" == "N/A" ]]; then
            speedup="N/A"
        else
            speedup=$(echo "scale=4; ${seq_avg} / ${avg}" | bc 2>/dev/null || echo "N/A")
        fi

        printf "%-12s %-16s %-16s %-12s\n" \
            "${size}x${size}" "${avg}" "${seq_avg}" "${speedup}"
    done

    echo ""
    log_ok "Benchmark finished: $(date '+%Y-%m-%d %H:%M:%S')"
}

main() {
    validate_mode

    if [[ "${MODE}" == "all" ]]; then
        run_all
        return
    fi

    print_banner

    trap restore_system EXIT

    optimize_system
    compile_project
    init_report_csv
    run_benchmark
    print_summary
}

main