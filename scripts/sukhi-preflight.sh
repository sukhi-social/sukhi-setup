#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Validate the host-side, non-secret contract before Quadlet is applied.
set -euo pipefail

etc_dir="${SUKHI_ETC_DIR:-/etc/sukhi}"
quadlet_dir="${QUADLET_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd}"
infra_dir="${INFRA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/sukhi-infra}"
failures=0

fail() {
  printf 'preflight: FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

check_instance_config() {
  local config="${SUKHI_INSTANCE_CONFIG:-$etc_dir/instance.json}"
  [ -f "$config" ] || { fail "missing instance config: $config"; return; }
  [ -s "$config" ] || fail "instance config is empty: $config"
  if command -v ruby >/dev/null 2>&1; then
    ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$config" 2>/dev/null ||
      fail "instance config is not valid JSON: $config"
  fi
}

check_domain_placeholders() {
  local file
  while IFS= read -r -d '' file; do
    if grep -Eiq '(^|[=:/_-])(change[-_ ]?me|([[:alnum:]_-]+\.)?invalid|example\.com|your[-_ ]?domain|<domain>)([[:space:]]|$|["'\''])' "$file"; then
      fail "placeholder DOMAIN/config value in $file"
    fi
  done < <(find "$quadlet_dir" -type f -print0 2>/dev/null)
}

check_release() {
  [ -d "$infra_dir/.git" ] || { fail "infra checkout is missing: $infra_dir"; return; }
  command -v git >/dev/null 2>&1 || { fail "git is required to inspect the infra release"; return; }
  git -C "$infra_dir" diff --quiet || fail "infra checkout has uncommitted changes: $infra_dir"
  git -C "$infra_dir" diff --cached --quiet || fail "infra checkout has staged changes: $infra_dir"
  [ -n "$(git -C "$infra_dir" rev-parse --verify HEAD 2>/dev/null)" ] ||
    fail "infra checkout has no checked-out revision: $infra_dir"
}

check_rootless() {
  [ "$(id -u)" -ne 0 ] || { fail "Podman preflight must run as sukhi, not root"; return; }
  if command -v podman >/dev/null 2>&1; then
    local rootless
    rootless="$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)"
    [ "$rootless" = true ] || fail "Podman is not rootless; run this as sukhi with its user service"
  fi
}

check_instance_config
check_release
check_rootless
check_domain_placeholders

if [ "$failures" -ne 0 ]; then
  printf 'preflight: %s check(s) failed.\n' "$failures" >&2
  printf 'next: fix the reported item, then rerun as sukhi: %s\n' "$(basename "$0")" >&2
  printf 'existing secrets and volumes were not changed.\n' >&2
  exit 2
fi

printf 'preflight: OK (root-owned config, infra release, rootless Podman checks passed)\n'
