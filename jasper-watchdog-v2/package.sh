#!/usr/bin/env bash
# Builds a distributable tarball of jasper-watchdog-v2 on demand.
# The tarball itself is not committed to git (see .gitignore).
set -euo pipefail
cd "$(dirname "$0")"

tar -czf ../jasper-watchdog-v2.tar.gz \
  jasper-watchdog-v2.sh \
  jasper-watchdog.conf.example \
  jasper-watchdog.service \
  jasper-watchdog.timer \
  logrotate-jasper-watchdog \
  postgres-watchdog-role.sql \
  tmpfiles-jasper-watchdog.conf \
  README.md \
  tests

echo "Built ../jasper-watchdog-v2.tar.gz"
