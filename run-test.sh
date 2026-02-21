#!/usr/bin/env bash
# =============================================================================
# Uso:
#   ./run_tests.sh [sequential|concurrent|threads] [num_threads]
#
#   Ejemplos:
#     ./run_tests.sh sequential
#     ./run_tests.sh threads 4
#     ./run_tests.sh threads 8
#     ./run_tests.sh concurrent
#
# Requisito sudo sin contraseña (agregar con: sudo visudo):
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
declare -A EXEC=(
    [sequential]="./mul_seq"
    [concurrent]="./mul_conc"
    [threads]="./mul_threads"
)
declare -A CFLAGS=(
    [sequential]="-O2 -Wall"
    [concurrent]="-O2 -Wall"
    [threads]="-O2 -Wall -lpthread"    # Agrega -fopenmp si usas OpenMP
)


BENCH_CPUS="1,2,3,4,5,6"

MATRIX_SIZES=(400 800 1600 3200 6400)

REPETITIONS=10

RESULTS_DIR="results"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_skip()    { echo -e "  ${YELLOW}[SKIP]${RESET}  $*"; }
log_section() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }


print_banner() {
    local label="${MODE}"
    [[ "${MODE}" == "threads" ]] && label="threads (${NUM_THREADS} hilos)"

    echo -e "${BOLD}"
    echo "============================================================"
    echo "   HPC Benchmark  --  Multiplicación de Matrices"
    echo "   Modo     : ${label}"
    echo "   Fecha    : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "   Host     : $(hostname)"
    echo "   CPU(s)   : $(nproc) núcleos disponibles"
    echo "   Bench CPUs: ${BENCH_CPUS}"
    echo "============================================================"
    echo -e "${RESET}"
}


validate_mode() {
    case "${MODE}" in
        sequential|concurrent|threads) ;;
        *)
            log_error "Modo desconocido: '${MODE}'. Opciones: sequential | concurrent | threads"
            exit 1
            ;;
    esac

    if [[ "${MODE}" == "threads" && -z "${NUM_THREADS}" ]]; then
        log_error "El modo 'threads' requiere el número de hilos como segundo argumento."
        log_error "Ejemplo: ./run_tests.sh threads 8"
        exit 1
    fi
}


optimize_system() {
    log_section "Optimizando sistema para benchmark"

    if sudo cpupower frequency-set -g performance > /dev/null 2>&1; then
        log_ok "Gobernador de CPU: performance"
    else
        log_warn "No se pudo cambiar el gobernador de CPU (¿cpupower instalado?)"
    fi

    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null
        log_ok "Turbo Boost Intel: desactivado"
    fi

    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost > /dev/null
        log_ok "Turbo Boost AMD: desactivado"
    fi

    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    log_ok "Caché de página: limpia"

    echo 0 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
    log_ok "ASLR: desactivado"
}


restore_system() {
    log_section "Restaurando sistema"

    if sudo cpupower frequency-set -g powersave > /dev/null 2>&1; then
        log_ok "Gobernador de CPU: powersave"
    fi

    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null
        log_ok "Turbo Boost Intel: restaurado"
    fi

    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost > /dev/null
        log_ok "Turbo Boost AMD: restaurado"
    fi

    echo 2 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
    log_ok "ASLR: restaurado"

    log_ok "Sistema restaurado correctamente."
}


compile_project() {
    log_section "Compilación"

    local src="${SRC[${MODE}]}"
    local out="${EXEC[${MODE}]}"
    local flags="${CFLAGS[${MODE}]}"
    local cmd="gcc ${flags} -o ${out} ${src} matrix_lib.c"

    if [[ ! -f "${src}" ]]; then
        log_error "Archivo fuente no encontrado: ${src}"
        exit 1
    fi

    log_info "Comando: ${cmd}"

    if eval "${cmd}"; then
        log_ok "Compilación exitosa: ${out}"
    else
        log_error "Compilación fallida. Revisa los errores anteriores."
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

setup_csv() {
    mkdir -p "${RESULTS_DIR}"
    REPORT_FILE="$(get_csv_path)"

    if [[ -f "${REPORT_FILE}" ]]; then
        local existing
        existing=$(( $(wc -l < "${REPORT_FILE}") - 1 ))
        log_warn "CSV existente detectado con ${existing} medición(es): ${REPORT_FILE}"
        log_warn "Las pruebas ya completadas se saltarán automáticamente."
    else
        # mode: sequential | concurrent | threads
        # threads: número de hilos (0 si no aplica)
        # matrix_size, repetition: identifican la prueba
        # wall_time_ms: tiempo medido por el programa en C
        # exit_code: para detectar fallos
        echo "mode,threads,matrix_size,repetition,wall_time_ms,exit_code" \
            > "${REPORT_FILE}"
        log_ok "CSV nuevo creado: ${REPORT_FILE}"
    fi
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

# ---------------------------------------------------------------------------
# EJECUCIÓN DE UNA PRUEBA INDIVIDUAL
#
# El tiempo lo imprime el propio programa en C (stdout) en milisegundos.
# chrt -f 99: prioridad de tiempo real FIFO (máxima)
# taskset -c:  fija el proceso a los núcleos definidos en BENCH_CPUS
# ---------------------------------------------------------------------------

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
        log_error "Ejecutable no encontrado o sin permisos de ejecución: ${exec_bin}"
        exit 1
    fi

    local label="${MODE}"
    [[ "${MODE}" == "threads" ]] && label="threads (${NUM_THREADS} hilos)"

    log_section "Pruebas  [${label}]"
    echo -e "${BOLD}Tamaños    : ${MATRIX_SIZES[*]}"
    echo -e "Repeticiones: ${REPETITIONS}"
    [[ "${MODE}" == "threads" ]] && echo -e "Hilos       : ${NUM_THREADS}"
    echo -e "${RESET}"

    local total_runs=$(( ${#MATRIX_SIZES[@]} * REPETITIONS ))
    local current_run=0
    local mode_label="${MODE}"
    [[ "${MODE}" == "threads" ]] && mode_label="threads"
    local threads="${NUM_THREADS:-0}"

    if [[ -f "${REPORT_FILE}" ]]; then
        current_run=$(awk -F',' -v m="${mode_label}" -v t="${threads}" \
            'NR>1 && $1==m && $2==t { count++ } END { print count+0 }' \
            "${REPORT_FILE}")
    fi

    for rep in $(seq 1 "${REPETITIONS}"); do
        echo "============================================================"
        log_info "Ronda ${rep} de ${REPETITIONS}"

        for size in "${MATRIX_SIZES[@]}"; do

            # Verificar si esta combinación exacta (tamaño + rep) ya fue guardada
            local already
            already=$(awk -F',' -v m="${mode_label}" -v t="${threads}" \
                -v s="${size}" -v r="${rep}" \
                'NR>1 && $1==m && $2==t && $3==s && $4==r { count++ }
                 END { print count+0 }' \
                "${REPORT_FILE}" 2>/dev/null)

            if (( already > 0 )); then
                log_skip "Tamaño=${size} Rep=${rep} ya guardado. Saltando."
                continue
            fi

            current_run=$(( current_run + 1 ))
            printf "  [%3d/%3d] Tamaño=%-6s Rep=%-3d " \
                "${current_run}" "${total_runs}" "${size}" "${rep}"

            read -r elapsed_ms exit_code <<< "$(run_single_test "${exec_bin}" "${size}")"

            write_measurement "${size}" "${rep}" "${elapsed_ms}" "${exit_code}"

            printf "%s ms\n" "${elapsed_ms}"

            if [[ "${exit_code}" -ne 0 ]]; then
                log_warn "Exit code ${exit_code} en tamaño=${size} rep=${rep}"
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
    log_section "Resumen de resultados"

    local mode_label="${MODE}"
    [[ "${MODE}" == "threads" ]] && mode_label="threads"
    local threads="${NUM_THREADS:-0}"

    echo -e "CSV guardado en: ${BOLD}${REPORT_FILE}${RESET}\n"

    printf "${BOLD}%-12s %-16s %-16s %-12s${RESET}\n" \
        "Tamaño" "Promedio (ms)" "Seq avg (ms)" "Speedup"
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
    log_ok "Benchmark finalizado: $(date '+%Y-%m-%d %H:%M:%S')"
}


main() {
    validate_mode
    print_banner

    trap restore_system EXIT

    optimize_system
    compile_project
    setup_csv
    run_benchmark
    print_summary
}

main