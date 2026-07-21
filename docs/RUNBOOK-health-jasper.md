# Protocolo de revisión rápida de salud — JasperServer

Guía operativa para IT. Objetivo: ante un supuesto problema con JasperServer,
diagnosticar rápido **qué** está pasando y **qué hacer**, usando las
herramientas ya instaladas en cada server.

> Escala de tiempo esperada: triage inicial en ~1 minuto (sección 1). Si el
> server tiene load balancer (hoy solo **IntDb4**), primero ubicá el nodo/capa
> que falla (sección 2) y recién ahí bajás por el árbol de decisión (sección 3).

---

## Inventario y topología

| Server | Rol | Balanceo | Nodos (IP interna : puerto) | Hostname público |
|---|---|---|---|---|
| **JasperDesa** | Donde se instala/actualiza todo y el equipo pega los reportes; luego se **propaga** al resto | Single node | *(completar)* | *(completar)* |
| **Jasper IntDb4** | Producción | **Load balancer** (backend set OCI `JasperServer_INTDB4_poolbs`) | `10.0.2.97:8080`, `10.0.2.206:8080`, `10.0.2.219:8080` | `jasper-intdb4.inthegrasoftware.com` |
| **Jasper IntDb5** | Producción | Single node | *(completar)* | *(completar)* |
| **Jasper IntDb6** | Producción | Single node | *(completar)* | *(completar)* |
| **Jasper ItgDb1** | Producción | Single node | *(completar)* | *(completar)* |

**Capas en IntDb4** (importante para saber dónde falla):

```
Usuario → WAF (https://jasper-intdb4.inthegrasoftware.com)
        → Load Balancer OCI (backend set JasperServer_INTDB4_poolbs)
        → 3 backends Tomcat (10.0.2.97 / .206 / .219 : 8080)
```

En los servers single-node no hay WAF/LB intermedios: se diagnostica directo
sobre el nodo. En IntDb4 hay que aislar **qué capa** falla (sección 2).

---

## Herramientas instaladas (contexto)

| Herramienta | Qué hace | Repo |
|---|---|---|
| **Watchdog** | Chequea salud cada 15s; si Jasper no responde, captura evidencia y reinicia el/los componente(s). No requiere intervención. | `jasperserver-watchdog` |
| **Diagnóstico de CPU/degradación** | Diagnostica CPU alta / reportes pesados. **Solo lee, no reinicia.** Identifica reporte, subreportes, QR, GC. | `jasper-cpu-diagnostic` |
| **Limpieza (`tomcat-cleanup.sh`)** | Recupera disco (heap dumps, catalina.out, temporales) **sin parar el stack**. | `jasperserver-watchdog` |

Todo se instala/actualiza en **jasper-desa** y se propaga al resto de los jaspers.
En IntDb4 cada backend es un nodo aparte: te conectás por SSH al nodo puntual
(su IP interna) y ahí corren su propio watchdog, logs y `ctlscript.sh`.

### Rutas y comandos clave (en cada nodo)

```text
JASPER_HOME     /opt/jasperreports-server-cp-7.1.0
Control stack   $JASPER_HOME/ctlscript.sh {status|start|stop|restart} [tomcat|postgresql]
Logs Tomcat     $JASPER_HOME/apache-tomcat/logs
pg_isready      $JASPER_HOME/postgresql/bin/pg_isready -h 127.0.0.1 -p 5432
Watchdog log    /var/log/jasper-watchdog/watchdog.log
Incidentes      /var/log/jasper-watchdog/incidents/
Config watchdog /etc/jasper-watchdog/jasper-watchdog.conf   (HEALTH_URL = reporte MONITOR)
Breaker (files) /var/log/jasper-watchdog/{restart-history.log,circuit-breaker-blocked.marker}
Limpieza        /home/opc/script/tomcat-cleanup.sh   → log /var/log/tomcat-cleanup.log
Diagnóstico CPU /root/diagnosticar_cpu_jasper_definitivo.sh → salida /tmp/jasper-cpu-diagnostico-<fecha>/
Servicio/timer  jasper-watchdog.service / jasper-watchdog.timer
```

### URLs de validación rápida (IntDb4)

```text
# Público (pasa por WAF + LB) — MONITOR
https://jasper-intdb4.inthegrasoftware.com/jasperserver/flow.html?_flowId=viewReportFlow&ParentFolderUri=/reports&reportUnit=/reports/MONITOR&standAlone=true&userLocale=es_ES&output=html

# Cada backend directo (saltea WAF/LB) — reachability rápida
http://10.0.2.97:8080/jasperserver/login.html
http://10.0.2.206:8080/jasperserver/login.html
http://10.0.2.219:8080/jasperserver/login.html

# Reporte real de prueba (valida render, no solo login) — público y por backend
#   LIQUI_ID de prueba: 3F33CA0D4ED95F94F635D7036F7D5F2A   (CONFIRMAR que es un registro de prueba, no de cliente)
https://jasper-intdb4.inthegrasoftware.com/jasperserver/flow.html?_flowId=viewReportFlow&userLocale=en_US&standAlone=true&output=pdf&reportUnit=/reports/ELEBAR/RESUMEN_DIGITAL&LIQUI_ID=3F33CA0D4ED95F94F635D7036F7D5F2A
http://10.0.2.97:8080/jasperserver/flow.html?_flowId=viewReportFlow&userLocale=en_US&standAlone=true&output=pdf&reportUnit=/reports/ELEBAR/RESUMEN_DIGITAL&LIQUI_ID=3F33CA0D4ED95F94F635D7036F7D5F2A
```

---

## 1. Triage en 60 segundos

**En un server con LB (IntDb4):** empezá desde afuera y desde la consola OCI
(sección 2) para ubicar el nodo/capa. **En single-node:** corré este bloque
directo en el nodo:

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

Con esa salida, elegí la rama:

| Lo que ves | Ir a |
|---|---|
| Es IntDb4 (o cualquier server con LB) | Sección 2 primero (ubicar nodo/capa) |
| `http_code=200` y stack `already running` → sano | Sección 3.E (parece OK) |
| No responde / `http_code=000` / connection refused | Sección 3.A |
| Responde pero lento (`time` alto) o CPU alta en `uptime` | Sección 3.B |
| `df` alto (disco casi lleno) | Sección 3.C |
| Log con `BLOCKED_CIRCUIT_BREAKER` o muchos `RECOVERED` seguidos | Sección 3.D |

---

## 2. ¿Qué capa/nodo está fallando? (servers con load balancer — hoy solo IntDb4)

El objetivo es separar **WAF / Load Balancer / un backend puntual** antes de
meterse a un nodo.

1. **Desde afuera (WAF + LB):** abrí/curleá la URL pública del MONITOR.
   - Responde 200 → el camino completo está sano; si igual hay quejas, es un
     reporte puntual (sección 3.B) o un backend intermitente.
   - No responde → seguí a los pasos 2 y 3 para ver si es un backend o la capa WAF/LB.
2. **Consola OCI — salud de los backends:** Networking → Load balancers → (el LB
   de IntDb4) → Backend sets → `JasperServer_INTDB4_poolbs` → pestaña **Backends**
   → columna **Health**. Región: *Chile Central (Santiago)*.
   - Muestra cuál backend el LB considera caído (`Critical`/`Warning`) vs `Ok`.
3. **Cada backend directo (saltea WAF/LB):** probá los 3 por IP interna.
   ```bash
   for ip in 10.0.2.97 10.0.2.206 10.0.2.219; do
     printf '%s -> ' "$ip"
     curl -s -o /dev/null -w "http_code=%{http_code} time=%{time_total}s\n" \
       --max-time 15 "http://$ip:8080/jasperserver/login.html"
   done
   ```

**Matriz de interpretación:**

| Público | Backends directos / OCI Health | Conclusión → acción |
|---|---|---|
| Falla | Los 3 responden OK | Problema en la **capa WAF/LB**, no en Jasper. Ver sección 8 ("corrupción atrás del WAF"). |
| Falla | 1 (o 2) backend no responde / OCI lo marca down | Es **ese nodo**. SSH a esa IP y aplicá el triage por nodo (sección 3). |
| Falla | Ninguno responde | Caída general de los backends. SSH a cada nodo y sección 3 (empezar por 3.A / 3.C). |
| OK | Un backend intermitente | Nodo con flapping: SSH a ese nodo, revisá watchdog (sección 3.D / 4). |

> En cuanto identificás el nodo, todo lo de las secciones 3–7 se aplica **en ese
> nodo** (cada backend tiene su propio watchdog, logs y stack).

---

## 3. Árbol de decisión por nodo (síntoma → acción)

*(Ya estás en el nodo que falla — por SSH a su IP, o directo si es single-node.)*

### A. Jasper no responde

1. **Mirá si el watchdog ya está actuando** (no pises su trabajo):
   ```bash
   tail -n 30 /var/log/jasper-watchdog/watchdog.log
   ```
   - `incident_status=RECOVERED` reciente → **ya lo levantó**. Confirmá con
     `ctlscript.sh status` y `curl`. Después andá a la sección 4 para ver *por qué* se cayó.
   - `NOT_RECOVERED` o `BLOCKED_CIRCUIT_BREAKER` → sección 3.D.
   - Sin eventos recientes → el watchdog no corre: `systemctl is-active jasper-watchdog.timer`
     (si está `inactive`, `sudo systemctl enable --now jasper-watchdog.timer`).
2. **Descartá disco lleno** (causa frecuente de que Tomcat no arranque): sección 3.C.
3. Si hace falta levantar a mano: sección 7.

### B. CPU alta / Jasper lento pero arriba

Escenario típico de **reporte pesado** (muchos subreportes + QR → agota heap → GC en loop).

1. Corré el diagnóstico (no reinicia, solo observa):
   ```bash
   sudo /root/diagnosticar_cpu_jasper_definitivo.sh
   ```
2. Leé la recomendación y qué reporte lo causa:
   ```bash
   D=$(ls -dt /tmp/jasper-cpu-diagnostico-* | head -1)
   cat "$D/recomendacion.txt"
   cat "$D/reportes_runtime_confiables.txt"
   ```
3. Marca `QR` + `subreportes` + `GC activo` → patrón conocido (sección 8). Si da un
   reporte confiable, pasarlo al equipo funcional para optimizarlo.

### C. Disco lleno

1. ¿Quién se comió el disco? Casi siempre `temp/` (heap dumps `.hprof`):
   ```bash
   JH=/opt/jasperreports-server-cp-7.1.0
   du -sh "$JH"/apache-tomcat/{temp,logs,work} 2>/dev/null
   ls -lhS "$JH"/apache-tomcat/temp/*.hprof 2>/dev/null | head
   ```
2. Limpiá — **primero en seco**, después real:
   ```bash
   sudo DRY_RUN=1 /home/opc/script/tomcat-cleanup.sh
   sudo /home/opc/script/tomcat-cleanup.sh
   tail -n 30 /var/log/tomcat-cleanup.log
   ```
3. Los `.hprof` gigantes son **heap dumps de OOM**: además de ocupar disco, son
   evidencia de que un reporte reventó la JVM (sección 8). Copiá uno antes de limpiar
   si querés analizarlo.

### D. El watchdog flapea / circuit breaker disparado

Síntoma: `BLOCKED_CIRCUIT_BREAKER` o `circuit_breaker_still_blocked` (reinició 3
veces en 15 min sin estabilizar).

1. **No reseteés el breaker todavía.** Entendé por qué no se sostiene:
   ```bash
   sudo crontab -l
   D=$(ls -dt /var/log/jasper-watchdog/incidents/* | head -1)
   cat "$D/cron_and_sessions.txt"                 # ¿algo externo apaga el stack?
   grep -i "killed process" "$D"/os_dmesg.txt     # ¿OOM del kernel?
   ```
   (Disco lleno → sección 3.C.)
2. Con la causa resuelta, rearmá el breaker:
   ```bash
   sudo sh -c ': > /var/log/jasper-watchdog/restart-history.log'
   sudo rm -f /var/log/jasper-watchdog/circuit-breaker-blocked.marker
   ```
   > El breaker igual se auto-resetea solo a los ~15 min del último reinicio.

### E. Parece OK pero hay quejas

1. Confirmá que el `200` sea real y no lento: repetí el `curl` un par de veces.
2. Revisá incidentes recientes: `ls -lt /var/log/jasper-watchdog/incidents/ | head`.
3. Si es un reporte puntual, corré el diagnóstico (3.B) mientras el usuario reproduce
   la queja, o probá el **reporte real de prueba** (ver URLs en "Herramientas").

---

## 4. Interpretar el watchdog

**Eventos en `watchdog.log`:**

| Evento | Significa |
|---|---|
| `health_probe_failed phase=first` | Falló un chequeo (todavía no reinicia; espera confirmación). |
| `incident_status=RECOVERED` | Reinició y Jasper volvió a responder 200. |
| `incident_status=NOT_RECOVERED` | Reinició pero no recuperó dentro del timeout. |
| `BLOCKED_CIRCUIT_BREAKER` | 3 reinicios en 15 min sin éxito → frenó para no loopear (sección 3.D). |
| `circuit_breaker_still_blocked` | Sigue caído y bloqueado; heartbeat, no hace nada. |

**Evidencia por incidente** (`/var/log/jasper-watchdog/incidents/<id>/`):
`README.md` (leer primero), `recovery_checks.log`, `os_*.txt` (CPU/mem/disco/dmesg/journal),
`jvm_thread_dump.txt` / `jvm_threads_cpu.txt`, `pg_*.txt`, `last_health_failure.html`.

> **NO borrar los incidentes.** Son el registro forense; sin ellos no se puede
> reconstruir por qué se cayó.

---

## 5. Diagnóstico de reporte / degradación

Cuándo: CPU alta sostenida o Jasper lento **pero arriba** (sección 3.B).
Es **read-only**: no reinicia nada.

```bash
sudo /root/diagnosticar_cpu_jasper_definitivo.sh
# opcional: mapear el reporte al repositorio Jasper (requiere password de DB;
# NO dejar el password en archivos ni en el historial de shell)
# sudo DB_LOOKUP=1 PGPASSWORD='<password>' /root/diagnosticar_cpu_jasper_definitivo.sh
```

Salida en `/tmp/jasper-cpu-diagnostico-<fecha>/`: `recomendacion.txt`,
`reportes_runtime_confiables.txt`, `subreportes_detectados_heap.txt`,
`jasper_execution_threads.txt`, `gc_delta.txt`.

---

## 6. Limpieza de disco

Cuándo: disco alto o `temp/` inflado. Corre **sin parar el stack**, seguro en
cualquier momento y **no pelea con el watchdog**.

```bash
sudo DRY_RUN=1 /home/opc/script/tomcat-cleanup.sh   # previsualizar
sudo /home/opc/script/tomcat-cleanup.sh             # ejecutar
```

Limpia por antigüedad: heap dumps `.hprof`, `catalina.out` sobredimensionado
(lo trunca, no lo borra), logs rotados viejos, temporales de reportes huérfanos
y jars JDBC viejos (nunca el de la instancia en uso).

---

## 7. Recuperación manual

Solo si el watchdog no alcanza o hay que forzarlo:

```bash
JH=/opt/jasperreports-server-cp-7.1.0
sudo "$JH"/ctlscript.sh restart          # stack completo
sudo "$JH"/ctlscript.sh restart tomcat   # o por componente
sudo "$JH"/ctlscript.sh stop tomcat
sudo "$JH"/ctlscript.sh start tomcat
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

## 8. Problemas conocidos y abiertos

**Reportes que revientan la JVM (confirmado).** Reportes con muchos subreportes
con **códigos QR embebidos** agotan el heap → `OutOfMemoryError` → GC en loop →
Jasper cuelga y deja un `.hprof` gigante en `temp/`. El diagnóstico (sección 5)
identifica el reporte; el fix real es optimizar/limitar ese reporte del lado
funcional. La limpieza (sección 6) recupera el disco de los dumps.

**Cuelgues de 1-2 min SIN OOM (IntDb4, en análisis desde jul/2026).** Además del
modo anterior (crash con `.hprof`), IntDb4 muestra cuelgues donde la JVM queda
**viva pero congelada**: el watchdog la ve lenta (responde en 5-10s) o timeoutea,
la reinicia y recupera en ~1 min. En estos incidentes **NO hay OOM**: sin
`.hprof`, sin `OutOfMemoryError` en logs, swap sin tocar y RAM libre. El RSS ~10 GB
es solo `-Xmx8g` + Metaspace, JVM llena pero no reventada. Firma de **pausa larga
de GC** o **pool de threads/conexiones agotado** (probable gatillo: reportes
pesados QR+subreportes). Se agravó al dejar **un solo backend** detrás del LB
(sección 2): sin redundancia, cada cuelgue lo siente todo el mundo.

Para cerrar la causa raíz hace falta cazar el próximo cuelgue con datos:

1. **Activar GC logging.** Agregar a `CATALINA_OPTS` (no a JAVA_OPTS, así el
   shutdown de Tomcat no pisa el mismo `gc.log`) en
   `/opt/jasperreports-server-cp-7.1.0/apache-tomcat/bin/setenv.sh` (NO ejecutar
   estas líneas en la shell). **IntDb4 corre Java 8 (1.8.0_151)** → usar el
   bloque Java 8. Confirmar en otros nodos con
   `/opt/jasperreports-server-cp-7.1.0/java/bin/java -version`:
   ```sh
   # setenv.sh — Java 11+ (unified logging)
   CATALINA_OPTS="$CATALINA_OPTS -Xlog:gc*,safepoint:file=/opt/jasperreports-server-cp-7.1.0/apache-tomcat/logs/gc.log:utctime,pid,tags:filecount=5,filesize=20m"
   ```
   ```sh
   # setenv.sh — Java 8
   CATALINA_OPTS="$CATALINA_OPTS -Xloggc:/opt/jasperreports-server-cp-7.1.0/apache-tomcat/logs/gc.log -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+PrintGCApplicationStoppedTime -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=5 -XX:GCLogFileSize=20m"
   ```
   Toma efecto en el próximo restart de Tomcat (`ctlscript.sh restart tomcat`).
   **Con rotación en Java 8 el archivo se llama `gc.log.0.current`** (no `gc.log`
   a secas). Cuando caiga el próximo cuelgue, buscar pausas largas y su causa:
   ```bash
   grep -E 'Full GC|Metadata GC Threshold|Total time for which application threads were stopped: [0-9]{2,}' \
     /opt/jasperreports-server-cp-7.1.0/apache-tomcat/logs/gc.log.0.current
   ```
   Sospecha principal: `Full GC (Metadata GC Threshold)` con pausas de varios
   segundos = Metaspace (512m) saturándose por compilación de reportes → subir
   `-XX:MaxMetaspaceSize` y/o revisar leak de classloaders.
2. **Thread dump real en el próximo incidente.** Ya corregido en el watchdog: la
   captura tomaba el PID de PostgreSQL (su ruta contiene `jasperreports-server`)
   en vez de la JVM, así que los thread dumps salían vacíos. Ahora ancla en
   `org.apache.catalina.startup.Bootstrap`. *Caveat:* `jcmd/jstack` corren como
   root; si la JVM es de otro usuario el attach puede fallar. Verificar dueño:
   ```bash
   ps -o user= -p "$(pgrep -f org.apache.catalina.startup.Bootstrap | head -n1)"
   ```

Con GC log + thread dump del próximo cuelgue se decide el fix real (subir
Metaspace/tunear G1, o limitar concurrencia de reportes). Y para el dolor
inmediato: **restaurar un segundo backend** detrás del LB.

**Problemas ABIERTOS (a escalar, no son pasos de triage):**

- **Corrupción atrás del WAF** — *pendiente de definir.* Falta documentar síntoma
  concreto, cómo se reproduce y cómo se verifica. Pista de aislamiento: si el
  MONITOR **público** falla pero los 3 backends responden OK directo por IP
  (sección 2), el problema está en la capa WAF/LB, no en Jasper. Completar cuando
  se acuerde.
- **Reportes de INTDB5 (sipssa) disparados desde jasper-intdb4** — investigación
  abierta con los equipos. Para ver las requests SIPSSA que llegan a IntDb4:
  ```bash
  grep -i SIPSSA /opt/jasperreports-server-cp-7.1.0/apache-tomcat/logs/localhost_access_log.<fecha>.txt
  ```
  Estado: en análisis.

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
