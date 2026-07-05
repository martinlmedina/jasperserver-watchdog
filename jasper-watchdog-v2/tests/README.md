# jasper-watchdog-v2 tests

Unit tests use [bats-core](https://github.com/bats-core/bats-core).

## Install bats-core

- Debian/Ubuntu: `sudo apt-get install bats`
- macOS (Homebrew): `brew install bats-core`
- Any platform via npm: `npm install -g bats`
- From source: `git clone https://github.com/bats-core/bats-core.git && cd bats-core && sudo ./install.sh /usr/local`

## Run the suite

From `jasper-watchdog-v2/`:

    bats tests/

Each `*.bats` file sources `jasper-watchdog-v2.sh` directly. The script guards its
`main` entry point behind `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]`, so sourcing it
only defines functions — no real JasperServer, PostgreSQL, or systemd is touched.
External commands (`curl`, `crontab`, `ss`, `last`, `who`) are stubbed by fixture
scripts under `tests/fixtures/`, which are prepended to `PATH` in each test's
`setup()`.
