#!/usr/bin/env bash
# =============================================================================
# bench_geekbench.sh -- Geekbench 6 benchmark runner
#
# Descarga Geekbench 6 si no está disponible, ejecuta el benchmark,
# exporta los resultados en JSON y genera un resumen en texto.
#
# Usage:
#   ./bench_geekbench.sh [machine_label]
#   machine_label : nombre de esta máquina (ej: "machine1", "laptop")
#                   Por defecto usa el hostname.
#
# Output:
#   results_geekbench/<label>/geekbench_result.json
#   results_geekbench/<label>/geekbench_summary.txt
#   results_geekbench/<label>/machine_info.txt
#
# Requires: wget/curl, tar, python3
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

cd "$(dirname "$0")/../.."

source "tests/benchmarks/bench_utils.sh"


LABEL="${1:-$(echo "${HOSTNAME}" | cut -d. -f1 | sed 's/[^a-zA-Z0-9_]//g')}"
RESULTS_DIR="tests/benchmarks/results_geekbench/${LABEL}"
GB_DIR="tools/geekbench"
GB_VERSION="6.4.0"
GB_TARBALL="Geekbench-${GB_VERSION}-Linux.tar.gz"
GB_URL="https://cdn.geekbench.com/${GB_TARBALL}"
GB_BIN="${GB_DIR}/Geekbench-${GB_VERSION}-Linux/geekbench6"


install_geekbench() {
    if [[ -x "${GB_BIN}" ]]; then
        log_info "Geekbench ${GB_VERSION} already installed: ${GB_BIN}"
        return
    fi

    log_section "Installing Geekbench ${GB_VERSION}"
    mkdir -p "${GB_DIR}"

    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "${GB_DIR}/${GB_TARBALL}" "${GB_URL}"
    elif command -v curl &>/dev/null; then
        curl -L --progress-bar -o "${GB_DIR}/${GB_TARBALL}" "${GB_URL}"
    else
        log_error "Neither wget nor curl found. Install one and retry."
        exit 1
    fi

    tar -xzf "${GB_DIR}/${GB_TARBALL}" -C "${GB_DIR}"
    rm -f "${GB_DIR}/${GB_TARBALL}"

    if [[ ! -x "${GB_BIN}" ]]; then
        log_error "Geekbench binary not found after extraction: ${GB_BIN}"
        exit 1
    fi

    log_ok "Geekbench installed: ${GB_BIN}"
}


collect_machine_info() {
    local out="${RESULTS_DIR}/machine_info.txt"
    log_section "Collecting machine info"

    {
        echo "=== Machine: ${LABEL} ==="
        echo "Date       : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Hostname   : ${HOSTNAME:-$(cat /etc/hostname 2>/dev/null || echo 'unknown')}"
        echo "OS         : $(uname -srm)"
        echo ""

        echo "--- CPU ---"
        grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs || echo "N/A"
        echo "Logical cores : $(nproc)"
        echo "Physical cores: $(grep -c "^core id" /proc/cpuinfo 2>/dev/null || echo N/A)"
        lscpu | grep -E "^(Architecture|CPU MHz|CPU max MHz|L1d cache|L1i cache|L2 cache|L3 cache|NUMA)" || true

        echo ""
        echo "--- Memory ---"
        free -h

        echo ""
        echo "--- GCC ---"
        gcc --version | head -1

        echo ""
        echo "--- Kernel ---"
        uname -a

    } | tee "${out}"

    log_ok "Machine info saved: ${out}"
}


run_geekbench() {
    log_section "Running Geekbench ${GB_VERSION}"
    log_info "This may take 3-5 minutes..."

    local summary_out="${RESULTS_DIR}/geekbench_summary.txt"
    local json_out="${RESULTS_DIR}/geekbench_result.json"

    # Correr sin flags especiales (versión free)
    "${GB_BIN}" --cpu 2>&1 | tee "${summary_out}" \
        || log_warn "Geekbench exited with non-zero"

    # Extraer URL del resultado
    local result_url
    result_url=$(grep -oP 'https://browser\.geekbench\.com/v6/cpu/\d+(?!/claim)' "${summary_out}" | head -1)

    if [[ -n "${result_url}" ]]; then
        log_info "Result URL: ${result_url}"
        echo "${result_url}" > "${RESULTS_DIR}/result_url.txt"
    else
        log_warn "No se encontró URL de resultado. Revisa: ${summary_out}"
    fi

    # Extraer scores desde el stdout y guardar como JSON local
    python3 - "${summary_out}" "${json_out}" << 'EOF'
import re, json, sys

text = open(sys.argv[1]).read()

def extract_score(label):
    m = re.search(rf'{label}\s+(\d+)', text)
    return int(m.group(1)) if m else None

single = extract_score("Single-Core Score")
multi  = extract_score("Multi-Core Score")

workloads = []
# Parsear líneas de workloads del output de texto
for line in text.splitlines():
    m = re.match(r'\s{2}(\S.+?)\s{2,}(\d+)', line)
    if m:
        workloads.append({"name": m.group(1).strip(), "score": int(m.group(2))})

result = {
    "score": single,
    "multicore_score": multi,
    "workloads": workloads
}

with open(sys.argv[2], "w") as f:
    json.dump(result, f, indent=2)

print(f"  Single-Core Score : {single}")
print(f"  Multi-Core  Score : {multi}")
EOF

    [[ -s "${json_out}" ]] || { log_error "JSON no generado."; exit 1; }
}

print_summary() {
    local json="${RESULTS_DIR}/geekbench_result.json"
    [[ -f "${json}" ]] || return

    log_section "Results for: ${LABEL}"
    python3 -c "
import json, sys
d = json.load(open('${json}'))
print(f\"  Single-Core Score : {d.get('score', 'N/A')}\")
print(f\"  Multi-Core  Score : {d.get('multicore_score', 'N/A')}\")
"
}


print_banner() {
    echo -e "${BOLD}"
    echo "============================================================"
    echo " Geekbench ${GB_VERSION} Benchmark"
    echo " Machine    : ${LABEL}"
    echo " Output dir : ${RESULTS_DIR}"
    echo " Date       : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
    echo -e "${RESET}"
}

main() {
    print_banner
    mkdir -p "${RESULTS_DIR}"

    install_geekbench
    collect_machine_info
    run_geekbench
    print_summary

    log_ok "Done. Copy ${RESULTS_DIR}/ to the other machine's results folder"
    log_ok "Then run: python3 tests/benchmarks/report_geekbench.py"
}

main