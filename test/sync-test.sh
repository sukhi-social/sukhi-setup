#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# bin/sukhi-gitops-sync の通し試験。systemctl / podman / cosign は偽物に差し替える(実機では何も動かさない)。
# 署名(ssh / gpg)の検証は含まない(VERIFY_COMMITS=none)。実機で確かめる。
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME" "$T/bin"
D1=$(printf '1%.0s' $(seq 64)); D2=$(printf '2%.0s' $(seq 64)); Z=$(printf '0%.0s' $(seq 64))

# --- 偽物 ---
cat >"$T/bin/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >>"$FAKE_LOG"
EOF
cat >"$T/bin/podman" <<'EOF'
#!/bin/sh
# podman inspect --format ... <unit>: 健康状態を返す。FAKE_UNHEALTHY に入っている unit は unhealthy
for last; do :; done
case " ${FAKE_UNHEALTHY:-} " in *" $last "*) echo unhealthy ;; *) echo healthy ;; esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$T/bin/cosign"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE_LOG="$T/calls"; : >"$FAKE_LOG"
# systemctl is-active は成功させる(偽物は常に 0)

# --- 手元の origin ---
git init -q --bare "$T/origin.git"
git init -q "$T/src"; cd "$T/src"; git config user.email t@t; git config user.name t
mkdir -p base overlays/test/sukhi-gateway.container.d overlays/other/sukhi-gateway.container.d
mk() { printf '[Unit]\nDescription=%s\n\n[Container]\nImage=%s\n' "$1" "$2" >"base/$1.container"; }
mk sukhi-nats   "docker.io/library/nats:2-alpine@sha256:$D1"
mk sukhi-gateway "ghcr.io/sukhi-social/sukhi-fedi-combined:sha-aaaaaaa@sha256:$D1"
mk sukhi-web-next "ghcr.io/sukhi-social/sukhi-fedi-web-next:sha-aaaaaaa@sha256:$D1"
printf '[Container]\nEnvironment=DOMAIN=test.invalid\n' >overlays/test/sukhi-gateway.container.d/override.conf
printf '[Container]\nEnvironment=DOMAIN=other.invalid\n' >overlays/other/sukhi-gateway.container.d/override.conf
git add -A; git commit -qm c1; git branch -M main; git remote add origin "$T/origin.git"; git push -q origin main
git clone -q "$T/origin.git" "$T/infra"

export SUKHI_GITOPS_ENV=/dev/null SUKHI_ENV=test INFRA_DIR="$T/infra" QUADLET_DIR="$T/quadlet" STATE_DIR="$T/state" \
       VERIFY_COMMITS=none HOLD_SECS=0
S="$here/bin/sukhi-gitops-sync"
n=0; ok() { n=$((n+1)); echo "ok $n - $1"; }
fail() { echo "NOT OK - $1" >&2; echo "--- calls:"; cat "$FAKE_LOG" >&2; exit 1; }
calls() { grep -E "restart|stop" "$FAKE_LOG" | tr '\n' ';'; }

# 1. 最初は --check: 変わらない
"$S" --check >/dev/null; [ ! -e "$QUADLET_DIR" ] || fail "check wrote files"; ok "check changes nothing"

# 2. 最初の apply: 全 unit を起こす(順序: nats → gateway → web-)
: >"$FAKE_LOG"; "$S" --apply >/dev/null
[ "$(calls)" = "--user restart sukhi-nats.service;--user restart sukhi-gateway.service;--user restart sukhi-web-next.service;" ] || fail "first apply order: $(calls)"
[ -f "$QUADLET_DIR/sukhi-gateway.container.d/override.conf" ] && grep -q test.invalid "$QUADLET_DIR/sukhi-gateway.container.d/override.conf" || fail "overlay not applied"
[ ! -e "$QUADLET_DIR/overlays" ] || fail "not flattened"
ok "first apply, ordered, overlay flattened"

# 3. 最新なら何もしない
: >"$FAKE_LOG"; "$S" --apply >/dev/null; [ -z "$(calls)" ] || fail "restarted when up to date"; ok "up to date is a no-op"

# 4. 別の環境の overlay だけの変更では動かない(last-good は進まない = 差分なしでも commit は取り込む)
cd "$T/src"; printf '[Container]\nEnvironment=DOMAIN=other2.invalid\n' >overlays/other/sukhi-gateway.container.d/override.conf
git commit -qam c2; git push -q origin main
: >"$FAKE_LOG"; "$S" --apply >/dev/null; [ -z "$(calls)" ] || fail "other env change restarted: $(calls)"; ok "other env change restarts nothing"

# 5. gateway の image だけ変える → gateway だけ try-restart
cd "$T/src"; sed -i "s/$D1/$D2/" base/sukhi-gateway.container; git commit -qam c3; git push -q origin main
: >"$FAKE_LOG"; "$S" --apply >/dev/null
[ "$(calls)" = "--user try-restart sukhi-gateway.service;" ] || fail "only gateway expected: $(calls)"; ok "only the changed unit is try-restarted"
good=$(cat "$STATE_DIR/last-good")

# 6. 不健康 → 戻す・見送り・last-good は進まない
cd "$T/src"; sed -i "s/sha-aaaaaaa@sha256:$D1/sha-bbbbbbb@sha256:$D2/" base/sukhi-web-next.container; git commit -qam c4; git push -q origin main
: >"$FAKE_LOG"; FAKE_UNHEALTHY=sukhi-web-next "$S" --apply >/dev/null && fail "unhealthy apply returned 0" || true
[ "$(cat "$STATE_DIR/last-good")" = "$good" ] || fail "last-good moved"
grep -q "sha-aaaaaaa" "$QUADLET_DIR/sukhi-web-next.container" || fail "not rolled back"
grep -q "$(git -C "$T/infra" rev-parse origin/main)" "$STATE_DIR/rejected" || fail "not recorded as rejected"
ok "unhealthy → rolled back, rejected, last-good unchanged"
: >"$FAKE_LOG"; "$S" --apply >/dev/null; [ -z "$(calls)" ] || fail "retried a rejected commit"; ok "rejected commit is not retried"

# 7. 仮のダイジェスト → 拒否(2)で何も変えない
cd "$T/src"; sed -i "s/$D1/$Z/" base/sukhi-nats.container; git commit -qam c5; git push -q origin main
: >"$FAKE_LOG"; rc=0; "$S" --apply >/dev/null || rc=$?
[ "$rc" = 2 ] && [ -z "$(calls)" ] || fail "placeholder not refused (rc=$rc)"; ok "placeholder digest refused (rc 2)"

# 8. 手で置かれた上書き → --clear-overrides が要る
cd "$T/src"; sed -i "s/$Z/$D1/" base/sukhi-nats.container; git commit -qam c6; git push -q origin main
"$S" forget-rejected >/dev/null
mkdir -p "$QUADLET_DIR/sukhi-gateway.container.d"; printf '[Container]\nImage=localhost/x\n' >"$QUADLET_DIR/sukhi-gateway.container.d/10-image.conf"
rc=0; "$S" --apply >/dev/null || rc=$?; [ "$rc" = 2 ] || fail "drift not refused (rc=$rc)"
"$S" --apply --clear-overrides >/dev/null || fail "clear-overrides failed"
[ ! -e "$QUADLET_DIR/sukhi-gateway.container.d/10-image.conf" ] || fail "override not cleared"; ok "manual override needs --clear-overrides"

echo "all $n passed"
