#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 箱の準備のうち root が要る部分(一度だけ。何度流しても同じ結果になる)。
#   sudo scripts/prepare-root.sh <prod|dev> [--infra-dir DIR] [--release REV]
# パッケージは入れない(docs/PREPARE.md の手順で人が入れる)。パスワードも作らない(パスワードマネージャーで作る)。
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
env_name="${1:?usage: $0 <prod|dev> [--infra-dir DIR] [--release REV]}"
case "$env_name" in prod|dev) ;; *) echo "env must be prod or dev" >&2; exit 1 ;; esac
shift
infra_dir="${INFRA_DIR:-/home/sukhi/.local/share/sukhi-infra}"
release="${INFRA_RELEASE:-}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --infra-dir) infra_dir="${2:?--infra-dir needs a path}"; shift 2 ;;
    --release) release="${2:?--release needs a revision}"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done
here=$(cd "$(dirname "$0")/.." && pwd)

# 1. サービスユーザー(既存なら作り直さず検査して再利用)
if id sukhi >/dev/null 2>&1; then
  sukhi_home="$(getent passwd sukhi | cut -d: -f6)"
  [ -n "$sukhi_home" ] && [ -d "$sukhi_home" ] ||
    { echo "sukhi exists but its home directory is missing; repair it before continuing" >&2; exit 1; }
  echo "reuse existing user: sukhi (home=$sukhi_home)"
else
  useradd -m -s /bin/bash sukhi
  sukhi_home="$(getent passwd sukhi | cut -d: -f6)"
  echo "created user: sukhi"
fi
grep -q '^sukhi:' /etc/subuid && grep -q '^sukhi:' /etc/subgid || { echo "sukhi has no subuid/subgid range; fix /etc/subuid /etc/subgid" >&2; exit 1; }

# 2. ログアウトしても user の systemd(timer・コンテナ)が動き続ける
loginctl enable-linger sukhi

# 3. cgroup の委譲(cpu を含める)
install -d -m 755 /etc/systemd/system/user@.service.d
install -m 644 "$here/systemd/system/user@.service.d/delegate.conf" /etc/systemd/system/user@.service.d/delegate.conf
systemctl daemon-reload

# 4. journal の永続化(sukhi の user unit のログを Cockpit / journalctl で読めるように)
install -d -m 2755 /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
usermod -aG systemd-journal sukhi
journalctl --flush || true

# 5. /etc/sukhi: 環境名・設定・署名者の置き場(リポジトリの外。リポジトリを書き換えた人に触れさせない)
install -d -m 755 /etc/sukhi
[ -f /etc/sukhi/env ] || echo "$env_name" >/etc/sukhi/env
[ -f /etc/sukhi/gitops.env ] || install -m 644 "$here/etc/gitops.env.example" /etc/sukhi/gitops.env
[ -f /etc/sukhi/allowed_signers ] || { : >/etc/sukhi/allowed_signers; chmod 644 /etc/sukhi/allowed_signers; }

if [ -e /etc/sukhi/infra ]; then
  [ -L /etc/sukhi/infra ] ||
    { echo "/etc/sukhi/infra is not a symlink; refusing to replace existing data" >&2; exit 1; }
  [ "$(readlink -f /etc/sukhi/infra)" = "$(readlink -f "$infra_dir")" ] ||
    { echo "/etc/sukhi/infra points at the wrong checkout; refusing to overwrite it" >&2; exit 1; }
else
  ln -s "$infra_dir" /etc/sukhi/infra
fi
chown -h root:root /etc/sukhi/infra

if [ -n "$release" ]; then
  # root が sukhi の持つ checkout を読むので、git の "dubious ownership" を、この呼び出しだけ許す(設定には書かない)
  git_infra() { git -c safe.directory="$infra_dir" -C "$infra_dir" "$@"; }
  [ -d "$infra_dir/.git" ] || { echo "infra checkout missing: $infra_dir (run prepare-user.sh first)" >&2; exit 1; }
  git_infra cat-file -e "$release^{commit}" ||
    { echo "infra release is not a commit in $infra_dir: $release" >&2; exit 1; }
  printf '%s\n' "$(git_infra rev-parse "$release^{commit}")" > /etc/sukhi/release-revision
  chmod 644 /etc/sukhi/release-revision
fi

# stow の package: 共通の `sukhi`(あれば)と、環境の `<env>`(instance.json など)。無い package は飛ばす
packages=()
for pkg in sukhi "$env_name"; do
  [ -d "$infra_dir/stow/$pkg" ] && packages+=("$pkg")
done
if [ "${#packages[@]}" -gt 0 ]; then
  command -v stow >/dev/null 2>&1 || {
    echo "GNU Stow is required for $infra_dir/stow (${packages[*]}); install it, then rerun this script" >&2
    exit 1
  }
  for pkg in "${packages[@]}"; do
    if find "$infra_dir/stow/$pkg" \( -type f -o -type l \) -print | grep -Eiq '(^|/)(secret|secrets|credentials|allowed_signers)(\.|/|$)'; then
      echo "refusing to Stow a secret-looking file in $pkg; keep secrets in Podman secret" >&2
      exit 1
    fi
  done
  stow -n -v --no-folding --dir "$infra_dir/stow" --target /etc/sukhi "${packages[@]}"
  stow -v --no-folding --dir "$infra_dir/stow" --target /etc/sukhi "${packages[@]}"
else
  echo "note: no $infra_dir/stow/{sukhi,$env_name} package; non-secret Stow entrypoint not installed yet"
fi
[ -e /etc/sukhi/instance.json ] ||
  echo "note: /etc/sukhi/instance.json が無い。infra に stow/$env_name/instance.json が入ってから、もう一度流す" >&2

echo "ok. 次: (1) sukhi のパスワードをパスワードマネージャーで作って passwd sukhi (Cockpit のログインに必須)"
echo "    (2) /etc/sukhi/allowed_signers に署名者の公開鍵を (3) sukhi で prepare-user.sh"
echo "    失敗時は表示された『次』を実行。既存 secret/volume は変更しない。"
echo "    cgroup の確認: cat /sys/fs/cgroup/user.slice/user-\$(id -u sukhi).slice/user@\$(id -u sukhi).service/cgroup.controllers  (cpu が出ること。出なければ sukhi が一度ログアウトして入り直し)"
