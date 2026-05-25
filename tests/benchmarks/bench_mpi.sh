#!/usr/bin/env bash
set -euo pipefail
export LC_NUMERIC=C

cd "$(dirname "$0")/../.."
source "tests/benchmarks/bench_utils.sh"

# ---------------------------------------------------------------------------
# Usage: bench_mpi_nfs.sh [--best] <machine_flag> [process_count...]
#
# Environment variables (override defaults):
#   MPI_DATA_DIR   NFS path where matrix .bin files are stored/generated.
#                  Default: tests/benchmarks/<machine_flag>/data_mpi
#   MPI_HOSTFILE   Path to the mpirun hostfile.
#                  Default: ~/mpi_hostfile
#
# Examples:
#   ./bench_mpi_nfs.sh machine1
#   ./bench_mpi_nfs.sh --best machine1
#   ./bench_mpi_nfs.sh --best machine1 2 3 6
#
# Notes:
#   - The compiled binary must be reachable at the same path on all nodes.
#     Place it under the NFS-mounted share, or ensure a matching local copy.
#   - optimize_system (from bench_utils.sh) only affects the local node.
#     To set the CPU governor on all nodes, run it independently on each one
#     before launching this script.
# ---------------------------------------------------------------------------

ORIGINAL_ARGS=("$@")
BEST_CONFIG=false

while [[ $# -gt 0 && "$1" == --* ]]; do
    case "$1" in
        --best) BEST_CONFIG=true ; shift ;;
        *)      echo "Unknown flag: $1" >&2 ; exit 1 ;;
    esac
done

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 [--best] <machine_flag> [process_count...]" >&2
    exit 1
fi

MACHINE_FLAG="$1"
shift
EXPLICIT_PROCS=("$@")

NFS_ROOT="/srv/nfs/hpc-matrix"
LOCAL_BIN_DIR="bin"
NFS_BIN_DIR="${NFS_ROOT}/bin"
DATA_DIR="${MPI_DATA_DIR:-${NFS_ROOT}/data/input}"
RESULTS_DIR="${NFS_ROOT}/results/mpi_nfs/${MACHINE_FLAG}"
HOSTFILE="${MPI_HOSTFILE:-${HOME}/mpi_hostfile}"
MATRIX_SIZES=(400 800 1600 3200 6400)
REPETITIONS=10

NORMAL_FLAGS=""
BEST_FLAGS="-O3 -march=native -funroll-loops -flto -ffast-math -fomit-frame-pointer"

if [[ "${BEST_CONFIG}" == true ]]; then
    ACTIVE_FLAGS="${BEST_FLAGS}"
    LOCAL_BIN_MPI="${LOCAL_BIN_DIR}/mul_mpi_nfs_opt"
    NFS_BIN_MPI="${NFS_BIN_DIR}/mul_mpi_nfs_opt"
else
    ACTIVE_FLAGS="${NORMAL_FLAGS}"
    LOCAL_BIN_MPI="${LOCAL_BIN_DIR}/mul_mpi_nfs_noopt"
    NFS_BIN_MPI="${NFS_BIN_DIR}/mul_mpi_nfs_noopt"
fi

CSV_HEADER="machine,impl,flags,processes,matrix_size,repetition,io_ms,scatter_ms,compute_ms,gather_ms,total_ms"
SRC_MPI="src/mpi_nfs/mul_mpi_nfs.c"

# Derive default process sweep from hostfile slot count (1..total_slots).
# Falls back to 1..3 when the hostfile is absent or has no slots= annotations.
build_process_sweep() {
    local max_procs=3
    if [[ -f "${HOSTFILE}" ]]; then
        local slots_total
        slots_total=$(grep -oP 'slots=\K[0-9]+' "${HOSTFILE}" 2>/dev/null \
                      | awk '{s += $1} END {print s + 0}')
        [[ "${slots_total:-0}" -gt 0 ]] && max_procs="${slots_total}"
    fi

    local counts=()
    local p=1
    while [[ "${p}" -le "${max_procs}" ]]; do
        counts+=("${p}")
        (( p++ ))
    done
    mapfile -t ALL_PROC_COUNTS < <(printf '%s\n' "${counts[@]}" | sort -un)
}

if [[ "${#EXPLICIT_PROCS[@]}" -gt 0 ]]; then
    mapfile -t ALL_PROC_COUNTS < <(printf '%s\n' "${EXPLICIT_PROCS[@]}" | sort -un)
else
    build_process_sweep
fi

# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------

compile_mpi() {
    if [[ ! -f "${SRC_MPI}" ]]; then
        log_error "Source not found: ${SRC_MPI}"
        return 1
    fi

    if [[ -x "${NFS_BIN_MPI}" && "${NFS_BIN_MPI}" -nt "${SRC_MPI}" ]]; then
        log_info "Already up-to-date: ${NFS_BIN_MPI}"
        return 0
    fi

    local flags_clean
    flags_clean=$(echo "${ACTIVE_FLAGS}" | tr -s ' ' | xargs)
    log_info "Compiling ${LOCAL_BIN_MPI} via Makefile (flags: ${flags_clean:-none})"

    if make -B "${LOCAL_BIN_MPI}" OPT_FLAGS="${flags_clean}" >/dev/null 2>&1; then
        log_info "Deploying to ${NFS_BIN_DIR}/"
        cp "${LOCAL_BIN_MPI}" "${NFS_BIN_DIR}/"
        log_ok "Binary ready: ${NFS_BIN_MPI}"
    else
        log_error "Compilation failed: ${SRC_MPI}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Matrix data management
# ---------------------------------------------------------------------------

ensure_matrices() {
    local gen_bin="${LOCAL_BIN_DIR}/gen_matrix"

    if [[ ! -x "${gen_bin}" ]]; then
        log_info "Compiling gen_matrix..."
        if ! make -B "bin/gen_matrix" >/dev/null 2>&1; then
            log_error "Cannot compile gen_matrix"
            return 1
        fi
    fi

    mkdir -p "${DATA_DIR}"

    for size in "${MATRIX_SIZES[@]}"; do
        local a="${DATA_DIR}/A_${size}.bin"
        local b="${DATA_DIR}/B_${size}.bin"
        [[ ! -f "${a}" ]] && { log_info "Generating A_${size}.bin" ; "${gen_bin}" "${size}" "${a}" ; }
        [[ ! -f "${b}" ]] && { log_info "Generating B_${size}.bin" ; "${gen_bin}" "${size}" "${b}" ; }
    done

    log_ok "Matrices ready in ${DATA_DIR}"
}

# ---------------------------------------------------------------------------
# Measurement helpers
# ---------------------------------------------------------------------------

already_done() {
    local csv="$1" machine="$2" procs="$3" size="$4" rep="$5"
    awk -F',' \
        -v ma="${machine}" -v fl="${ACTIVE_FLAGS}" -v pr="${procs}" \
        -v si="${size}"    -v re="${rep}" \
        'NR > 1 {
            gsub(/"/, "", $3)
            if ($1 == ma && $3 == fl && $4 == pr && $5 == si && $6 == re)
                found = 1
        }
        END { print found + 0 }' \
        "${csv}" 2>/dev/null
}

# Sets global IO_MS SCATTER_MS COMPUTE_MS GATHER_MS TOTAL_MS from one output line.
parse_mpi_output() {
    local line="$1"
    IO_MS=$(     echo "${line}" | grep -oP 'io=\K[0-9.]+')
    SCATTER_MS=$(echo "${line}" | grep -oP 'scatter=\K[0-9.]+')
    COMPUTE_MS=$(echo "${line}" | grep -oP 'compute=\K[0-9.]+')
    GATHER_MS=$( echo "${line}" | grep -oP 'gather=\K[0-9.]+')
    TOTAL_MS=$(  echo "${line}" | grep -oP 'total=\K[0-9.]+')
}

zero_phases() {
    IO_MS="0.000"; SCATTER_MS="0.000"
    COMPUTE_MS="0.000"; GATHER_MS="0.000"; TOTAL_MS="0.000"
}

# mpirun without chrt: MPI's own process placement handles CPU affinity
# across nodes. taskset/chrt would only pin the launcher process, not the
# remote ranks, so it is intentionally omitted here.
run_single() {
    local bin="$1" size="$2" procs="$3"
    local a="${DATA_DIR}/A_${size}.bin"
    local b="${DATA_DIR}/B_${size}.bin"
    local c="${NFS_ROOT}/tmp/C_${size}_p${procs}.bin"
    local output exit_code=0

    local mpirun_args=(-np "${procs}")
    [[ -f "${HOSTFILE}" ]] && mpirun_args+=(--hostfile "${HOSTFILE}")

    output=$(mpirun "${mpirun_args[@]}" "${bin}" "${a}" "${b}" "${c}" 2>&1) || exit_code=$?
    if [[ -z "${output}" || "${exit_code}" -ne 0 ]]; then
        echo "${output}" | tail -20
        zero_phases
        return
    fi

    parse_mpi_output "${output}"
}

write_row() {
    local csv="$1" machine="$2" procs="$3" size="$4" rep="$5"
    printf '%s,mul_mpi_nfs,"%s",%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${machine}" "${ACTIVE_FLAGS}" "${procs}" "${size}" "${rep}" \
        "${IO_MS}" "${SCATTER_MS}" "${COMPUTE_MS}" "${GATHER_MS}" "${TOTAL_MS}" \
        >> "${csv}"
    sync
}

# ---------------------------------------------------------------------------
# Benchmark loop
# ---------------------------------------------------------------------------

run_benchmark() {
    local csv="${RESULTS_DIR}/data_mpi_nfs.csv"
    setup_csv "${RESULTS_DIR}" "${csv}" "${CSV_HEADER}"

    for procs in "${ALL_PROC_COUNTS[@]}"; do
        log_section "Measuring: mul_mpi_nfs  procs=${procs}  machine=${MACHINE_FLAG}"
        for rep in $(seq 1 "${REPETITIONS}"); do
            for size in "${MATRIX_SIZES[@]}"; do
                if [[ "$(already_done "${csv}" "${MACHINE_FLAG}" \
                        "${procs}" "${size}" "${rep}")" -gt 0 ]]; then
                    log_info "  [SKIP] procs=${procs} size=${size} rep=${rep}"
                    continue
                fi

                printf "  rep=%-2s  size=%-6s  procs=%-3s  " \
                    "${rep}" "${size}" "${procs}"
                run_single "${NFS_BIN_MPI}" "${size}" "${procs}"
                printf "compute=%-10s total=%s ms\n" \
                    "${COMPUTE_MS}" "${TOTAL_MS}"
                write_row "${csv}" "${MACHINE_FLAG}" "${procs}" "${size}" "${rep}"
            done
        done
    done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
    local csv="${RESULTS_DIR}/data_mpi_nfs.csv"
    local summary="${RESULTS_DIR}/summary_mpi_nfs.txt"
    local tmpfile="${RESULTS_DIR}/.avgs_mpi_nfs.tmp"

    # CSV columns: $1=machine $2=impl $3=flags $4=processes $5=matrix_size
    #              $6=rep $7=io_ms $8=scatter_ms $9=compute_ms $10=gather_ms $11=total_ms
    awk -F',' '
    NR == 1 { next }
    {
        key = $4 SUBSEP $5
        compute_sum[key] += $9
        total_sum[key]   += $11
        cnt[key]++
    }
    END {
        for (k in compute_sum) {
            split(k, a, SUBSEP)
            printf "%s|%s|%.3f|%.3f\n",
                a[1], a[2],
                compute_sum[k] / cnt[k],
                total_sum[k]   / cnt[k]
        }
    }' "${csv}" | sort -t'|' -k1,1n -k2,2n > "${tmpfile}"

    local ref_procs=1
    declare -A REF_COMPUTE
    while IFS='|' read -r procs size compute _total; do
        [[ "${procs}" == "${ref_procs}" ]] && REF_COMPUTE["${size}"]="${compute}"
    done < "${tmpfile}"

    declare -A ROW_COMPUTE ROW_TOTAL
    while IFS='|' read -r procs size compute total; do
        ROW_COMPUTE["${procs}:${size}"]="${compute}"
        ROW_TOTAL["${procs}:${size}"]="${total}"
    done < "${tmpfile}"

    {
        echo ""
        echo "Machine      : ${MACHINE_FLAG}"
        echo "Date         : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Host         : $(hostname)"
        echo "Processes    : ${ALL_PROC_COUNTS[*]}"
        echo "Hostfile     : ${HOSTFILE}"
        echo "Data dir     : ${DATA_DIR}"
        echo "GCC          : $(gcc --version | head -1)"
        echo "Sizes        : ${MATRIX_SIZES[*]}"
        echo "Reps         : ${REPETITIONS}"
        echo "Reference    : ${ref_procs} process"

        echo ""
        echo "Average compute time (ms) — kernel only, excludes I/O and communication"
        echo "======================================================================="
        printf "%-12s" "Procs"
        for size in "${MATRIX_SIZES[@]}"; do printf "  %9s" "N=${size}"; done
        printf "  %10s\n" "Avg Speedup"

        printf "%-12s" "------------"
        for size in "${MATRIX_SIZES[@]}"; do printf "  %9s" "---------"; done
        printf "  %10s\n" "----------"

        for procs in "${ALL_PROC_COUNTS[@]}"; do
            printf "%-12s" "${procs}p"
            local sp_sum=0 sp_cnt=0
            for size in "${MATRIX_SIZES[@]}"; do
                local avg="${ROW_COMPUTE[${procs}:${size}]:-}"
                if [[ -z "${avg}" ]]; then printf "  %9s" "N/A"; continue; fi
                printf "  %9.1f" "${avg}"
                local ref="${REF_COMPUTE[${size}]:-}"
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
        echo "Average total time (ms) — I/O + scatter + compute + gather"
        echo "======================================================================="
        printf "%-12s" "Procs"
        for size in "${MATRIX_SIZES[@]}"; do printf "  %9s" "N=${size}"; done
        printf "\n"

        printf "%-12s" "------------"
        for size in "${MATRIX_SIZES[@]}"; do printf "  %9s" "---------"; done
        printf "\n"

        for procs in "${ALL_PROC_COUNTS[@]}"; do
            printf "%-12s" "${procs}p"
            for size in "${MATRIX_SIZES[@]}"; do
                local avg="${ROW_TOTAL[${procs}:${size}]:-}"
                if [[ -z "${avg}" ]]; then printf "  %9s" "N/A"; continue; fi
                printf "  %9.1f" "${avg}"
            done
            printf "\n"
        done

        echo ""
        echo "Speedup = compute(1p) / compute(row)  (>1 means faster than 1 process)"

        local has_baseline=0
        for p in "${ALL_PROC_COUNTS[@]}"; do
            [[ "${p}" -eq 1 ]] && has_baseline=1 && break
        done
        if [[ "${has_baseline}" -eq 0 ]]; then
            echo ""
            echo "NOTE: 1-process baseline not in this run. Speedup requires a prior"
            echo "      full sweep or an explicit run with process_count=1."
        fi
    } | tee "${summary}"

    rm -f "${tmpfile}"
    log_ok "Summary : ${summary}"
    log_ok "Raw data: ${csv}"
}

# ---------------------------------------------------------------------------
# Banner and entry point
# ---------------------------------------------------------------------------

print_banner() {
    echo -e "${BOLD}"
    echo "============================================================"
    echo "   MPI+NFS Matrix Multiplication Benchmark"
    echo "   Machine      : ${MACHINE_FLAG}"
    echo "   Processes    : ${ALL_PROC_COUNTS[*]}"
    echo "   Sizes        : ${MATRIX_SIZES[*]}"
    echo "   Repetitions  : ${REPETITIONS}"
    echo "   Flags        : ${ACTIVE_FLAGS:-none}"
    echo "   Hostfile     : ${HOSTFILE}"
    echo "   Data dir     : ${DATA_DIR}"
    echo "   Date         : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo -e "${RESET}"
}

main() {
    mkdir -p "${RESULTS_DIR}" "${LOCAL_BIN_DIR}" "${NFS_BIN_DIR}" "${NFS_ROOT}/tmp"

    ensure_matrices
    optimize_system
    print_banner
    compile_mpi
    run_benchmark
    print_summary
}

if [[ -z "${INHIBITED:-}" ]]; then
    export INHIBITED=1
    if command -v systemd-inhibit >/dev/null 2>&1; then
        systemd-inhibit \
            --what=idle:sleep \
            --who="bench_mpi_nfs" \
            --why="MPI+NFS benchmark running" \
            --mode=block \
            bash "$0" "${ORIGINAL_ARGS[@]}" || main
    else
        main
    fi
else
    main
fi
