# JasperServer Watchdog v2 Installer Implementation Plan

**Goal:** Replace the manual six-command install with an idempotent `install.sh` + `uninstall.sh`, delivered over a pinned git tag (tarball fallback), and leave the public repo minimal (no v1, no process scaffolding).

**Architecture:** Two bash scripts placed next to `package.sh`. `install.sh` copies managed artifacts into system paths, preserves existing config, prints a state-aware config checklist, and never enables the timer (explicit operator step). `uninstall.sh` reverses it, preserving config/evidence unless `--purge`. Both work from a git checkout or extracted tarball and support a `DESTDIR` prefix for root-free staged testing. A repository cleanup pass and a `v2.0.0` tag close it out.

**Tech Stack:** Bash, GNU coreutils `install(1)`, systemd, bats-core.

## Global Constraints

- Scripts are bash, no new host dependencies (no `make`), matching the `package.sh` idiom.
- `install.sh`/`uninstall.sh` must NOT depend on git — they run identically from a git checkout or an extracted tarball.
- `install.sh` is idempotent: managed artifacts are always overwritten; `jasper-watchdog.conf` and `pgpass` are NEVER clobbered; the timer is NEVER enabled or started.
- Require root when installing for real; when `DESTDIR` is set, skip ownership changes and allow non-root (staged/test install).
- Managed artifact modes are exact: binary `0700`, systemd units `0644`, logrotate `0644`, tmpfiles `0644`, config `0600`; dirs `/etc/jasper-watchdog` `0750`, incidents `0700`.
- Cleanup is forward-only (`git rm` + commit); history is NOT rewritten.
- The repo is public: no `jasper-watchdog-v1/`, no process-scaffolding path or references in tracked files, no tracked tooling config.
- The `v2.0.0` tag is created LAST, after the tree is clean.
- Repo: `martinlmedina/jasperserver-watchdog`, branch `main`, remote `origin`.

---

### Task 1: `install.sh` + staged install test

**Files:**
- Create: `jasper-watchdog-v2/install.sh`
- Test: `jasper-watchdog-v2/tests/test_install.bats`

**Interfaces:**
- Consumes: the existing artifacts in `jasper-watchdog-v2/` (`jasper-watchdog-v2.sh`, `jasper-watchdog.conf.example`, `jasper-watchdog.service`, `jasper-watchdog.timer`, `logrotate-jasper-watchdog`, `tmpfiles-jasper-watchdog.conf`).
- Produces: `install.sh`, runnable as `sudo ./install.sh` or `DESTDIR=<dir> bash install.sh`. No functions are sourced by other tasks.

- [ ] **Step 1: Write the failing test**

Create `jasper-watchdog-v2/tests/test_install.bats`:

```bash
#!/usr/bin/env bats

setup() {
  STAGE="$(mktemp -d)"
  export DESTDIR="$STAGE"
  INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
}

teardown() {
  unset DESTDIR
  rm -rf "$STAGE"
}

@test "clean install places all managed artifacts" {
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  [ -f "$STAGE/usr/local/sbin/jasper-watchdog-v2" ]
  [ -f "$STAGE/etc/systemd/system/jasper-watchdog.service" ]
  [ -f "$STAGE/etc/systemd/system/jasper-watchdog.timer" ]
  [ -f "$STAGE/etc/logrotate.d/jasper-watchdog" ]
  [ -f "$STAGE/etc/tmpfiles.d/jasper-watchdog.conf" ]
  [ -f "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf" ]
  [ -f "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf.example" ]
}

@test "installed binary is not world-accessible" {
  bash "$INSTALLER"
  mode="$(stat -c '%a' "$STAGE/usr/local/sbin/jasper-watchdog-v2" 2>/dev/null || echo skip)"
  if [ "$mode" = "skip" ]; then skip "stat -c unsupported here"; fi
  [ "$mode" = "700" ]
}

@test "re-install preserves an existing config" {
  bash "$INSTALLER"
  printf 'CUSTOM_EDIT=1\n' >> "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf"
  run bash "$INSTALLER"
  [ "$status" -eq 0 ]
  run grep -q 'CUSTOM_EDIT=1' "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd jasper-watchdog-v2 && bats tests/test_install.bats`
Expected: FAIL — `install.sh` does not exist yet (`bash: install.sh: No such file or directory`).

- [ ] **Step 3: Write `install.sh`**

Create `jasper-watchdog-v2/install.sh`:

```bash
#!/usr/bin/env bash
# Idempotent installer for jasper-watchdog-v2.
#
# Places managed artifacts into system paths, preserves existing config and
# pgpass, and prints a state-aware configuration checklist. Works from a git
# checkout or an extracted tarball; does not depend on git. Does NOT enable the
# timer — that is the operator's explicit go-live step.
#
# Usage:
#   sudo ./install.sh
#   DESTDIR=/tmp/stage bash install.sh   # staged/test install, no root needed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTDIR="${DESTDIR:-}"

# Ownership is only enforced on a real root install. Under DESTDIR (staging or
# tests) we skip chown so the script runs unprivileged.
own=()
if [[ -n "$DESTDIR" ]]; then
  own=()
elif [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  own=(-o root -g root)
else
  echo "ERROR: run as root, or set DESTDIR for a staged install." >&2
  exit 1
fi

etc_dir="$DESTDIR/etc/jasper-watchdog"
sbin_dir="$DESTDIR/usr/local/sbin"
systemd_dir="$DESTDIR/etc/systemd/system"
logrotate_dir="$DESTDIR/etc/logrotate.d"
tmpfiles_dir="$DESTDIR/etc/tmpfiles.d"
incident_dir="$DESTDIR/var/log/jasper-watchdog/incidents"

# Verify every source artifact exists before touching the system.
required_sources=(
  jasper-watchdog-v2.sh
  jasper-watchdog.conf.example
  jasper-watchdog.service
  jasper-watchdog.timer
  logrotate-jasper-watchdog
  tmpfiles-jasper-watchdog.conf
)
for f in "${required_sources[@]}"; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    echo "ERROR: missing source file: $f" >&2
    exit 1
  fi
done

# Owned directories (mode enforced).
install -d -m 0750 "${own[@]}" "$etc_dir"
install -d -m 0700 "${own[@]}" "$incident_dir"

# Standard system directories: create only when staging (they exist on a real
# host, and we must not alter their mode).
if [[ -n "$DESTDIR" ]]; then
  install -d "$sbin_dir" "$systemd_dir" "$logrotate_dir" "$tmpfiles_dir"
fi

# Managed artifacts — always overwritten.
install -m 0700 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog-v2.sh"         "$sbin_dir/jasper-watchdog-v2"
install -m 0644 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog.service"       "$systemd_dir/jasper-watchdog.service"
install -m 0644 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog.timer"         "$systemd_dir/jasper-watchdog.timer"
install -m 0644 "${own[@]}" "$SCRIPT_DIR/logrotate-jasper-watchdog"     "$logrotate_dir/jasper-watchdog"
install -m 0644 "${own[@]}" "$SCRIPT_DIR/tmpfiles-jasper-watchdog.conf" "$tmpfiles_dir/jasper-watchdog.conf"

# Config: create from the example only if absent; never clobber operator edits.
conf="$etc_dir/jasper-watchdog.conf"
conf_created=0
if [[ -e "$conf" ]]; then
  echo "Preserved existing config: /etc/jasper-watchdog/jasper-watchdog.conf"
else
  install -m 0600 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog.conf.example" "$conf"
  conf_created=1
fi
# Always refresh the example alongside it so operators can diff new options.
install -m 0600 "${own[@]}" "$SCRIPT_DIR/jasper-watchdog.conf.example" "$etc_dir/jasper-watchdog.conf.example"

# Reload systemd only on a real install.
if [[ -z "$DESTDIR" ]]; then
  systemctl daemon-reload
  systemd-tmpfiles --create /etc/tmpfiles.d/jasper-watchdog.conf
fi

# ---- State-aware configuration checklist ----
pgpass="$etc_dir/pgpass"
echo
echo "== Configuration required =="
if [[ "$conf_created" -eq 1 ]]; then
  echo "[!] jasper-watchdog.conf was created from the example. You MUST edit these"
  echo "    required values before enabling:"
  echo "      HEALTH_URL      - endpoint that proves JasperServer is alive"
  echo "      JASPER_SERVICE  - the actual systemd service name"
  echo "      JASPER_LOG_DIR  - the Tomcat/Jasper logs directory"
  echo "    Optional: HEALTH_BODY_MARKER, SLOW_RESPONSE_THRESHOLD_SEC,"
  echo "              ALERT_COMMAND, MAX_AUTORESTARTS, RESTART_WINDOW_SEC"
else
  echo "[ok] Kept existing jasper-watchdog.conf."
  echo "     Review new options in /etc/jasper-watchdog/jasper-watchdog.conf.example"
fi
echo
if [[ ! -e "$pgpass" ]]; then
  echo "[MISSING] /etc/jasper-watchdog/pgpass - create it (format host:port:database:user:password):"
  echo "    sudo sh -c 'umask 077; printf \"127.0.0.1:5432:jasperserver:jasper_watchdog:PASSWORD\\n\" > /etc/jasper-watchdog/pgpass'"
else
  mode="$(stat -c '%a' "$pgpass" 2>/dev/null || echo '')"
  if [[ -n "$mode" && "$mode" != "600" ]]; then
    echo "[warn] /etc/jasper-watchdog/pgpass mode is $mode; expected 600."
  else
    echo "[ok] /etc/jasper-watchdog/pgpass present."
  fi
fi
echo
echo "When configured, go live with:"
echo "    sudo systemctl enable --now jasper-watchdog.timer"
```

- [ ] **Step 4: Make it executable with the tracked mode**

The repo has `core.filemode=false`, so a filesystem `chmod` alone is not recorded.

Run:
```bash
chmod +x jasper-watchdog-v2/install.sh
git add jasper-watchdog-v2/install.sh jasper-watchdog-v2/tests/test_install.bats
git update-index --chmod=+x jasper-watchdog-v2/install.sh
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd jasper-watchdog-v2 && bats tests/test_install.bats`
Expected: PASS — 3 tests ok (the mode test may report `skip` if `stat -c` is unavailable, which still counts as passing).

- [ ] **Step 6: Run the full suite to confirm no regressions**

Run: `cd jasper-watchdog-v2 && bats tests/`
Expected: all tests pass (the prior 15 plus the new install tests).

- [ ] **Step 7: Commit**

```bash
git commit -m "feat: add idempotent install.sh with staged-install tests"
```

---

### Task 2: `uninstall.sh` + test, and package the new scripts

**Files:**
- Create: `jasper-watchdog-v2/uninstall.sh`
- Create: `jasper-watchdog-v2/tests/test_uninstall.bats`
- Modify: `jasper-watchdog-v2/package.sh`

**Interfaces:**
- Consumes: the layout produced by `install.sh` (Task 1), addressed via the same `DESTDIR` prefix.
- Produces: `uninstall.sh`, runnable as `sudo ./uninstall.sh [--purge]`.

- [ ] **Step 1: Write the failing test**

Create `jasper-watchdog-v2/tests/test_uninstall.bats`:

```bash
#!/usr/bin/env bats

setup() {
  STAGE="$(mktemp -d)"
  export DESTDIR="$STAGE"
  INSTALLER="$BATS_TEST_DIRNAME/../install.sh"
  UNINSTALLER="$BATS_TEST_DIRNAME/../uninstall.sh"
  bash "$INSTALLER"
}

teardown() {
  unset DESTDIR
  rm -rf "$STAGE"
}

@test "uninstall removes managed artifacts but keeps config by default" {
  run bash "$UNINSTALLER"
  [ "$status" -eq 0 ]
  [ ! -f "$STAGE/usr/local/sbin/jasper-watchdog-v2" ]
  [ ! -f "$STAGE/etc/systemd/system/jasper-watchdog.service" ]
  [ ! -f "$STAGE/etc/systemd/system/jasper-watchdog.timer" ]
  [ ! -f "$STAGE/etc/logrotate.d/jasper-watchdog" ]
  [ ! -f "$STAGE/etc/tmpfiles.d/jasper-watchdog.conf" ]
  # Config and incident evidence are preserved.
  [ -f "$STAGE/etc/jasper-watchdog/jasper-watchdog.conf" ]
  [ -d "$STAGE/var/log/jasper-watchdog/incidents" ]
}

@test "uninstall --purge also removes config and evidence" {
  run bash "$UNINSTALLER" --purge
  [ "$status" -eq 0 ]
  [ ! -d "$STAGE/etc/jasper-watchdog" ]
  [ ! -d "$STAGE/var/log/jasper-watchdog" ]
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd jasper-watchdog-v2 && bats tests/test_uninstall.bats`
Expected: FAIL — `uninstall.sh` does not exist yet.

- [ ] **Step 3: Write `uninstall.sh`**

Create `jasper-watchdog-v2/uninstall.sh`:

```bash
#!/usr/bin/env bash
# Removes jasper-watchdog-v2's managed artifacts.
#
# Preserves /etc/jasper-watchdog (config) and /var/log/jasper-watchdog
# (forensic incident evidence) by default. Pass --purge to remove those too.
# Works from a git checkout or an extracted tarball; supports DESTDIR for
# staged/test runs.
#
# Usage:
#   sudo ./uninstall.sh
#   sudo ./uninstall.sh --purge
set -euo pipefail

DESTDIR="${DESTDIR:-}"
purge=0
if [[ "${1:-}" == "--purge" ]]; then
  purge=1
elif [[ -n "${1:-}" ]]; then
  echo "ERROR: unknown argument: $1 (only --purge is supported)" >&2
  exit 1
fi

if [[ -z "$DESTDIR" && "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: run as root, or set DESTDIR for a staged uninstall." >&2
  exit 1
fi

# Stop and disable the timer on a real system.
if [[ -z "$DESTDIR" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now jasper-watchdog.timer 2>/dev/null || true
fi

rm -f "$DESTDIR/usr/local/sbin/jasper-watchdog-v2"
rm -f "$DESTDIR/etc/systemd/system/jasper-watchdog.service"
rm -f "$DESTDIR/etc/systemd/system/jasper-watchdog.timer"
rm -f "$DESTDIR/etc/logrotate.d/jasper-watchdog"
rm -f "$DESTDIR/etc/tmpfiles.d/jasper-watchdog.conf"

if [[ -z "$DESTDIR" ]] && command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
fi

if [[ "$purge" -eq 1 ]]; then
  rm -rf "$DESTDIR/etc/jasper-watchdog"
  rm -rf "$DESTDIR/var/log/jasper-watchdog"
  echo "Removed managed artifacts, config, and incident evidence."
else
  echo "Removed managed artifacts."
  echo "Kept /etc/jasper-watchdog (config) and /var/log/jasper-watchdog (incidents)."
  echo "Re-run with --purge to remove those too."
fi
```

- [ ] **Step 4: Make it executable with the tracked mode**

```bash
chmod +x jasper-watchdog-v2/uninstall.sh
git add jasper-watchdog-v2/uninstall.sh jasper-watchdog-v2/tests/test_uninstall.bats
git update-index --chmod=+x jasper-watchdog-v2/uninstall.sh
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd jasper-watchdog-v2 && bats tests/test_uninstall.bats`
Expected: PASS — 2 tests ok.

- [ ] **Step 6: Add both scripts to the tarball**

Edit `jasper-watchdog-v2/package.sh`. Change the `tar` file list to include the two new scripts:

```bash
tar -czf ../jasper-watchdog-v2.tar.gz \
  jasper-watchdog-v2.sh \
  install.sh \
  uninstall.sh \
  jasper-watchdog.conf.example \
  jasper-watchdog.service \
  jasper-watchdog.timer \
  logrotate-jasper-watchdog \
  postgres-watchdog-role.sql \
  tmpfiles-jasper-watchdog.conf \
  README.md \
  tests
```

- [ ] **Step 7: Verify the tarball contains the scripts**

Run: `cd jasper-watchdog-v2 && ./package.sh && tar -tzf ../jasper-watchdog-v2.tar.gz | grep -E 'install.sh|uninstall.sh'`
Expected: both `install.sh` and `uninstall.sh` are listed. (The tarball itself is gitignored.)

- [ ] **Step 8: Commit**

```bash
git add jasper-watchdog-v2/package.sh
git commit -m "feat: add uninstall.sh and include both installers in the tarball"
```

---

### Task 3: Rewrite the install docs

**Files:**
- Modify: `jasper-watchdog-v2/README.md` (section 3 and add Updating/Uninstall)
- Modify: `README.md` (repository root → short pointer)

**Interfaces:**
- Consumes: `install.sh`/`uninstall.sh` behavior from Tasks 1–2, and the `v2.0.0` tag name (created in Task 5).
- Produces: no code; documentation only.

- [ ] **Step 1: Replace section 3 of `jasper-watchdog-v2/README.md`**

Replace the entire current `## 3. Install` block (from `## 3. Install` up to, but not including, `## 4. What PostgreSQL evidence is captured`) with:

````markdown
## 3. Install

### 3.1 Get the files

Option 1 — git (recommended, when the server can reach GitHub):

```bash
sudo git clone https://github.com/martinlmedina/jasperserver-watchdog.git /opt/jasper-watchdog
sudo git -C /opt/jasper-watchdog checkout v2.0.0
cd /opt/jasper-watchdog/jasper-watchdog-v2
```

Option 2 — air-gapped: on any machine with the repo, run `./package.sh` to build
`jasper-watchdog-v2.tar.gz`, copy it to the server, extract it, and `cd` into it:

```bash
scp jasper-watchdog-v2.tar.gz root@server:/root/
ssh root@server 'tar -xzf /root/jasper-watchdog-v2.tar.gz -C /root/'
cd /root/jasper-watchdog-v2
```

### 3.2 Run the installer

```bash
sudo ./install.sh
```

The installer is idempotent. It places the binary, systemd units, logrotate and
tmpfiles configuration into their system paths, creates the config from the
example only if it does not already exist, never touches `pgpass`, reloads
systemd, and prints a configuration checklist. It does **not** enable the timer —
that is the explicit go-live step in 3.4.

### 3.3 Configure

Edit `/etc/jasper-watchdog/jasper-watchdog.conf` and validate these values
against the server:

- `HEALTH_URL`: a JasperServer endpoint that proves the application is alive. Do not leave a mere port check as the only health condition. Optionally set `HEALTH_BODY_MARKER` to a string that must appear in the response body, and `SLOW_RESPONSE_THRESHOLD_SEC` to treat a slow-but-200 response as a failure. Both are unset by default.
- `JASPER_SERVICE`: the actual systemd service name.
- `JASPER_LOG_DIR`: the Tomcat/Jasper logs directory.

Create the password file. The line format is `host:port:database:user:password`:

```bash
sudo sh -c 'umask 077; cat > /etc/jasper-watchdog/pgpass'
# Enter exactly one line, then Ctrl+D:
# 127.0.0.1:5432:jasperserver:jasper_watchdog:REPLACE_WITH_GENERATED_PASSWORD
sudo chmod 0600 /etc/jasper-watchdog/pgpass
sudo chown root:root /etc/jasper-watchdog/pgpass
```

### 3.4 Enable the timer

```bash
sudo systemctl enable --now jasper-watchdog.timer
systemctl list-timers jasper-watchdog.timer
```

A systemd `.timer` unit activates the accompanying `.service` according to the configured timing schedule; the service performs a single monitor execution.

### 3.5 Updating

```bash
sudo git -C /opt/jasper-watchdog fetch --tags
sudo git -C /opt/jasper-watchdog checkout v2.1.0     # the tag you are moving to
sudo /opt/jasper-watchdog/jasper-watchdog-v2/install.sh
```

Your `jasper-watchdog.conf` and incident evidence are preserved. The timer stays
enabled and runs the new binary on its next tick — no restart needed.

### 3.6 Uninstall

```bash
sudo /opt/jasper-watchdog/jasper-watchdog-v2/uninstall.sh          # keeps config + incidents
sudo /opt/jasper-watchdog/jasper-watchdog-v2/uninstall.sh --purge  # also removes them
```
````

- [ ] **Step 2: Add the installer scripts to the validation section**

In `jasper-watchdog-v2/README.md`, in the `## 5. Validation before production` code block, add a syntax check for the new scripts as the first line:

```bash
sudo bash -n install.sh uninstall.sh /usr/local/sbin/jasper-watchdog-v2
```

(Replace the existing lone `sudo bash -n /usr/local/sbin/jasper-watchdog-v2` line.)

- [ ] **Step 3: Replace the root `README.md`**

Overwrite `README.md` (repository root) with:

```markdown
# JasperServer Watchdog

A bash + systemd health monitor for a JasperServer/Tomcat instance. It probes the
application health endpoint and, on a confirmed failure, captures forensic
evidence (OS, JVM thread dump, PostgreSQL activity/locks, cron and login
sessions) **before** restarting the service — with a restart circuit breaker and
an optional alert hook.

Installation and operation: **[jasper-watchdog-v2/README.md](jasper-watchdog-v2/README.md)**.
```

- [ ] **Step 4: Commit**

```bash
git add README.md jasper-watchdog-v2/README.md
git commit -m "docs: rewrite install flow around install.sh and git delivery"
```

---

### Task 4: Repository cleanup

**Files:**
- Delete: `jasper-watchdog-v1/Watchdog_JasperServer_INTDB4_Guia_Tecnica.md` (and the now-empty directory)
- Move: `docs/<scaffold>/specs/2026-07-05-jasper-watchdog-v2-hardening-design.md` → `docs/2026-07-05-jasper-watchdog-v2-hardening-design.md`
- Move: `docs/<scaffold>/specs/2026-07-05-jasper-watchdog-v2-installer-design.md` → `docs/2026-07-05-jasper-watchdog-v2-installer-design.md`
- Move: `docs/<scaffold>/plans/2026-07-05-jasper-watchdog-v2-hardening.md` → `docs/2026-07-05-jasper-watchdog-v2-hardening.md`
- Modify: `.gitignore`
- Untrack: `.claude/settings.json`
- Modify (scrub process-scaffolding references): the relocated docs and this plan file

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: a clean tree for the `v2.0.0` tag in Task 5.

- [ ] **Step 1: Remove v1**

```bash
git rm -r jasper-watchdog-v1
```

- [ ] **Step 2: Relocate the design docs out of the nested process-scaffolding path**

```bash
git mv "docs/<scaffold>/specs/2026-07-05-jasper-watchdog-v2-hardening-design.md" docs/2026-07-05-jasper-watchdog-v2-hardening-design.md
git mv "docs/<scaffold>/specs/2026-07-05-jasper-watchdog-v2-installer-design.md" docs/2026-07-05-jasper-watchdog-v2-installer-design.md
git mv "docs/<scaffold>/plans/2026-07-05-jasper-watchdog-v2-hardening.md" docs/2026-07-05-jasper-watchdog-v2-hardening.md
```

The now-empty nested spec/plan directories are removed automatically by git when their last tracked file moves.

- [ ] **Step 3: Scrub process-scaffolding references from tracked markdown**

Find remaining references (adjust the pattern to whatever the tooling's name was):
```bash
grep -rl "<scaffold>" docs README.md jasper-watchdog-v2/README.md
```

For each hit, remove the reference. The known pattern is the plan header line referencing the sub-skill tooling used to implement plans — delete that entire blockquote line from `docs/2026-07-05-jasper-watchdog-v2-hardening.md` and `docs/2026-07-05-jasper-watchdog-v2-installer.md`. Re-run the grep and confirm it returns nothing:
```bash
grep -rl "<scaffold>" docs README.md jasper-watchdog-v2/README.md ; echo "exit=$?"
```
Expected: no file paths printed (grep exit 1).

- [ ] **Step 4: Untrack tooling config and ignore it**

```bash
git rm --cached .claude/settings.json
```

Replace `.gitignore` contents with:
```gitignore
*.tar.gz
.claude/
.<scaffold>/
```

- [ ] **Step 5: Verify the tree is clean**

Run: `git ls-files | grep -E 'jasper-watchdog-v1|<scaffold>|\.claude'`
Expected: no output (nothing tracked under v1, no process-scaffolding path, no tracked `.claude`).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: slim public repo — drop v1, process scaffolding, and tooling config"
```

---

### Task 5: Release `v2.0.0` and publish

**Files:** none (git operations only).

**Interfaces:**
- Consumes: the clean tree from Task 4 and the working installer from Tasks 1–3.

- [ ] **Step 1: Confirm the full suite passes on the final tree**

Run: `cd jasper-watchdog-v2 && bats tests/`
Expected: all tests pass (20 total: the original 15 + 3 install + 2 uninstall; confirm the printed total and that all are `ok`).

- [ ] **Step 2: Push the branch**

```bash
git push origin main
```

- [ ] **Step 3: Create and push the annotated tag**

```bash
git tag -a v2.0.0 -m "jasper-watchdog v2.0.0: hardened watchdog with idempotent installer"
git push origin v2.0.0
```

- [ ] **Step 4: Verify the release on the remote**

```bash
git ls-remote --tags origin
```
Expected: `refs/tags/v2.0.0` is listed.

---

## Self-Review

**Spec coverage:**
- install.sh (idempotent, config-preserving, no timer enable, DESTDIR, checklist) → Task 1. ✓
- State-aware config guidance → Task 1, Step 3 checklist block. ✓
- uninstall.sh (+ `--purge`, preserve by default) → Task 2. ✓
- DESTDIR testability + test_install.bats (placement + preservation) → Task 1. ✓ (uninstall test added in Task 2 as a quality extra.)
- `bash -n` in validation section → Task 3, Step 2. ✓
- package.sh includes new scripts → Task 2, Step 6. ✓
- README rewrite (git delivery + tarball fallback + updating + uninstall) → Task 3. ✓
- Root README pointer → Task 3, Step 3. ✓
- Remove v1 → Task 4, Step 1. ✓
- Relocate docs out of nested process-scaffolding path → Task 4, Step 2. ✓
- Untrack tooling config → Task 4, Step 4. ✓
- Tag v2.0.0 after cleanup → Task 5. ✓

**Placeholder scan:** No TBD/TODO; all steps contain concrete code or exact commands. ✓

**Type/name consistency:** Artifact names, target paths, and modes are identical across Tasks 1–3 (`jasper-watchdog-v2` binary, `jasper-watchdog.{service,timer}`, `/etc/jasper-watchdog/...`). `DESTDIR` semantics are identical in install.sh, uninstall.sh, and both test files. ✓
