# Protocolo de revisión rápida de salud — JasperServer

Guía operativa para IT. Objetivo: ante un supuesto problema con JasperServer,
diagnosticar rápido **qué** está pasando y **qué hacer**, usando las
herramientas ya instaladas en cada server.

> Escala de tiempo esperada: triage inicial en ~1 minuto (sección 1), luego se
> baja por el árbol de decisión (sección 2) según el síntoma.

---

## Herramientas instaladas (contexto)

| Herramienta | Qué hace | Repo |
|---|---|---|
| **Watchdog** | Chequea salud cada 15s; si Jasper no responde, captura evidencia y reinicia el/los componente(s). No requiere intervención. | `jasperserver-watchdog` |
| **Diagnóstico de CPU/degradación** | Diagnostica CPU alta / reportes pesados. **Solo lee, no reinicia.** Identifica reporte, subreportes, QR, GC. | `jasper-cpu-diagnostic` |
| **Limpieza (`tomcat-cleanup.sh`)** | Recupera disco (heap dumps, catalina.out, temporales) **sin parar el stack**. | `jasperserver-watchdog` |

Todo se instala/actualiza en **jasper-desa** y se propaga al resto de los jaspers.

### Rutas y comandos clave

```text
JASPER_HOME     /opt/jasperreports-server-cp-7.1.0
Control stack   $JASPER_HOME/ctlscript.sh {status|start|stop|restart} [tomcat|postgresql]
Watchdog log    /var/log/jasper-watchdog/watchdog.log
Incidentes      /var/log/jasper-watchdog/incidents/
Config watchdog /etc/jasper-watchdog/jasper-watchdog.conf   (HEALTH_URL = reporte MONITOR)
Breaker (files) /var/log/jasper-watchdog/{restart-history.log,circuit-breaker-blocked.marker}
Limpieza        /home/opc/script/tomcat-cleanup.sh   → log /var/log/tomcat-cleanup.log
Diagnóstico CPU /root/diagnosticar_cpu_jasper_definitivo.sh → salida /tmp/jasper-cpu-diagnostico-<fecha>/
Servicio/timer  jasper-watchdog.service / jasper-watchdog.timer
```

---

## 1. Triage en 60 segundos

Copiar y pegar todo el bloque; da la foto completa:

```bash
JH=/opt/jasperreports-server-cp-7.1.0

echo "== 1. ¿Responde Jasper? =="
curl -s -o /dev/null -w "http_code=%{http_code} time=%{time_total}s\n" \
  --max-time 15 "$(. /etc/jasper-watchdog/jasper-watchdog.conf; echo "$HEALTH_URL")"

echo "== 2. Estado del stack =="
"$JH"/ctlscript.sh status

echo "== 3. ¿Watchdog activo? =="
systemctl is-active jasper-watchdog.timer; systemctl is-enabled jasper-watchdog.timer

echo "== 4. Últimos eventos del watchdog =="
tail -n 15 /var/log/jasper-watchdog/watchdog.log

echo "== 5. Recursos =="
uptime; free -m | head -2; df -h "$JH" | tail -1
echo "procesos java:"; pgrep -fa 'catalina.startup.Bootstrap' | wc -l
```

Con esa salida, elegí la rama del árbol:

| Lo que ves | Ir a |
|---|---|
| `http_code=200` y stack `already running` → sano | Sección 2.E (parece OK) |
| No responde / `http_code=000` / connection refused | Sección 2.A |
| Responde pero lento (`time` alto) o CPU alta en `uptime` | Sección 2.B |
| `df` alto (disco casi lleno) | Sección 2.C |
| Log con `BLOCKED_CIRCUIT_BREAKER` o muchos `RECOVERED` seguidos | Sección 2.D |

---

## 2. Árbol de decisión (síntoma → acción)

### A. Jasper no responde

1. **Mirá si el watchdog ya está actuando** (no pises su trabajo):
   ```bash
   tail -n 30 /var/log/jasper-watchdog/watchdog.log
   ```
   - Ves `incident_status=RECOVERED` reciente → **ya lo levantó**. Confirmá con
     `ctlscript.sh status` y `curl`. Después andá a la sección 3 para ver *por qué* se cayó.
   - Ves `NOT_RECOVERED` o `BLOCKED_CIRCUIT_BREAKER` → sección 2.D.
   - No hay eventos recientes → el watchdog no está corriendo: revisá
     `systemctl is-active jasper-watchdog.timer` (si está `inactive`, `sudo systemctl enable --now jasper-watchdog.timer`).
2. **Descartá disco lleno** (causa frecuente de que Tomcat no arranque): sección 2.C.
3. Si hace falta levantar a mano: sección 6.

### B. CPU alta / Jasper lento pero arriba

Es el escenario típico de **reporte pesado** (muchos subreportes + QR → agota heap → GC en loop).

1. Corré el diagnóstico (no reinicia, solo observa):
   ```bash
   sudo /root/diagnosticar_cpu_jasper_definitivo.sh
   ```
2. Leé la recomendación y qué reporte lo está causando:
   ```bash
   D=$(ls -dt /tmp/jasper-cpu-diagnostico-* | head -1)
   cat "$D/recomendacion.txt"
   cat "$D/reportes_runtime_confiables.txt"   # nombre del reporte culpable
   ```
3. Interpretación:
   - Marca `QR` + `subreportes` + `GC activo` → es el patrón conocido (ver sección 7).
   - Da un nombre de reporte confiable → pasarlo al equipo funcional para revisar/optimizar ese reporte.
4. Si el servicio está degradado y no se puede cancelar la ejecución, el watchdog
   lo va a reciclar solo cuando el probe falle; o reiniciá a mano (sección 6).

### C. Disco lleno

1. ¿Quién se comió el disco? Casi siempre `temp/` (heap dumps `.hprof`):
   ```bash
   JH=/opt/jasperreports-server-cp-7.1.0
   du -sh "$JH"/apache-tomcat/{temp,logs,work} 2>/dev/null
   ls -lhS "$JH"/apache-tomcat/temp/*.hprof 2>/dev/null | head
   ```
2. Limpiá — **primero en seco**, después real:
   ```bash
   sudo DRY_RUN=1 /home/opc/script/tomcat-cleanup.sh   # muestra qué borraría
   sudo /home/opc/script/tomcat-cleanup.sh             # ejecuta
   tail -n 30 /var/log/tomcat-cleanup.log
   ```
3. Los `.hprof` gigantes son **heap dumps de OOM**: además de ocupar disco, son
   evidencia de que un reporte reventó la JVM (sección 7). Si querés analizarlos,
   copiá uno antes de limpiar.

### D. El watchdog flapea / circuit breaker disparado

Síntoma en el log: `BLOCKED_CIRCUIT_BREAKER` o `circuit_breaker_still_blocked`
(el watchdog reinició 3 veces en 15 min y no logró estabilizar).

1. **No reseteés el breaker todavía.** Primero entendé por qué no se sostiene:
   - ¿Algo externo apaga el stack? (cron, otro proceso). Revisá:
     ```bash
     sudo crontab -l
     D=$(ls -dt /var/log/jasper-watchdog/incidents/* | head -1)
     cat "$D/cron_and_sessions.txt"
     ```
   - ¿OOM del kernel? `grep -i "killed process" "$D"/os_dmesg.txt`
   - ¿Disco lleno? sección 2.C.
2. Recién con la causa identificada y resuelta, rearmá el breaker:
   ```bash
   sudo sh -c ': > /var/log/jasper-watchdog/restart-history.log'
   sudo rm -f /var/log/jasper-watchdog/circuit-breaker-blocked.marker
   ```
   > El breaker igual se auto-resetea solo a los ~15 min del último reinicio.

### E. Parece OK pero hay quejas

1. Confirmá que el `200` sea real y no lento: repetí el `curl` de la sección 1 un par de veces.
2. Revisá si hubo incidentes recientes (aunque ahora esté sano):
   ```bash
   ls -lt /var/log/jasper-watchdog/incidents/ | head
   ```
3. Si el problema es de un reporte puntual (no del server), corré el diagnóstico (2.B)
   mientras el usuario reproduce la queja.

---

## 3. Interpretar el watchdog

**Eventos en `watchdog.log`:**

| Evento | Significa |
|---|---|
| `health_probe_failed phase=first` | Falló un chequeo (todavía no reinicia; espera confirmación). |
| `incident_status=RECOVERED` | Reinició y Jasper volvió a responder 200. |
| `incident_status=NOT_RECOVERED` | Reinició pero no recuperó dentro del timeout. |
| `BLOCKED_CIRCUIT_BREAKER` | 3 reinicios en 15 min sin éxito → frenó para no loopear (sección 2.D). |
| `circuit_breaker_still_blocked` | Sigue caído y bloqueado; heartbeat, no hace nada. |

**Evidencia por incidente** (en `/var/log/jasper-watchdog/incidents/<id>/`):

- `README.md` — resumen del incidente (leer esto primero).
- `recovery_checks.log` — qué probó tras cada reinicio.
- `os_*.txt` — CPU, memoria, disco, procesos, dmesg, journal.
- `jvm_thread_dump.txt` / `jvm_threads_cpu.txt` — qué estaba haciendo la JVM.
- `pg_*.txt` — actividad, bloqueos y locks de PostgreSQL.
- `last_health_failure.html` — la respuesta que falló.

> **NO borrar los incidentes.** Son el registro forense; sin ellos no se puede
> reconstruir por qué se cayó.

---

## 4. Diagnóstico de reporte / degradación

Cuándo usarlo: CPU alta sostenida o Jasper lento **pero arriba** (sección 2.B).
Es **read-only**: no reinicia nada, solo captura evidencia.

```bash
sudo /root/diagnosticar_cpu_jasper_definitivo.sh
# opcional: mapear el reporte al repositorio Jasper (requiere password de DB;
# NO dejar el password en archivos ni en el historial de shell)
# sudo DB_LOOKUP=1 PGPASSWORD='<password>' /root/diagnosticar_cpu_jasper_definitivo.sh
```

Salida en `/tmp/jasper-cpu-diagnostico-<fecha>/`:
`recomendacion.txt`, `reportes_runtime_confiables.txt`, `subreportes_detectados_heap.txt`,
`jasper_execution_threads.txt`, `gc_delta.txt`.

---

## 5. Limpieza de disco

Cuándo: disco alto o `temp/` inflado. Corre **sin parar el stack**, así que es
seguro en cualquier momento y **no pelea con el watchdog**.

```bash
sudo DRY_RUN=1 /home/opc/script/tomcat-cleanup.sh   # previsualizar
sudo /home/opc/script/tomcat-cleanup.sh             # ejecutar
```

Limpia por antigüedad: heap dumps `.hprof`, `catalina.out` sobredimensionado
(lo trunca, no lo borra), logs rotados viejos, temporales de reportes huérfanos
y jars JDBC viejos (nunca el de la instancia en uso).

---

## 6. Recuperación manual

Solo si el watchdog no alcanza o hay que forzarlo:

```bash
JH=/opt/jasperreports-server-cp-7.1.0
sudo "$JH"/ctlscript.sh restart          # stack completo
# o por componente:
sudo "$JH"/ctlscript.sh restart tomcat
```

- Durante los ~30-50s que tarda en volver, **el watchdog lo va a ver caído y va a
  lanzar su propia recuperación en paralelo**. Es esperable e inofensivo (genera un
  incidente en el log); no te asustes.
- Verificá que **quede** arriba (no que se caiga a los 25s):
  ```bash
  sleep 60; "$JH"/ctlscript.sh status
  systemctl show jasper-watchdog.service -p KillMode   # debe decir KillMode=process
  ```

---

## 7. Causa raíz conocida y problemas abiertos

**Reportes que revientan la JVM (confirmado).** Reportes con muchos subreportes
con **códigos QR embebidos** agotan el heap → `OutOfMemoryError` → GC en loop →
Jasper cuelga y deja un `.hprof` gigante en `temp/`. El diagnóstico (sección 4)
identifica el reporte; el fix real es optimizar/limitar ese reporte del lado
funcional. La limpieza (sección 5) recupera el disco que dejan los dumps.

**Problemas ABIERTOS (a escalar, no son pasos de triage):**

- **Corrupción atrás del WAF** — *pendiente de definir.* Falta documentar síntoma
  concreto, cómo se reproduce y cómo se verifica. Completar cuando se acuerde.
- **Reportes de INTDB5 (sipssa) disparados desde jasper-intdb4** — investigación
  abierta con los equipos. Síntoma: ejecuciones que deberían correr en INTDB5 se
  originan desde intdb4. Estado: en análisis.

**Escalado:** si tras el triage no se resuelve, o si es uno de los problemas
abiertos → escalar a *(completar: responsable / canal de guardia)*.

---

## Apéndice — instalación y propagación

Las herramientas se instalan/actualizan en **jasper-desa** y se replican al resto.
Para traer la última versión en un server:

```bash
sudo git -C /opt/jasper-watchdog fetch --tags
sudo git -C /opt/jasper-watchdog checkout "$(git -C /opt/jasper-watchdog describe --tags --abbrev=0)"
```

Repos: `jasperserver-watchdog` (watchdog + `tomcat-cleanup.sh`) y
`jasper-cpu-diagnostic` (diagnóstico de CPU/degradación).
