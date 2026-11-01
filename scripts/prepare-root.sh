#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# 箱の準備のうち root が要る部分(一度だけ。何度流しても同じ結果になる)。
#   sudo scripts/prepare-root.sh <prod|dev>
# パッケージは入れない(docs/PREPARE.md の手順で人が入れる)。パスワードも作らない(パスワードマネージャーで作る)。
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
env_name="${1:?usage: $0 <prod|dev>}"
case "$env_name" in prod|dev) ;; *) echo "env must be prod or dev" >&2; exit 1 ;; esac
here=$(cd "$(dirname "$0")/.." && pwd)

# 1. サービスユーザー(アプリを動かすためだけ。人用のユーザーとは別)
id sukhi >/dev/null 2>&1 || useradd -m -s /bin/bash sukhi
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

echo "ok. 次: (1) sukhi のパスワードをパスワードマネージャーで作って passwd sukhi (Cockpit のログインに必須)"
echo "    (2) /etc/sukhi/allowed_signers に署名者の公開鍵を (3) sukhi で入って scripts/prepare-user.sh"
echo "    cgroup の確認: cat /sys/fs/cgroup/user.slice/user-\$(id -u sukhi).slice/user@\$(id -u sukhi).service/cgroup.controllers  (cpu が出ること。出なければ sukhi が一度ログアウトして入り直し)"
