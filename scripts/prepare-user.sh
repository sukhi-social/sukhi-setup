#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 箱の準備のうちユーザー sukhi でやる部分(何度流してもよい。既にあるものは作り直さない)。
#   ssh で sukhi として入って(su ではなく):  scripts/prepare-user.sh [--enable-timer]
# 既定では timer を有効にしない。--enable-timer で有効にする(中身は --check のまま。適用は docs/PREPARE.md §6)。
set -euo pipefail
[ "$(id -un)" = sukhi ] || { echo "run as the sukhi user (log in with ssh, not su)" >&2; exit 1; }
[ -n "${XDG_RUNTIME_DIR:-}" ] || { echo "XDG_RUNTIME_DIR is not set; log in directly with ssh (or machinectl shell sukhi@)" >&2; exit 1; }
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f /etc/sukhi/gitops.env ] && . /etc/sukhi/gitops.env
INFRA_URL="${INFRA_URL:-git@github.com:sukhi-social/sukhi-infra.git}"
INFRA_DIR="${INFRA_DIR:-$HOME/.local/share/sukhi-infra}"

# 1. 置き場所
mkdir -p "$HOME/.local/bin" "$HOME/.config/systemd/user" "$HOME/.config/containers/systemd" "$HOME/.local/state/sukhi-gitops"
install -m 755 "$here/bin/sukhi-gitops-sync" "$here/bin/sukhi-render" "$HOME/.local/bin/"
install -m 644 "$here"/systemd/user/* "$HOME/.config/systemd/user/"

# 2. sukhi-infra を引くための読み取り専用 deploy key(書き込み権限は付けない)
key="$HOME/.ssh/sukhi-infra-deploy"
if [ ! -f "$key" ]; then
  install -d -m 700 "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C "sukhi-infra deploy (read-only) $(hostname)" -f "$key"
  echo "=== 次の公開鍵を sukhi-infra の Settings > Deploy keys に『読み取り専用』で登録してください ==="
  cat "$key.pub"
  echo "=== 登録したら、このスクリプトをもう一度 ==="
  exit 0
fi
export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
if [ ! -d "$INFRA_DIR/.git" ]; then git clone -q "$INFRA_URL" "$INFRA_DIR"; fi

# 3. podman secret(無いものだけ作る。値は表示しない・引数に出さない)
mk_secret() { podman secret inspect "$1" >/dev/null 2>&1 || { (umask 077; openssl rand -hex "$2" | podman secret create "$1" - >/dev/null); echo "created secret: $1"; }; }
mk_secret erlang_cookie 32
mk_secret secret_key_base 64
mk_secret anubis_ed25519_key 32
echo "SMTP・S3 などの秘密は docs/PREPARE.md §5 の手順で作る(ここでは作らない)"

# 4. systemd
systemctl --user daemon-reload
if [ "${1:-}" = "--enable-timer" ]; then systemctl --user enable --now sukhi-gitops-sync.timer; echo "timer enabled (--check mode)"; fi
echo "ok. 試す: sukhi-gitops-sync --check ; sukhi-gitops-sync status"
