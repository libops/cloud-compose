#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
backup_script="$repo_root/rootfs/home/cloud-compose/mariadb-backup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  echo "backup contract: $*" >&2
  exit 1
}

mkdir -p "$tmp/bin"
cat >"$tmp/profile.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export PATH="${TEST_BIN:?}:/usr/bin:/bin"
acquire_cloud_compose_lifecycle_lock() {
  printf '%s\n' "$1" >>"${LOCK_LOG:?}"
}
EOF
cat >"$tmp/compose-apps.sh" <<'EOF'
#!/usr/bin/env bash
compose_app_names_array() {
  local -n result="$1"
  result=(alpha)
}
source_compose_app_env() {
  SITECTL_CONTEXT_NAME="$1-context"
  export SITECTL_CONTEXT_NAME
}
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "is-active" && "${FAKE_APP_ACTIVE:-true}" == "true" ]]
EOF
cat >"$tmp/bin/sitectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (($# > 0)); do
  if [[ "$1" == "--output" ]]; then
    output="$2"
    shift 2
    continue
  fi
  shift
done
[[ -n "$output" ]]
printf 'CALL\n' >>"${SITECTL_LOG:?}"
case "${FAKE_BACKUP_MODE:-success}" in
  success) printf 'SQL backup\n' | gzip -c >"$output" ;;
  partial) printf 'not gzip\n' >"$output"; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/systemctl" "$tmp/bin/sitectl"

export TEST_BIN="$tmp/bin"
export LOCK_LOG="$tmp/lock.log"
export SITECTL_LOG="$tmp/sitectl.log"
export CLOUD_COMPOSE_PROFILE_PATH="$tmp/profile.sh"
export CLOUD_COMPOSE_COMPOSE_APPS_PATH="$tmp/compose-apps.sh"
export MARIADB_BACKUP_ROOT="$tmp/backups"
: >"$LOCK_LOG"
: >"$SITECTL_LOG"

FAKE_APP_ACTIVE=false bash "$backup_script"
[[ ! -s "$SITECTL_LOG" ]] || fail "inactive application was backed up or started"
grep -Fxq mariadb-backup "$LOCK_LOG" || fail "backup did not acquire the shared lifecycle lock"

: >"$LOCK_LOG"
FAKE_APP_ACTIVE=true bash "$backup_script"
backup="$(find "$MARIADB_BACKUP_ROOT/alpha" -maxdepth 1 -type f -name '*.sql.gz' -print -quit)"
[[ -n "$backup" && -s "$backup" ]] || fail "valid backup was not published"
gzip -t -- "$backup" || fail "published backup is not valid gzip"
[[ "$(find "$MARIADB_BACKUP_ROOT/alpha" -maxdepth 1 -type d -name '*.staging.*' | wc -l)" == 0 ]] || \
  fail "successful backup retained staging data"

calls_before="$(wc -l <"$SITECTL_LOG")"
FAKE_APP_ACTIVE=true bash "$backup_script"
[[ "$(wc -l <"$SITECTL_LOG")" == "$calls_before" ]] || fail "validated existing backup was regenerated"

rm -f -- "$backup"
if FAKE_APP_ACTIVE=true FAKE_BACKUP_MODE=partial bash "$backup_script" >/dev/null 2>&1; then
  fail "partial backup command was accepted"
fi
[[ -z "$(find "$MARIADB_BACKUP_ROOT/alpha" -maxdepth 1 -type f -name '*.sql.gz' -print -quit)" ]] || \
  fail "partial backup was published as final"
[[ "$(find "$MARIADB_BACKUP_ROOT/alpha" -maxdepth 1 -type d -name '*.staging.*' | wc -l)" == 0 ]] || \
  fail "failed backup retained staging data"

printf 'corrupt\n' >"$MARIADB_BACKUP_ROOT/alpha/$(date -u +%Y%m%d)-alpha.sql.gz"
if FAKE_APP_ACTIVE=true bash "$backup_script" >/dev/null 2>&1; then
  fail "corrupt existing backup was treated as complete"
fi

echo "Backup contract passed"
