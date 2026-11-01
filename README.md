<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# sukhi-setup

sukhi の箱(Rocky Linux、Podman rootless、専用ユーザー `sukhi`)を**準備する手順と道具**。人が手で入れるもの。
箱が自動で引いて実行する Quadlet の正本は [sukhi-infra](https://github.com/sukhi-social/sukhi-infra)(別のリポジトリ)。

設計は [sukhi-fedi の `docs/OPS_QUADLET_GITOPS.md`](https://github.com/sukhi-social/sukhi-fedi/blob/main/docs/OPS_QUADLET_GITOPS.md)。

## なぜ infra と分けるか

同期スクリプト(署名と image の検証役)が `sukhi-infra` の中にあると、infra を書き換えた人が検証の仕組みごと書き換えられる。
ここは自動では適用されない。変更は PR・必須レビューで入れ、箱には人が `prepare-*.sh` で入れる。

## 中身

| パス | 何か |
| --- | --- |
| `docs/PREPARE.md` | 準備の手順(上から順に) |
| `scripts/prepare-root.sh` | root が要る部分: ユーザー、linger、cgroup 委譲、journal、`/etc/sukhi` |
| `scripts/prepare-user.sh` | `sukhi` でやる部分: deploy key、infra の clone、`podman secret`、timer |
| `bin/sukhi-render` | (Ruby)`sukhi.version` の値で `{{version}}` / `{{digest:<name>}}` を埋める。**埋め方を決める唯一の場所**(箱の同期は load、sukhi-infra の CI はコマンドか load で使う) |
| `bin/sukhi-gitops-sync` | (Ruby)引く → 署名を確かめる → 変わった unit だけ再起動 → ヘルスを待つ → 失敗なら戻す |
| `systemd/user/` | 同期の service / timer(既定は `--check`)、失敗の通知 |
| `systemd/system/user@.service.d/delegate.conf` | rootless の cgroup 委譲(cpu を含める) |
| `etc/gitops.env.example` | `/etc/sukhi/gitops.env` の例 |
| `test/sync_test.rb` | 埋め込みと同期スクリプトの試験(minitest。systemctl / podman / cosign は偽物) |

## 試験

```sh
ruby test/sync_test.rb   # 16 項目。実機では何も動かさない
```

**Ruby 3.0 以上が要る**(標準ライブラリだけ。Rocky は `sudo dnf module enable ruby:3.3 && sudo dnf install ruby`。版は `dnf module list ruby` で確かめる)。
`prepare-root.sh` / `prepare-user.sh` は、Ruby が入る前に動かすので bash のまま。

署名(ssh / gpg)の検証と、実際の Podman・Quadlet・Cockpit は**含まれない**。箱で確かめる(docs/PREPARE.md §7)。
