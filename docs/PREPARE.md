<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 箱の準備(Rocky Linux・Podman rootless・Quadlet・GitOps)

> **実機では通していない。** 上から順に。各節の「確かめ」が通ってから次へ。
> 設計は sukhi-fedi の `docs/OPS_QUADLET_GITOPS.md`、Cockpit は同じく `docs/RUNTIME.md` §12。

## 1. パッケージ(人が入れる。スクリプトは入れない)

```sh
sudo dnf install -y podman skopeo git openssl cockpit cockpit-podman
podman --version      # この版を OPS_QUADLET_GITOPS.md §12-6 に書く(Notify=healthy 等が効くかの根拠)
```

- `cosign` は EPEL か公式の rpm(`dnf info cosign` で確かめる)。入れたものは OS の自動更新の対象になる(RUNTIME.md §12.4)。
- Cockpit は **127.0.0.1 だけで待ち受ける**(RUNTIME.md §12.1 の `cockpit.socket.d/listen.conf`)。9090 番は開けない。SSH のトンネルで見る。

## 2. root の部分

```sh
sudo scripts/prepare-root.sh prod        # 開発の箱なら dev
```

やること: `sukhi` ユーザー、linger、cgroup 委譲(`Delegate=cpu cpuset io memory pids`)、journal の永続化、`/etc/sukhi/`。

確かめ:

```sh
grep sukhi /etc/subuid /etc/subgid                                  # 範囲があること
loginctl show-user sukhi -p Linger                                  # Linger=yes
# sukhi が一度入り直したあと:
cat /sys/fs/cgroup/user.slice/user-$(id -u sukhi).slice/user@$(id -u sukhi).service/cgroup.controllers   # cpu が出ること
```

## 3. `sukhi` のパスワード(Cockpit に必須)

Cockpit は `sukhi` でログインして rootless のコンテナを見る(RUNTIME.md §12.1)。ログインにパスワードが要る。

- **パスワードマネージャーで生成した長いもの**にする(人の記憶に頼らない・使い回さない)。
- `sudo passwd sukhi` に貼る。ssh は鍵だけで入る運用のままでよい(sshd のパスワード認証は閉じたまま)。
- Cockpit は**見る**だけに使う(OPS_QUADLET_GITOPS.md §11.2)。`sukhi` のログインは箱の中で `sukhi` の権限を丸ごと渡すので、
  トンネルの中だけ・アイドル切れ(`IdleTimeout = 15`)を崩さない。

## 4. 署名者(コミット署名の公開鍵)

`/etc/sukhi/allowed_signers`(リポジトリの外)に、`sukhi-infra` の main に入るコミットの署名者を書く:

```
<メール> namespaces="git" ssh-ed25519 AAAA...
```

- 方式は `/etc/sukhi/gitops.env` の `VERIFY_COMMITS`(`ssh` / `gpg`)。GitHub の Web でマージして署名を付ける運用なら `gpg` にして、
  GitHub の署名鍵(`https://github.com/web-flow.gpg`)を `sukhi` の鍵束に入れる(OPS_QUADLET_GITOPS.md §12-5。未決)。
- 空のままだと、`ssh` 方式では**何も適用されない**(安全側)。

## 5. `sukhi` の部分

```sh
ssh sukhi@<箱>                        # su ではなく直接
git clone https://github.com/sukhi-social/sukhi-setup && cd sukhi-setup
scripts/prepare-user.sh               # 1 回目: deploy key を作って、公開鍵を表示して終わる
# → 表示された公開鍵を sukhi-infra の Settings > Deploy keys に「読み取り専用」で登録
scripts/prepare-user.sh --enable-timer   # 2 回目: infra を clone、podman secret、timer(--check のまま)
```

`podman secret`: `erlang_cookie` `secret_key_base` `anubis_ed25519_key` は自動で作る。ほかは**標準入力から**手で(値を引数やシェル履歴に残さない):

```sh
umask 077
read -rsp 'SMTP password: ' p; echo; printf '%s' "$p" | podman secret create smtp_password -; unset p
podman secret ls                      # 名前だけ。値は出ない
```

- rootless の `podman secret` の保管は `~/.local/share/containers/storage/secrets/` の平文ファイル(権限 600)。控えに入れるときに注意。
- secret を替えたら、それを使う unit の再起動が要る(secret だけでは届かない)。
- Quadlet の unit が `Secret=` で参照する名前は `sukhi-infra/base/*.container` を見る。足りない秘密は起動に失敗して分かる。

## 6. 計画 → 適用

timer は最初 **`--check`(計画だけ)** で回る。

```sh
sukhi-gitops-sync --check             # 何が変わるか。署名・Image= の形・仮のダイジェストを見る
journalctl --user -u sukhi-gitops-sync -n 30
```

- 版は sukhi-infra の `overlays/<env>/sukhi.version` に書かれ、同期スクリプトが unit の `{{version}}` / `{{digest:*}}` に埋める。
  `requires-sync` がこの スクリプトの版より大きいと適用しない(先に sukhi-setup を更新する)。
- **仮のダイジェスト(0 埋め)は適用されない。** 最初の bump PR(4 つの image が同じ sha で本物になる)がマージされてから先へ。
- 適用に進む: `systemctl --user edit sukhi-gitops-sync.service` で `[Service]` に `Environment=SUKHI_GITOPS_MODE=--apply`。
- 最初の適用の前に、`~/.config/containers/systemd/` に手で置いたものがあれば `--apply --clear-overrides` が要る(手で置いたものは消える)。
- **わざと壊した PR**(存在しないダイジェスト、起動しない設定)で、戻しと見送り(`sukhi-gitops-sync status` の `rejected`)を試してから、本番に任せる。

## 7. 実機で確かめること(未確認の一覧)

- 署名の検証(`ssh` / `gpg` どちらも。`test/sync-test.sh` は通さない)。
- Podman の版でのキー: `Notify=healthy`、`HealthOnFailure=kill`、`Secret=...,type=env`、ドロップインの重なり方。
- Quadlet が `~/.config/containers/systemd/` を読み、`sukhi-gateway.service` などが生成されること(`/usr/lib/systemd/system-generators/podman-system-generator --user --dryrun`)。
- ヘルス(`wget`)が各 image で通ること、Anubis のヘルスの口。
- cgroup の委譲で `cpu` が見えること、`CPUWeight=` が効くこと。
- Cockpit に `sukhi` で入って、コンテナと user の unit が見えること。
- 非常時: `sukhi-fedi/scripts/sukhi-swap-image.sh` はドロップインを置く。次の同期で `--clear-overrides` が要る(意図した動き)。
