#!/usr/bin/env bash

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-full}"
failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

warn() {
  printf 'WARN: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

require_file() {
  local relative_path="$1"
  if [[ -s "$repo_root/$relative_path" ]]; then
    pass "$relative_path exists and is not empty"
  else
    fail "$relative_path is missing or empty"
  fi
}

contains() {
  local relative_path="$1"
  local pattern="$2"
  grep -Eiq -- "$pattern" "$repo_root/$relative_path"
}

required_files=(
  "README.md"
  "INCIDENT.md"
  "docker-compose.prod.yml"
  "nginx.conf"
  ".gitlab-ci.yml"
  "answers/incident.md"
  "answers/handover.md"
  "answers/AI_USAGE.md"
)

for relative_path in "${required_files[@]}"; do
  require_file "$relative_path"
done

if [[ "$mode" == "--structure-only" ]]; then
  if (( failures > 0 )); then
    exit 1
  fi
  printf '\nRepository structure is complete.\n'
  exit 0
fi

for answer_path in answers/incident.md answers/handover.md answers/AI_USAGE.md; do
  if [[ ! -s "$repo_root/$answer_path" ]]; then
    continue
  elif contains "$answer_path" 'TODO'; then
    fail "$answer_path still contains TODO"
  else
    pass "$answer_path has been filled in"
  fi
done

if [[ -s "$repo_root/answers/handover.md" ]]; then
  handover_words="$(awk '!/^[[:space:]]*(#|>|$)/ { count += NF } END { print count + 0 }' "$repo_root/answers/handover.md")"
  if (( handover_words <= 200 )); then
    pass "answers/handover.md is within the 200-word limit ($handover_words)"
  else
    fail "answers/handover.md exceeds the 200-word limit ($handover_words)"
  fi
fi

if [[ -s "$repo_root/answers/AI_USAGE.md" ]]; then
  ai_content_lines="$(awk '!/^[[:space:]]*(#|>|$)/ { count++ } END { print count + 0 }' "$repo_root/answers/AI_USAGE.md")"
  if (( ai_content_lines <= 10 )); then
    pass "answers/AI_USAGE.md is within the 10-line limit ($ai_content_lines)"
  else
    fail "answers/AI_USAGE.md exceeds the 10-line limit ($ai_content_lines)"
  fi
fi

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if docker compose -f "$repo_root/docker-compose.prod.yml" config --no-interpolate --quiet; then
    pass 'docker compose config accepts docker-compose.prod.yml'
  else
    fail 'docker compose config rejects docker-compose.prod.yml'
  fi
else
  warn 'Docker Compose is unavailable; YAML/runtime validation was skipped'
fi

printf '\nValidation finished with %d failure(s).\n' "$failures"

if (( failures > 0 )); then
  exit 1
fi
