#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

# ---------------------------------------------------------------------------
# verify_mpi_nfs.sh
#
# Checks correctness of mul_mpi_nfs against the sequential reference.
# Covers four categories of cases:
#   1. P=1          — single-process baseline
#   2. N divisible  — uniform row distribution across ranks
#   3. N remainder  — irregular distribution (some ranks get one extra row)
#   4. N < P        — more processes than rows (some ranks get zero rows)
#
# Usage: ./verify_mpi_nfs.sh [process_count...]
#   Default process counts: 1 2 3
#
# Environment variables:
#   MPI_HOSTFILE   Path to hostfile (default: ~/mpi_hostfile if it exists).
# ---------------------------------------------------------------------------

NFS_ROOT="/srv/nfs/share/hpc-matrix"

# gen_matrix and verify_mpi run on the master; mul_mpi_nfs runs via mpirun.
# All three binaries live on NFS so every node resolves the same path.
GEN="${NFS_ROOT}/bin/gen_matrix"
MPI_BIN="${NFS_ROOT}/bin/mul_mpi_nfs_noopt"
VERIFY="bin/verify_mpi"

TMP_DIR="${NFS_ROOT}/tmp/verify_mpi_nfs_$$"

RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[0;33m'
BOLD='\033[1m'
RST='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() { echo -e "${RED}ERROR: $*${RST}" >&2; exit 1; }

check_binaries() {
    for bin in "${GEN}" "${MPI_BIN}" "${VERIFY}"; do
        [[ -x "${bin}" ]] || die "${bin} not found or not executable"
    done
}

# Fills the MPI_ARGS array for the given process count.
# Avoids the fragility of building and word-splitting a command string.
build_mpi_args() {
    local procs="$1"
    MPI_ARGS=(-np "${procs}")

    local hostfile="${MPI_HOSTFILE:-${HOME}/mpi_hostfile}"
    [[ -f "${hostfile}" ]] && MPI_ARGS+=(--hostfile "${hostfile}")
}

# Runs a command via mpirun and captures its stderr into MPI_STDERR.
# Sets MPI_EXIT to the exit code.
run_mpi() {
    local err_file
    err_file=$(mktemp)

    MPI_EXIT=0
    mpirun "${MPI_ARGS[@]}" "$@" >/dev/null 2>"${err_file}" || MPI_EXIT=$?

    MPI_STDERR=$(cat "${err_file}")
    rm -f "${err_file}"
}

preflight_check() {
    echo -e "${BOLD}Pre-flight checks${RST}"

    # NFS tmp must be writable
    local probe="${NFS_ROOT}/tmp/.preflight_$$"
    if ! touch "${probe}" 2>/dev/null; then
        echo -e "  ${RED}[FAIL]${RST} Cannot write to ${NFS_ROOT}/tmp/"
        echo "  Fix: sudo chown \$(whoami) ${NFS_ROOT}/tmp"
        die "NFS tmp not writable"
    fi
    rm -f "${probe}"
    echo -e "  ${GRN}[OK]${RST} NFS tmp writable"

    # gen_matrix must produce a file on NFS
    local probe_mat="${NFS_ROOT}/tmp/.preflight_matrix_$$.bin"
    local gen_err
    gen_err=$(mktemp)
    if ! "${GEN}" 4 "${probe_mat}" 2>"${gen_err}"; then
        echo -e "  ${RED}[FAIL]${RST} gen_matrix cannot write to NFS:"
        sed 's/^/    /' "${gen_err}"
        rm -f "${gen_err}" "${probe_mat}"
        die "gen_matrix write failed"
    fi
    rm -f "${gen_err}" "${probe_mat}"
    echo -e "  ${GRN}[OK]${RST} gen_matrix writes to NFS"

    # mpirun must launch at least one process
    build_mpi_args 1
    run_mpi true
    if [[ "${MPI_EXIT}" -ne 0 ]]; then
        echo -e "  ${RED}[FAIL]${RST} mpirun -np 1 true:"
        echo "${MPI_STDERR}" | head -5 | sed 's/^/    /'
        echo ""
        echo "  Possible causes:"
        echo "    - mpirun not installed (apt install openmpi-bin)"
        echo "    - SSH keys not configured between nodes"
        echo "    - Set MPI_HOSTFILE env var to your hostfile path"
        die "MPI environment not functional"
    fi
    echo -e "  ${GRN}[OK]${RST} mpirun -np 1 true"
    echo ""
}

run_case() {
    local desc="$1" n="$2" procs="$3"
    local a="${TMP_DIR}/A_${n}.bin"
    local b="${TMP_DIR}/B_${n}.bin"
    local c="${TMP_DIR}/C_${n}_p${procs}.bin"

    printf "  %-42s" "${desc}"

    # Matrices for the same N are shared across process counts; generate once.
    local gen_err
    gen_err=$(mktemp)
    if [[ ! -f "${a}" ]]; then
        if ! "${GEN}" "${n}" "${a}" 2>"${gen_err}"; then
            echo -e "${YEL}SKIP${RST}  gen_matrix failed: $(head -1 "${gen_err}")"
            rm -f "${gen_err}"; (( SKIP_COUNT++ )) || true; return
        fi
    fi
    if [[ ! -f "${b}" ]]; then
        if ! "${GEN}" "${n}" "${b}" 2>"${gen_err}"; then
            echo -e "${YEL}SKIP${RST}  gen_matrix failed: $(head -1 "${gen_err}")"
            rm -f "${gen_err}"; (( SKIP_COUNT++ )) || true; return
        fi
    fi
    rm -f "${gen_err}"

    build_mpi_args "${procs}"
    run_mpi "${MPI_BIN}" "${a}" "${b}" "${c}"

    if [[ "${MPI_EXIT}" -ne 0 ]]; then
        local first_err
        first_err=$(echo "${MPI_STDERR}" | grep -v '^$' | grep -v '^-' | head -1)
        echo -e "${YEL}SKIP${RST}  ${first_err}"
        (( SKIP_COUNT++ )) || true
        return
    fi

    local result verify_exit=0
    result=$("${VERIFY}" "${a}" "${b}" "${c}" 2>&1) || verify_exit=$?

    if [[ "${verify_exit}" -eq 0 ]]; then
        echo -e "${GRN}${result}${RST}"
        (( PASS_COUNT++ )) || true
    else
        echo -e "${RED}${result}${RST}"
        (( FAIL_COUNT++ )) || true
    fi
}

# ---------------------------------------------------------------------------
# Test matrix
# ---------------------------------------------------------------------------

run_all() {
    local proc_list=("$@")

    echo -e "${BOLD}Category 1 — single process (P=1 baseline)${RST}"
    run_case "N=8   P=1" 8 1
    run_case "N=64  P=1" 64 1

    echo ""
    echo -e "${BOLD}Category 2 — N divisible by P (uniform distribution)${RST}"
    for p in "${proc_list[@]}"; do
        [[ "${p}" -le 1 ]] && continue
        run_case "N=12  P=${p}  (12%${p}=0)" 12 "${p}"
        run_case "N=64  P=${p}  (64%${p}=0)" 64 "${p}"
    done

    echo ""
    echo -e "${BOLD}Category 3 — N not divisible by P (irregular distribution)${RST}"
    for p in "${proc_list[@]}"; do
        [[ "${p}" -le 1 ]] && continue
        local rem=$(( 10 % p ))
        run_case "N=10  P=${p}  (10%${p}=${rem})" 10 "${p}"
        local rem2=$(( 7 % p ))
        run_case "N=7   P=${p}  (7%${p}=${rem2})" 7 "${p}"
    done

    echo ""
    echo -e "${BOLD}Category 4 — more processes than rows (N < P)${RST}"
    for p in "${proc_list[@]}"; do
        [[ "${p}" -le 2 ]] && continue
        run_case "N=2   P=${p}  (some ranks idle)" 2 "${p}"
        run_case "N=1   P=${p}  (only rank 0 works)" 1 "${p}"
    done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if [[ $# -gt 0 ]]; then
    PROC_LIST=("$@")
else
    PROC_LIST=(1 2 3)
fi

check_binaries
mkdir -p "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo -e "${BOLD}"
echo "============================================================"
echo "   MPI+NFS Correctness Verification"
echo "   Binary  : ${MPI_BIN}"
echo "   Procs   : ${PROC_LIST[*]}"
echo "   Date    : $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo -e "${RST}"

preflight_check
run_all "${PROC_LIST[@]}"

echo ""
echo "============================================================"
echo -e "  ${GRN}PASS${RST} ${PASS_COUNT}   ${RED}FAIL${RST} ${FAIL_COUNT}   ${YEL}SKIP${RST} ${SKIP_COUNT}"
echo "============================================================"
echo ""

[[ "${FAIL_COUNT}" -eq 0 ]]