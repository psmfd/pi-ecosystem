#!/usr/bin/env bash
#
# log.sh — structured output helpers (script-output-conventions).
#
# Sourced by build scripts. Defined inline (not shared from a framework lib)
# because this repo is standalone. Owns LOG_ERROR_COUNT / LOG_WARN_COUNT,
# is bash-3.2 safe, and never sets shell options (the caller owns them).

: "${LOG_ERROR_COUNT:=0}"
: "${LOG_WARN_COUNT:=0}"

ok()     { printf 'OK    [%s] %s\n' "$1" "$2"; }
skip()   { printf 'SKIP  [%s] %s\n' "$1" "$2"; }
warn()   { printf 'WARN  [%s] %s\n' "$1" "$2" >&2; LOG_WARN_COUNT=$((LOG_WARN_COUNT + 1)); }
info()   { printf 'INFO  %s\n' "$*"; }
err()    { printf 'ERROR [%s] %s\n' "$1" "$2" >&2; LOG_ERROR_COUNT=$((LOG_ERROR_COUNT + 1)); }
detail() { [ "${VERBOSE:-0}" = "1" ] && printf '      %s\n' "$*" || true; }
fatal()  { err "$1" "$2"; exit 1; }

print_summary() {
  printf '==================================\n'
  if [ "$LOG_ERROR_COUNT" -eq 0 ]; then
    printf 'PASS — %d errors, %d warnings\n' "$LOG_ERROR_COUNT" "$LOG_WARN_COUNT"
  else
    printf 'FAIL — %d errors, %d warnings\n' "$LOG_ERROR_COUNT" "$LOG_WARN_COUNT"
  fi
}
