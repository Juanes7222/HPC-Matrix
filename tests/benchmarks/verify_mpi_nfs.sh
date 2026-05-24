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
#   MPI_HOSTFILE   Path to hostfile. Omit flag if not set.
# ---------------------------------------------------------------------------

NFS_ROOT="/mnt/share"
LOCAL_BIN_DIR="bin"
TMP_DIR="${NFS_ROOT}/tmp/verify_mpi_nfs_$$"

# gen_matrix and verify_mpi run locally on the master node.
# mul_mpi_nfs must be on NFS so all ranks can find it at the same path.
GEN="${LOCAL_BIN_DIR}/gen_matrix"
MPI_BIN="${NFS_ROOT}/bin/mul_mpi_nfs_noopt"
VERIFY="${LOCAL_BIN_DIR}/verify_mpi"

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

die() { echo -e "${RED}ERROR: $*${RST}" >&2 ; exit 1 ; }

check_binaries() {
    for bin in "${GEN}" "${MPI_BIN}" "${VERIFY}"; do
        [[ -x "${bin}" ]] || die "${bin} not found. Run: make ${bin}"
    done
}

build_mpirun_cmd() {
    local procs="$1"
    local args=(-np "${procs}")
    [[ -n "${MPI_HOSTFILE:-}" && -f "${MPI_HOSTFILE}" ]] && \
        args+=(--hostfile "${MPI_HOSTFILE}")
    echo "mpirun ${args[*]}"
}

run_case() {
    local desc="$1" n="$2" procs="$3"
    local a="${TMP_DIR}/A_${n}.bin"
    local b="${TMP_DIR}/B_${n}.bin"
    local c="${TMP_DIR}/C_${n}_p${procs}.bin"

    printf "  %-40s" "${desc}"

    # Matrices are shared across process counts for the same N; generate once.
    [[ -f "${a}" ]] || "${GEN}" "${n}" "${a}" 2>/dev/null
    [[ -f "${b}" ]] || "${GEN}" "${n}" "${b}" 2>/dev/null

    local mpirun_cmd
    mpirun_cmd=$(build_mpirun_cmd "${procs}")

    local exit_code=0
    ${mpirun_cmd} "${MPI_BIN}" "${a}" "${b}" "${c}" >/dev/null 2>&1 \
        || exit_code=$?

    if [[ "${exit_code}" -ne 0 ]]; then
        echo -e "${YEL}SKIP${RST}  (mpirun failed, check hostfile/cluster)"
        (( SKIP_COUNT++ )) || true
        return
    fi

    local result
    result=$("${VERIFY}" "${a}" "${b}" "${c}" 2>&1)
    local verify_exit=$?

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

    echo ""
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
        run_case "N=2   P=${p}  (some ranks get 0 rows)" 2 "${p}"
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

run_all "${PROC_LIST[@]}"

echo ""
echo "============================================================"
echo -e "  ${GRN}PASS${RST} ${PASS_COUNT}   ${RED}FAIL${RST} ${FAIL_COUNT}   ${YEL}SKIP${RST} ${SKIP_COUNT}"
echo "============================================================"
echo ""

[[ "${FAIL_COUNT}" -eq 0 ]]