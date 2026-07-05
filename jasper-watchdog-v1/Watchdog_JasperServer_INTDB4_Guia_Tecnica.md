# Watchdog de JasperServer - Informe técnico y guía operativa

**Servicio:** JasperServer INTDB4  
**Host:** `inst-k5vj9-jasperserver-intdb4-poo`  
**Versión documentada:** 2026-07-05

## Resumen

Se implementó un watchdog local que valida cada 15 segundos el reporte funcional `/reports/MONITOR`. El reporte debe responder HTTP 200, contener la palabra `MONITOR` y responder dentro de 4 segundos.

Ante una falla confirmada, el watchdog captura evidencia técnica, reinicia primero Tomcat y usa un reinicio completo de JasperServer sólo como fallback. No reinicia automáticamente la VM.

## Hallazgos

- La VM permanecía accesible aunque Jasper dejaba de devolver reportes.
- En un incidente, Tomcat registró: `A valid shutdown command was received via the shutdown port.`
- El puerto 8005 estaba ligado a localhost, por lo que el shutdown provino de la propia VM.
- El cron `/home/opc/script/limpiar_tomcat.sh` de las 13:00 quedó como principal sospechoso y debe mantenerse deshabilitado hasta revisión.
- El cron anterior del watchdog cada minuto debe permanecer deshabilitado: la supervisión actual se realiza mediante systemd.

## Política

| Situación | Política |
|---|---|
| Falla dura | Confirmar a los 5 s; capturar evidencia; reiniciar Tomcat |
| Falla lógica/lenta | Dos fallas consecutivas; capturar evidencia; reiniciar Tomcat |
| Tomcat no recupera | Fallback a reinicio completo de JasperServer |
| 3 reinicios en 15 min | Bloquear nuevas recuperaciones automáticas y requerir intervención humana |

## Operación

```bash
systemctl status jasper-watchdog.service
journalctl -u jasper-watchdog.service -f
tail -f /var/log/jasper-watchdog.log
ls -lht /var/lib/jasper-watchdog/incidents/ | head
```

## Mantenimiento manual

```bash
systemctl stop jasper-watchdog.service
cd /tmp
# mantenimiento manual
systemctl start jasper-watchdog.service
```

## Unidad systemd

```ini
[Unit]
Description=JasperServer watchdog and fast recovery
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/tmp
ExecStart=/usr/local/sbin/jasper-watchdog.sh run
Restart=on-failure
RestartSec=5
KillMode=process
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target

```

## Script

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 027

# ==========================================================
# JasperServer watchdog - control cada 15 segundos
# ==========================================================

JASPER_HOME="/opt/jasperreports-server-cp-7.1.0"
JASPER_CTL="${JASPER_HOME}/ctlscript.sh"
TOMCAT_CTL="${JASPER_HOME}/apache-tomcat/scripts/ctl.sh"
JAVA_HOME="${JASPER_HOME}/java"

HEALTH_URL="http://127.0.0.1:8080/jasperserver/flow.html?_flowId=viewReportFlow&ParentFolderUri=/reports&reportUnit=/reports/MONITOR&standAlone=true&userLocale=es_ES&output=html"
HEALTH_MARKER="MONITOR"

STATE_DIR="/var/lib/jasper-watchdog"
INCIDENT_DIR="${STATE_DIR}/incidents"
LOG_FILE="/var/log/jasper-watchdog.log"
LOCK_FILE="/run/jasper-watchdog.lock"
RESTART_HISTORY="${STATE_DIR}/restart-history.log"

CHECK_INTERVAL=15
HARD_CONFIRM_DELAY=5
SOFT_FAILURE_THRESHOLD=2

CONNECT_TIMEOUT=2
HEALTH_TIMEOUT=12
SLOW_RESPONSE_SECONDS=4

TOMCAT_STOP_TIMEOUT=45
TOMCAT_START_TIMEOUT=60
TOMCAT_RECOVERY_TIMEOUT=90

FULL_STOP_TIMEOUT=90
FULL_START_TIMEOUT=120
FULL_RECOVERY_TIMEOUT=180

MAX_AUTORESTARTS=3
RESTART_WINDOW_SECONDS=900
HEARTBEAT_SECONDS=300

mkdir -p "${STATE_DIR}" "${INCIDENT_DIR}"
touch "${LOG_FILE}" "${RESTART_HISTORY}"

if [[ "${1:-}" != "run" ]]; then
    echo "Uso: $0 run"
    exit 2
fi

exec 9>"${LOCK_FILE}"

if ! flock -n 9; then
    printf '%s | Otro watchdog ya posee el lock. Saliendo.\n' \
        "$(date '+%F %T')" >> "${LOG_FILE}"
    exit 0
fi

log() {
    local message="$*"
    printf '%s | %s\n' "$(date '+%F %T')" "${message}" >> "${LOG_FILE}"
    logger -t jasper-watchdog -- "${message}" 2>/dev/null || true
}

trap 'log "Watchdog detenido."; exit 0' TERM INT

get_java_pid() {
    pgrep -fo 'org.apache.catalina.startup.Bootstrap' || true
}

float_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'
}

health_check() {
    local body_file meta curl_rc

    HC_KIND="SOFT"
    HC_HTTP="000"
    HC_ELAPSED="N/A"

    body_file=$(mktemp "${STATE_DIR}/monitor.XXXXXX.html")

    set +e
    meta=$(
        curl --silent --show-error --location \
            --connect-timeout "${CONNECT_TIMEOUT}" \
            --max-time "${HEALTH_TIMEOUT}" \
            --output "${body_file}" \
            --write-out '%{http_code}|%{time_total}' \
            "${HEALTH_URL}" 2>>"${LOG_FILE}"
    )
    curl_rc=$?
    set -e

    if [[ "${meta}" == *"|"* ]]; then
        HC_HTTP="${meta%%|*}"
        HC_ELAPSED="${meta#*|}"
    fi

    if [[ "${curl_rc}" -eq 0 ]] &&
       [[ "${HC_HTTP}" == "200" ]] &&
       grep -Fq -- "${HEALTH_MARKER}" "${body_file}"; then

        rm -f "${body_file}"

        if float_gt "${HC_ELAPSED}" "${SLOW_RESPONSE_SECONDS}"; then
            HC_KIND="SOFT"
            return 1
        fi

        HC_KIND="OK"
        return 0
    fi

    cp "${body_file}" "${STATE_DIR}/last_health_failure.html" 2>/dev/null || true
    rm -f "${body_file}"

    if [[ "${curl_rc}" -ne 0 ]] ||
       [[ "${HC_HTTP}" == "000" ]] ||
       [[ -z "$(get_java_pid)" ]]; then
        HC_KIND="HARD"
    else
        HC_KIND="SOFT"
    fi

    return 1
}

capture_evidence() {
    local reason="$1"
    local ts dir java_pid catalina_log

    ts=$(date '+%Y%m%d_%H%M%S')
    dir="${INCIDENT_DIR}/${ts}"

    mkdir -p "${dir}"

    log "Guardando evidencia: ${dir} | Motivo: ${reason}"

    printf '%s\n' "${reason}" > "${dir}/motivo.txt"
    date > "${dir}/fecha.txt" 2>&1 || true
    uptime > "${dir}/uptime.txt" 2>&1 || true
    free -h > "${dir}/memoria.txt" 2>&1 || true
    df -h > "${dir}/disco.txt" 2>&1 || true
    df -i > "${dir}/inodos.txt" 2>&1 || true
    top -b -n 1 > "${dir}/top.txt" 2>&1 || true
    ps -eo pid,ppid,%cpu,%mem,rss,vsz,etime,cmd --sort=-%cpu \
        > "${dir}/procesos_cpu.txt" 2>&1 || true
    ss -tanp > "${dir}/conexiones.txt" 2>&1 || true
    journalctl --since "10 minutes ago" --no-pager \
        > "${dir}/journal_10_minutos.txt" 2>&1 || true
    dmesg -T | tail -300 > "${dir}/dmesg.txt" 2>&1 || true

    java_pid=$(get_java_pid)

    if [[ -n "${java_pid}" ]]; then
        ps -p "${java_pid}" -o pid,ppid,%cpu,%mem,rss,vsz,etime,cmd \
            > "${dir}/java_proceso.txt" 2>&1 || true

        top -H -b -n 1 -p "${java_pid}" \
            > "${dir}/java_threads_cpu.txt" 2>&1 || true

        if [[ -x "${JAVA_HOME}/bin/jstack" ]]; then
            timeout 5 "${JAVA_HOME}/bin/jstack" -l "${java_pid}" \
                > "${dir}/jstack.txt" 2>&1 || true
        fi
    fi

    catalina_log="${JASPER_HOME}/apache-tomcat/logs/catalina.$(date +%F).log"

    if [[ -f "${catalina_log}" ]]; then
        tail -n 2000 "${catalina_log}" \
            > "${dir}/catalina_ultimas_2000_lineas.txt" 2>&1 || true
    fi

    cp "${STATE_DIR}/last_health_failure.html" \
       "${dir}/last_health_failure.html" 2>/dev/null || true
}

take_restart_slot() {
    local now tmp count

    now=$(date +%s)
    tmp=$(mktemp "${STATE_DIR}/restart-history.XXXXXX")

    awk -v now="${now}" -v window="${RESTART_WINDOW_SECONDS}" \
        '$1 ~ /^[0-9]+$/ && now - $1 < window { print $1 }' \
        "${RESTART_HISTORY}" > "${tmp}" 2>/dev/null || true

    count=$(wc -l < "${tmp}")

    if (( count >= MAX_AUTORESTARTS )); then
        mv "${tmp}" "${RESTART_HISTORY}"
        return 1
    fi

    printf '%s\n' "${now}" >> "${tmp}"
    mv "${tmp}" "${RESTART_HISTORY}"
    return 0
}

wait_pid_gone() {
    local pid="$1"
    local max_seconds="$2"
    local end=$((SECONDS + max_seconds))

    while (( SECONDS < end )); do
        if ! kill -0 "${pid}" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done

    return 1
}

wait_for_monitor() {
    local max_seconds="$1"
    local waited=0

    while (( waited < max_seconds )); do
        sleep 5

        if health_check; then
            return 0
        fi

        waited=$((waited + 5))
    done

    return 1
}

stop_tomcat_fast() {
    local java_pid

    java_pid=$(get_java_pid)

    if [[ -z "${java_pid}" ]]; then
        return 0
    fi

    cd /tmp

    log "Intentando detener Tomcat en forma controlada. PID=${java_pid}"

    if timeout "${TOMCAT_STOP_TIMEOUT}" "${TOMCAT_CTL}" stop 9>&- >> "${LOG_FILE}" 2>&1; then
        :
    else
        log "Tomcat no finalizó el stop controlado dentro de ${TOMCAT_STOP_TIMEOUT}s."
    fi

    if wait_pid_gone "${java_pid}" 15; then
        return 0
    fi

    log "Tomcat continúa activo. Enviando SIGTERM a PID=${java_pid}."
    kill -TERM "${java_pid}" 2>/dev/null || true

    if wait_pid_gone "${java_pid}" 15; then
        return 0
    fi

    log "Tomcat no respondió a SIGTERM. Enviando SIGKILL a PID=${java_pid}."
    kill -KILL "${java_pid}" 2>/dev/null || true

    wait_pid_gone "${java_pid}" 10
}

restart_tomcat() {
    cd /tmp

    if ! stop_tomcat_fast; then
        log "ERROR: No se pudo detener Tomcat."
        return 1
    fi

    log "Iniciando Tomcat solamente."

    if ! timeout "${TOMCAT_START_TIMEOUT}" "${TOMCAT_CTL}" start 9>&- >> "${LOG_FILE}" 2>&1; then
        log "ERROR: No se pudo iniciar Tomcat."
        return 1
    fi

    if wait_for_monitor "${TOMCAT_RECOVERY_TIMEOUT}"; then
        log "Tomcat recuperado. MONITOR responde correctamente."
        return 0
    fi

    log "Tomcat inició, pero MONITOR no recuperó dentro de ${TOMCAT_RECOVERY_TIMEOUT}s."
    return 1
}

full_restart_jasper() {
    local java_pid

    cd /tmp

    log "Fallback: reinicio completo de JasperServer."

    if timeout "${FULL_STOP_TIMEOUT}" "${JASPER_CTL}" stop 9>&- >> "${LOG_FILE}" 2>&1; then
        :
    else
        log "Stop completo de JasperServer excedió el timeout."
    fi

    java_pid=$(get_java_pid)

    if [[ -n "${java_pid}" ]]; then
        kill -TERM "${java_pid}" 2>/dev/null || true
        wait_pid_gone "${java_pid}" 15 || true
    fi

    if ! timeout "${FULL_START_TIMEOUT}" "${JASPER_CTL}" start 9>&- >> "${LOG_FILE}" 2>&1; then
        log "ERROR: No se pudo iniciar JasperServer completo."
        return 1
    fi

    if wait_for_monitor "${FULL_RECOVERY_TIMEOUT}"; then
        log "JasperServer recuperado. MONITOR responde correctamente."
        return 0
    fi

    log "ERROR CRITICO: JasperServer no recuperó MONITOR luego del reinicio completo."
    return 1
}

recover_service() {
    local reason="$1"

    if ! take_restart_slot; then
        log "ERROR CRITICO: se alcanzó el máximo de ${MAX_AUTORESTARTS} reinicios en ${RESTART_WINDOW_SECONDS}s. No se reinicia más automáticamente."
        return 1
    fi

    capture_evidence "${reason}"

    if restart_tomcat; then
        return 0
    fi

    log "El restart de Tomcat no alcanzó. Se intenta reinicio completo de JasperServer."

    full_restart_jasper
}

SOFT_FAILURES=0
LAST_HEARTBEAT=0

log "Watchdog iniciado. Control cada ${CHECK_INTERVAL}s."

while true; do

    if health_check; then
        SOFT_FAILURES=0

        now=$(date +%s)

        if (( now - LAST_HEARTBEAT >= HEARTBEAT_SECONDS )); then
            log "Health OK | HTTP=${HC_HTTP} | Tiempo=${HC_ELAPSED}s"
            LAST_HEARTBEAT="${now}"
        fi

        sleep "${CHECK_INTERVAL}"
        continue
    fi

    if [[ "${HC_KIND}" == "HARD" ]]; then
        log "Falla dura detectada | HTTP=${HC_HTTP} | Tiempo=${HC_ELAPSED}s. Confirmando en ${HARD_CONFIRM_DELAY}s."
        sleep "${HARD_CONFIRM_DELAY}"

        if health_check; then
            log "Falla dura transitoria. MONITOR volvió a responder."
            SOFT_FAILURES=0
            sleep "${CHECK_INTERVAL}"
            continue
        fi

        recover_service "Falla dura confirmada | HTTP=${HC_HTTP} | Tiempo=${HC_ELAPSED}s" || true
        SOFT_FAILURES=0

    else
        SOFT_FAILURES=$((SOFT_FAILURES + 1))

        log "Falla lógica/lenta ${SOFT_FAILURES}/${SOFT_FAILURE_THRESHOLD} | HTTP=${HC_HTTP} | Tiempo=${HC_ELAPSED}s"

        if (( SOFT_FAILURES >= SOFT_FAILURE_THRESHOLD )); then
            recover_service "Falla lógica/lenta confirmada | HTTP=${HC_HTTP} | Tiempo=${HC_ELAPSED}s" || true
            SOFT_FAILURES=0
        fi
    fi

    sleep "${CHECK_INTERVAL}"
done

```
