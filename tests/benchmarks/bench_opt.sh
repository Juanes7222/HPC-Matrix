#!/usr/bin/env bash
# =============================================================================
# bench_opt.sh  --  Compiler optimization benchmark for sequential matrix mult
#
# Tests a set of GCC flag combinations across multiple matrix sizes and
# repetitions. Measures wall time (reported by the C program itself), writes
# all measurements to a CSV, and prints a ranked summary at the end.
#
# Correctness check: every configuration is compared against the -O0 reference
# output for N=64. If any result differs the configuration is flagged.
#
# Usage:
#   ./bench_opt.sh
#
# Output:
#   results_opt/data_opt.csv          raw measurements
#   results_opt/summary_opt.txt       ranked summary
#
# Requirements:
#   gcc, bc, taskset, chrt  (sudo without password for chrt/taskset)
#
# Passwordless sudo (add with: sudo visudo):
#   your_user ALL=(ALL) NOPASSWD: /usr/bin/chrt, /usr/bin/taskset
# =============================================================================

set -euo pipefail

cd "$(dirname "$0")/../.."

SRC_FILES="src/sequential/mul_seq.c src/matrix_lib.c"
RESULTS_DIR="tests/benchmarks/machine1/results_opt"
CSV_FILE="${RESULTS_DIR}/data_opt.csv"
SUMMARY_FILE="${RESULTS_DIR}/summary_opt.txt"
BIN_DIR="bin"

# Matrix sizes to benchmark
MATRIX_SIZES=(200 400 800 1600)

# Repetitions per size per configuration
REPETITIONS=5

# CPU cores to pin to (adjust to your machine)
BENCH_CPUS="0,1,2,3,4,5,6,7,8,9,10,11"


# ---------------------------------------------------------------------------
# COMPILER CONFIGURATIONS
#
# Format: "label|flags"
# label  : short name used as identifier in the CSV and summary
# flags  : flags passed to gcc (do NOT include -o or source files here)
#
# Grouped by category:
#   1. Baseline optimization levels
#   2. Architecture-aware variants (march=native exploits AVX2/AVX-512 on
#      Ryzen 7600X, enabling auto-vectorization of the inner multiply loop)
#   3. Extra flags that affect specific optimizations
# ---------------------------------------------------------------------------

declare -a CONFIGS=(
    # ---- Baseline levels ------------------------------------------------
    "O0|           -O0 -Wall"
    "O1|           -O1 -Wall"
    "O2|           -O2 -Wall"
    "O3|           -O3 -Wall"
    "Ofast|        -Ofast -Wall"

    # ---- Native architecture (uses all SIMD extensions of your CPU) -----
    # -march=native enables AVX2 on Ryzen 7600X, which lets gcc vectorize
    # the innermost multiply-accumulate loop automatically.
    "O2_native|    -O2 -Wall -march=native"
    "O3_native|    -O3 -Wall -march=native"
    "Ofast_native| -Ofast -Wall -march=native"

    # ---- Loop unrolling --------------------------------------------------
    # -funroll-loops unrolls the inner j-loop, reducing branch overhead and
    # exposing more instruction-level parallelism to the CPU pipeline.
    "O3_unroll|    -O3 -Wall -march=native -funroll-loops"

    # ---- Link-Time Optimization ------------------------------------------
    # -flto lets the linker optimize across translation units (mul_seq.c and
    # matrix_lib.c together), enabling inlining of matrixMultiplyRange into
    # main and eliminating function call overhead.
    "O3_lto|       -O3 -Wall -march=native -flto"

    # ---- Full aggressive stack -------------------------------------------
    # Combines all of the above. -ffast-math allows reordering of floating
    # point ops (safe here since the core loop is integer arithmetic).
    # -fomit-frame-pointer frees one register for the compiler to use.
    "O3_full|      -O3 -Wall -march=native -funroll-loops -flto \
                   -ffast-math -fomit-frame-pointer"
)

# shellcheck source=tests/benchmarks/bench_utils.sh
source "tests/benchmarks/bench_utils.sh"

setup() {
    setup_csv "${RESULTS_DIR}" "${CSV_FILE}" \
        "config,flags,matrix_size,repetition,wall_time_ms,correct"
}

compile_config() {
    local label="$1"
    local flags="$2"
    local bin="${BIN_DIR}/mul_seq_${label}"

    local flags_clean
    flags_clean=$(echo "${flags}" | tr -s ' ' | xargs)

    local cmd="gcc ${flags_clean} -o ${bin} ${SRC_FILES}"
    log_info "Compiling [${label}]: ${cmd}"

    if eval "${cmd}" 2>/dev/null; then
        log_ok "Binary: ${bin}"
        echo "${bin}"
        return 0
    else
        log_error "Compilation failed for [${label}]"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# CORRECTNESS CHECK
#
# Compiles verify_mul.c with the same flags as each benchmark configuration
# and runs it. verify_mul.c multiplies two 4x4 matrices with hardcoded values
# and compares against the mathematically correct result, returning exit 0 on
# success and exit 1 on failure.
#
# This proves that the compiler optimizations did not alter the behavior of
# matrixMultiply, not just that all configs agree with each other.
# ---------------------------------------------------------------------------

compile_verifier() {
    local label="$1"
    local flags="$2"
    local bin="${BIN_DIR}/verify_mul_${label}"
    local flags_clean
    flags_clean=$(echo "${flags}" | tr -s ' ' | xargs)

    if gcc ${flags_clean} -o "${bin}" tests/correctness/verify_mul.c src/matrix_lib.c 2>/dev/null; then
        echo "${bin}"
    else
        echo ""
    fi
}

check_correctness() {
    local label="$1"
    local flags="$2"
    local verifier="${BIN_DIR}/verify_mul_${label}"

    if [[ ! -x "${verifier}" ]]; then
        verifier=$(compile_verifier "${label}" "${flags}")
        if [[ -z "${verifier}" ]]; then
            log_warn "Could not compile verifier for [${label}]."
            echo "N/A"
            return
        fi
    fi

    # Run without chrt/taskset: correctness does not require real-time priority
    if "${verifier}" > /dev/null 2>&1; then
        echo "1"
    else
        echo "0"
    fi
}

run_single() {
    local bin="$1"
    local size="$2"
    local exit_code=0
    local elapsed_ms

    elapsed_ms=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
        "${bin}" "${size}" 2>/dev/null) || exit_code=$?

    if [[ -z "${elapsed_ms}" || "${exit_code}" -ne 0 ]]; then
        echo "0.000"
        return
    fi
    echo "${elapsed_ms}"
}

write_row() {
    local config="$1" flags="$2" size="$3" rep="$4" ms="$5" correct="$6"
    # Wrap flags in quotes to keep CSV valid despite spaces
    printf '"%s","%s",%s,%s,%s,%s\n' \
        "${config}" "${flags}" "${size}" "${rep}" "${ms}" "${correct}" \
        >> "${CSV_FILE}"
    sync
}

already_done() {
    local config="$1" size="$2" rep="$3"
    awk -F',' -v c="\"${config}\"" -v s="${size}" -v r="${rep}" \
        'NR>1 && $1==c && $3==s && $4==r { count++ }
         END { print count+0 }' \
        "${CSV_FILE}" 2>/dev/null
}

run_benchmark() {
    local total_configs=${#CONFIGS[@]}
    local config_idx=0

    for entry in "${CONFIGS[@]}"; do
        config_idx=$(( config_idx + 1 ))
        local label flags

        label=$(echo "${entry}" | cut -d'|' -f1 | tr -d ' ')
        flags=$(echo "${entry}"  | cut -d'|' -f2 | tr -s ' ' | xargs)

        echo ""
        echo "============================================================"
        log_section "Config ${config_idx}/${total_configs}: ${label}"
        log_info "Flags: ${flags}"

        local bin="${BIN_DIR}/mul_seq_${label}"

        if [[ ! -x "${bin}" ]]; then
            compile_config "${label}" "${flags}" > /dev/null || continue
        else
            log_info "Binary already exists, skipping compilation."
        fi

        local correct
        correct=$(check_correctness "${label}" "${flags}")
        if [[ "${correct}" == "1" ]]; then
            log_ok "Correctness: PASS"
        elif [[ "${correct}" == "0" ]]; then
            log_warn "Correctness: FAIL (compiler altered matrixMultiply behavior)"
        else
            log_warn "Correctness: N/A (verifier could not be built)"
        fi

        for rep in $(seq 1 "${REPETITIONS}"); do
            for size in "${MATRIX_SIZES[@]}"; do
                local done_count
                done_count=$(already_done "${label}" "${size}" "${rep}")
                if (( done_count > 0 )); then
                    log_info "  [SKIP] size=${size} rep=${rep} already saved."
                    continue
                fi

                printf "  Rep=%-2s  Size=%-6s  " "${rep}" "${size}"
                local ms
                ms=$(run_single "${bin}" "${size}")
                printf "%s ms\n" "${ms}"

                write_row "${label}" "${flags}" "${size}" "${rep}" "${ms}" "${correct}"
            done
        done
    done
}

print_summary() {
    log_section "Results summary"

    local tmpfile="${RESULTS_DIR}/.avgs.tmp"

    awk -F',' '
    NR==1 { next }
    {
        # Strip surrounding quotes from config and flags
        gsub(/^"|"$/, "", $1)
        key = $1 SUBSEP $3
        sum[key] += $5
        cnt[key]++
    }
    END {
        for (k in sum) {
            split(k, a, SUBSEP)
            printf "%s,%s,%.3f\n", a[1], a[2], sum[k]/cnt[k]
        }
    }' "${CSV_FILE}" | sort -t',' -k1,1 -k2,2n > "${tmpfile}"

    declare -A O0_AVG
    while IFS=',' read -r config size avg; do
        if [[ "${config}" == "O0" ]]; then
            O0_AVG["${size}"]="${avg}"
        fi
    done < "${tmpfile}"

    declare -A CONFIG_TOTAL CONFIG_COUNT
    for entry in "${CONFIGS[@]}"; do
        local label
        label=$(echo "${entry}" | cut -d'|' -f1 | tr -d ' ')
        CONFIG_TOTAL["${label}"]="0"
        CONFIG_COUNT["${label}"]="0"
    done

    {
        echo ""
        echo "Per-size average (ms)"
        echo "======================================================================="
        printf "%-18s" "Config"
        for size in "${MATRIX_SIZES[@]}"; do
            printf "  %8s" "${size}x${size}"
        done
        printf "  %10s\n" "Avg Speedup"
        printf "%-18s" "------------------"
        for size in "${MATRIX_SIZES[@]}"; do
            printf "  %8s" "--------"
        done
        printf "  %10s\n" "----------"

        while IFS= read -r config_entry; do
            local label flags
            label=$(echo "${config_entry}" | cut -d'|' -f1 | tr -d ' ')

            printf "%-18s" "${label}"
            local speedup_sum=0
            local speedup_cnt=0

            for size in "${MATRIX_SIZES[@]}"; do
                local avg
                avg=$(awk -F',' -v c="${label}" -v s="${size}" \
                    '$1==c && $2==s { print $3 }' "${tmpfile}")

                if [[ -z "${avg}" ]]; then
                    printf "  %8s" "N/A"
                    continue
                fi

                printf "  %8.1f" "${avg}"

                local ref="${O0_AVG[${size}]:-}"
                if [[ -n "${ref}" && "${avg}" != "0.000" ]]; then
                    local sp
                    sp=$(echo "scale=4; ${ref} / ${avg}" | bc 2>/dev/null || echo "0")
                    speedup_sum=$(echo "scale=4; ${speedup_sum} + ${sp}" | bc)
                    speedup_cnt=$(( speedup_cnt + 1 ))
                fi
            done

            if (( speedup_cnt > 0 )); then
                local avg_speedup
                avg_speedup=$(echo "scale=3; ${speedup_sum} / ${speedup_cnt}" | bc)
                printf "  %10sx\n" "${avg_speedup}"
                CONFIG_TOTAL["${label}"]="${avg_speedup}"
            else
                printf "  %10s\n" "N/A"
            fi

        done < <(printf '%s\n' "${CONFIGS[@]}")

        echo ""
        echo "Ranking by average speedup over O0"
        echo "======================================================================="
        printf "%-6s  %-18s  %10s  %s\n" "Rank" "Config" "Speedup" "Flags"
        printf "%-6s  %-18s  %10s  %s\n" "------" "------------------" \
            "----------" "-----"

        # Sort configs by speedup descending
        local rank=1
        for entry in "${CONFIGS[@]}"; do
            local label flags
            label=$(echo "${entry}" | cut -d'|' -f1 | tr -d ' ')
            flags=$(echo "${entry}"  | cut -d'|' -f2 | tr -s ' ' | xargs)
            echo "${CONFIG_TOTAL[${label}]} ${label} ${flags}"
        done \
        | sort -rn \
        | while read -r sp label flags; do
            printf "%-6s  %-18s  %10sx  %s\n" "#${rank}" "${label}" "${sp}" "${flags}"
            rank=$(( rank + 1 ))
        done

        echo ""
        echo "Notes:"
        echo "  Speedup = T_O0 / T_config  (>1 means faster than -O0)"
        echo "  Correctness verified against known 4x4 result (verify_mul.c)"
        echo "  Measurements: ${REPETITIONS} repetitions per size"
        echo "  CPU affinity: ${BENCH_CPUS}"
        echo "  Date: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Host: $(hostname)"
        echo "  GCC: $(gcc --version | head -1)"

    } | tee "${SUMMARY_FILE}"

    rm -f "${tmpfile}"
    echo ""
    log_ok "Summary saved to: ${SUMMARY_FILE}"
    log_ok "Raw data saved to: ${CSV_FILE}"
}

print_banner() {
    echo -e "${BOLD}"
    echo "============================================================"
    echo "   Compiler Optimization Benchmark  --  Sequential MatMul"
    echo "   Configurations : ${#CONFIGS[@]}"
    echo "   Sizes          : ${MATRIX_SIZES[*]}"
    echo "   Repetitions    : ${REPETITIONS} per size"
    echo "   Bench CPUs     : ${BENCH_CPUS}"
    echo "   Date           : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "   GCC            : $(gcc --version | head -1)"
    echo "============================================================"
    echo -e "${RESET}"
}

main() {
    print_banner
    trap restore_system EXIT
    optimize_system
    setup

    # Compile all configs first so failures are visible upfront
    log_section "Compiling all configurations"
    for entry in "${CONFIGS[@]}"; do
        local label flags
        label=$(echo "${entry}" | cut -d'|' -f1 | tr -d ' ')
        flags=$(echo "${entry}"  | cut -d'|' -f2 | tr -s ' ' | xargs)
        local bin="${BIN_DIR}/mul_seq_${label}"
        if [[ ! -x "${bin}" ]]; then
            compile_config "${label}" "${flags}" > /dev/null
        else
            log_info "[${label}] already compiled."
        fi
    done

    # Run benchmarks
    run_benchmark

    # Print and save summary
    print_summary
}

main