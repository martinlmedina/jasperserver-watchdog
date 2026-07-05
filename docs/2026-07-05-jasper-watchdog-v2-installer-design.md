# JasperServer Watchdog v2 — Installer Design

## Problem

The v2 README section 3 asks the operator to run six manual `install -m ...`
commands plus directory creation, systemd reload, tmpfiles, and timer enable —
by hand, in order, as root. This is error-prone (wrong mode, wrong owner,
skipped step) for a tool that restarts production infrastructure, and there is
no supported way to update an existing install or to know which configuration
still needs attention afterward.

Two concerns are conflated in the current instructions:

1. **Transport** — how the files reach the server (today: "copy them somehow" /
   `package.sh` tarball).
2. **Install** — placing files into system paths (`/etc`, `/usr/local/sbin`,
   `/etc/systemd/system`) with correct owner and mode.

Git can improve transport, but it does **not** replace the install step: systemd
looks for units under `/etc/systemd/system`, the binary under
`/usr/local/sbin`, etc. The running artifacts must live in system paths, not be
executed from a checkout. So the real ergonomic win is a single idempotent
installer script, delivered over git (with a tarball fallback for air-gapped
hosts).

## Decisions (from brainstorming)

- **Server has GitHub access** → git clone is a viable transport, with the
  `package.sh` tarball kept as the air-gapped fallback.
- **Version pinning: tags/releases** → the installer runs against a checked-out
  tag, not the tip of `main`. First release tag: `v2.0.0`.
- **Structure: `install.sh` + `uninstall.sh`** bash scripts (no `make`
  dependency, matches the existing `package.sh` idiom).
- **Scope includes** all four: `install.sh`, `uninstall.sh`, first release tag,
  and the README rewrite.

## Components (all in `jasper-watchdog-v2/`)

### `install.sh`

Idempotent installer. Runs as root, from its own directory, and must **not**
depend on git — it works identically from a git checkout or an extracted
tarball. Behavior:

1. Resolve its own directory (`SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`) so
   the working directory does not matter.
2. Require root (`EUID == 0`), unless `DESTDIR` is set for a staged/test install
   (see Testing). Exit non-zero with a clear message otherwise.
3. Verify every expected source file exists next to the script before touching
   the system; abort if any is missing.
4. Create directories: `/etc/jasper-watchdog` (0750 root:root) and
   `/var/log/jasper-watchdog/incidents` (0700 root:root).
5. Install the **managed artifacts**, always overwriting them:
   - `jasper-watchdog-v2.sh` → `/usr/local/sbin/jasper-watchdog-v2` (0700)
   - `jasper-watchdog.service` → `/etc/systemd/system/` (0644)
   - `jasper-watchdog.timer` → `/etc/systemd/system/` (0644)
   - `logrotate-jasper-watchdog` → `/etc/logrotate.d/jasper-watchdog` (0644)
   - `tmpfiles-jasper-watchdog.conf` → `/etc/tmpfiles.d/jasper-watchdog.conf` (0644)
6. **Config preservation**: install `jasper-watchdog.conf.example` to
   `/etc/jasper-watchdog/jasper-watchdog.conf` (0600) **only if it does not
   already exist**. Always (re)install the example alongside it as
   `/etc/jasper-watchdog/jasper-watchdog.conf.example` (0600) so operators can
   diff new options after an update.
7. **Never touch `pgpass`** — it holds a password and must be created by hand.
8. Run `systemctl daemon-reload` and `systemd-tmpfiles --create
   /etc/tmpfiles.d/jasper-watchdog.conf`.
9. **Do not enable or start the timer.** Enabling is the operator's explicit
   "go to production" decision and is printed as a next step. On an update the
   timer is already enabled and picks up the new binary on the next tick, so no
   restart is needed.
10. Print the post-install configuration guidance (below).

**Idempotency**: running twice yields the same result; managed artifacts are
overwritten, `conf`/`pgpass` are never clobbered, the timer is left untouched.

### Post-install configuration guidance

`install.sh` ends with a **state-aware** checklist (not a generic dump),
reporting exactly what still needs attention:

- **`/etc/jasper-watchdog/jasper-watchdog.conf`** (required):
  - If just created from the example → warn "this is the example config, you
    MUST edit these values" and list the required keys `HEALTH_URL`,
    `JASPER_SERVICE`, `JASPER_LOG_DIR`, then the optional ones
    `HEALTH_BODY_MARKER`, `SLOW_RESPONSE_THRESHOLD_SEC`, `ALERT_COMMAND`,
    `MAX_AUTORESTARTS`, `RESTART_WINDOW_SEC`.
  - If preserved (already existed) → "kept your existing config; review new
    options in `jasper-watchdog.conf.example`".
- **`/etc/jasper-watchdog/pgpass`** (required):
  - Missing → mark `MISSING` and print the exact create command and the
    `host:port:database:user:password` line format.
  - Present but not mode `0600` → warn about the permissions.
- Final line: the command to go live —
  `sudo systemctl enable --now jasper-watchdog.timer`.

Detections are limited to what can be reported with confidence (file existence,
file mode, whether the conf was just created vs. preserved). It does **not**
try to guess whether individual values are "still defaults", to avoid false
positives. Runtime validation of required values remains the watchdog script's
responsibility on execution.

### `uninstall.sh`

Runs as root. Behavior:

1. `systemctl disable --now jasper-watchdog.timer` (ignore if absent).
2. Remove the managed artifacts: `/usr/local/sbin/jasper-watchdog-v2`, both
   systemd units, `/etc/logrotate.d/jasper-watchdog`,
   `/etc/tmpfiles.d/jasper-watchdog.conf`.
3. `systemctl daemon-reload`.
4. **Preserve by default** `/etc/jasper-watchdog` (config) and
   `/var/log/jasper-watchdog` (forensic incident evidence) — never delete
   incidents automatically. Print what was kept.
5. `--purge` flag additionally removes `/etc/jasper-watchdog` and
   `/var/log/jasper-watchdog`, with the removal clearly announced.

### Release tag `v2.0.0`

Create an annotated tag `v2.0.0` and push it, so the installer has a pinned
version to check out. **The tag is created after the repository cleanup below**,
so it points at a clean tree (no v1, no process scaffolding).

### README rewrite (`jasper-watchdog-v2/README.md`)

Replace section 3 "Install" with:

- **3.1 Get the files** — Option 1 (git, recommended): clone into
  `/opt/jasper-watchdog`, `git checkout v2.0.0`. Option 2 (air-gapped):
  `package.sh` tarball → scp → extract.
- **3.2 Install** — `cd jasper-watchdog-v2 && sudo ./install.sh`.
- **3.3 Configure** — edit `jasper-watchdog.conf`, create `pgpass` (existing
  content), guided by the installer's checklist output.
- **3.4 Enable** — `sudo systemctl enable --now jasper-watchdog.timer`.
- **Updating** subsection — `git fetch --tags` → `checkout vX.Y.Z` → re-run
  `install.sh` (config preserved).
- **Uninstall** note — pointing to `uninstall.sh` and `--purge`.

### Root `README.md` cleanup

The repository-root `README.md` is a stale, diverged copy of the v2 README
(missing the circuit breaker, cron/session capture, and `HEALTH_BODY_MARKER`
sections). Replace it with a short pointer to `jasper-watchdog-v2/` and a
one-line description of the project. It no longer references v1 (removed below).

## Repository cleanup

The repository is public; the goal is the smallest, cleanest tree possible with
no process scaffolding or dead versions. Cleanup is done **forward-only** (`git
rm` + commit) — history is not rewritten. All of it lands before the `v2.0.0`
tag so the tag points at the clean tree.

- **Remove v1**: delete `jasper-watchdog-v1/` (a Spanish operational runbook).
  It remains recoverable from git history. Its one durable insight — the real
  incident root cause (a 13:00 cron job sending a shutdown to Tomcat's shutdown
  port) — is already embodied in v2's cron/session evidence capture, so no
  knowledge is lost from the product itself.
- **Drop the process-scaffolding path**: relocate the three design docs to a
  flat `docs/` directory (this installer spec, the hardening design spec, and
  the hardening plan), and remove the now empty nested tree they came from.
  The installer plan produced next also goes in `docs/`.
- **Untrack tooling config**: `git rm --cached .claude/settings.json` and ignore
  `.claude/` in `.gitignore` (consistent with the already-ignored
  `settings.local.json`). Also add the untracked local process-scaffolding
  directory to `.gitignore` so it can never be committed.
- **Duplicates**: none remain beyond the root README addressed above (confirmed
  via `git ls-files`; the root-level duplicate script/tarball were removed in an
  earlier commit).

## Testing

- `install.sh` supports a **`DESTDIR`** prefix (standard staged-install
  convention): every target path is prefixed with `$DESTDIR`, and ownership
  changes (`chown`/`-o`/`-g`) are skipped when not running as root. This makes
  the installer testable without root and without touching the real system.
- New `tests/test_install.bats` covering the two highest-value behaviors:
  1. A clean staged install places every managed artifact at its expected path
     with the expected mode, and creates the config from the example.
  2. A second run **preserves** a pre-seeded `jasper-watchdog.conf` (does not
     overwrite operator edits).
- Add `bash -n install.sh uninstall.sh` to the README validation section.

## Packaging

Verify `package.sh` includes `install.sh` and `uninstall.sh` in the tarball
(it packages the directory, so new files should be included — confirm during
implementation). The same `install.sh` runs from the extracted tarball, giving
air-gapped hosts an identical install experience.

## Out of scope

- A `jasper-watchdog-ctl` multi-command tool (rejected in favor of two focused
  scripts).
- A `Makefile` (would add a `make` dependency on the host).
- Embedding/reporting a version string in the installed binary (the git tag is
  the source of truth; the operator knows what they checked out).
- Automated remote/fleet deployment (Ansible, etc.).
