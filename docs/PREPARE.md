<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# 箱の準備(Rocky Linux・Podman rootless・Quadlet・GitOps)

> **実機では通していない。** 上から順に。各節の「確かめ」が通ってから次へ。
> 設計は sukhi-fedi の `docs/OPS_QUADLET_GITOPS.md`、Cockpit は同じく `docs/RUNTIME.md` §12。

## 1. パッケージ(人が入れる。スクリプトは入れない)

```sh
sudo dnf install -y podman skopeo git openssl cockpit cockpit-podman
# 同期スクリプトは Ruby(標準ライブラリだけ)。Rocky は module で版を選ぶ:
dnf module list ruby                 # 3.0 以上があること
sudo dnf module enable -y ruby:3.3 && sudo dnf install -y ruby
ruby -v
podman --version      # この版を OPS_QUADLET_GITOPS.md §12-6 に書く(Notify=healthy 等が効くかの根拠)
```

- `cosign` は EPEL か公式の rpm(`dnf info cosign` で確かめる)。入れたものは OS の自動更新の対象になる(RUNTIME.md §12.4)。
- Cockpit は **127.0.0.1 だけで待ち受ける**(RUNTIME.md §12.1 の `cockpit.socket.d/listen.conf`)。9090 番は開けない。SSH のトンネルで見る。

## 2. root の部分

```sh
sudo scripts/prepare-root.sh prod        # 開発の箱なら dev
```

やること: `sukhi` ユーザー、linger、cgroup 委譲(`Delegate=cpu cpuset io memory pids`)、journal の永続化、`/etc/sukhi/`。

既存の `sukhi` ユーザーは作り直さず、home と subuid/subgid を検査して再利用する。既存の
`/etc/sukhi/env`、`gitops.env`、`allowed_signers`、secret、volume は上書きしない。

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

- 方式は **gpg に決定**(OPS_QUADLET_GITOPS.md §12-5)。`/etc/sukhi/gitops.env` の `VERIFY_COMMITS=gpg`(既定)。
- 検証には専用の鍵束 `GPG_HOME`(既定 `~/.local/share/sukhi-gnupg`)を使う。ここに入れた鍵の署名だけが通る。`sukhi` で:
  ```
  install -d -m 700 ~/.local/share/sukhi-gnupg
  curl -fsSL https://github.com/web-flow.gpg | GNUPGHOME=~/.local/share/sukhi-gnupg gpg --import   # GitHub の Web マージ
  GNUPGHOME=~/.local/share/sukhi-gnupg gpg --import <メンテナの公開鍵>                              # 直接 push する人
  ```
  取り込む前に、指紋を GitHub の画面(各人のプロフィール、web-flow は GitHub の公式文書)と見比べる。
- 鍵束が空のままだと、**何も適用されない**(安全側)。メンテナの鍵を失効・交代したら、鍵束も入れ替える。
- git の設定が `gpg.format=ssh` でも、同期は `gpg.format=openpgp` を指定して呼ぶので影響されない。

## 5. `sukhi` の部分

```sh
ssh sukhi@<箱>                        # su ではなく直接
git clone https://github.com/sukhi-social/sukhi-setup && cd sukhi-setup
scripts/prepare-user.sh --enable-timer   # infra を clone(public なので認証なしの https)、podman secret、timer(--check のまま)
```

sukhi-infra を private に戻すときは、`INFRA_URL` を `git@github.com:sukhi-social/sukhi-infra.git` にして `prepare-user.sh` を流す。
読み取り専用の deploy key を作って公開鍵を表示するので、sukhi-infra の Settings > Deploy keys に「読み取り専用」で登録し、もう一度流す。
service には、`sukhi-gitops-sync.service` の注釈にある `GIT_SSH_COMMAND` の drop-in を足す。deploy key には期限がないので、年に一度は入れ替える。

`prepare-user.sh` は既存 checkout の変更を守るため、dirty な checkout を上書きせず停止する。既定では `origin/main` の
commit を detached checkout にし、固定したい release は `--release REV` で指定できる。その後 root で次を実行する:

```sh
sudo scripts/prepare-root.sh prod \
  --infra-dir /home/sukhi/.local/share/sukhi-infra \
  --release <commit>
```

infra が `stow/sukhi/` を提供する場合、root スクリプトは GNU Stow の dry-run と本適用を順に行い、
`/etc/sukhi` の非秘密設定と Quadlet の入口だけを symlink で接続する。既存の `/etc/sukhi/infra` が
別 checkout を指している場合は安全のため停止する。秘密は Stow に置かず、`podman secret` のままにする。

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
- 適用前に `scripts/sukhi-preflight.sh` を `sukhi` で実行する。`/etc/sukhi/instance.json`
  (または `SUKHI_INSTANCE_CONFIG`) の存在・JSON、infra checkout の clean 状態、rootless Podman、
  placeholder DOMAIN を検査する。同期スクリプト自身も同じ契約を検査する。
- 適用に進む: `systemctl --user edit sukhi-gitops-sync.service` で `[Service]` に `Environment=SUKHI_GITOPS_MODE=--apply`。
- 最初の適用の前に、`~/.config/containers/systemd/` に手で置いたものがあれば `--apply --clear-overrides` が要る(手で置いたものは消える)。
- **わざと壊した PR**(存在しないダイジェスト、起動しない設定)で、戻しと見送り(`sukhi-gitops-sync status` の `rejected`)を試してから、本番に任せる。

## 7. 実機で確かめること(未確認の一覧)

- ssh 署名の検証(gpg はテストで確認済み。ssh は「署名なしを断る」だけ)。
- Podman の版でのキー: `Notify=healthy`、`HealthOnFailure=kill`、`Secret=...,type=env`、ドロップインの重なり方。
- Quadlet が `~/.config/containers/systemd/` を読み、`sukhi-gateway.service` などが生成されること(`/usr/lib/systemd/system-generators/podman-system-generator --user --dryrun`)。
- ヘルス(`wget`)が各 image で通ること、Anubis のヘルスの口。
- cgroup の委譲で `cpu` が見えること、`CPUWeight=` が効くこと。
- Cockpit に `sukhi` で入って、コンテナと user の unit が見えること。
- 非常時: `sukhi-fedi/scripts/sukhi-swap-image.sh` はドロップインを置く。次の同期で `--clear-overrides` が要る(意図した動き)。
- 失敗時は表示された `next:` をそのまま確認する。root のコマンドと `sukhi` のコマンドを混ぜず、secret/volume を消す再初期化はしない。

## 8. 動いている instance を引き継ぐとき

§1〜§6 は新しい箱の準備。すでに動いている instance(sukhi.social など)を移すときは、次の四つを先に済ませる。コードを読んで確かめた(2026-11-05 時点)。

1. **秘密は、起動の前に現行の値で作る。** `prepare-user.sh` の `mk_secret` は、無い名前(`erlang_cookie` `secret_key_base` `anubis_ed25519_key`)を乱数で作る。現行の値を `podman secret create` で先に入れてから流す。順を逆にすると、`secret_key_base` が変わってログインが切れ、anubis の鍵が変わって通行証が無効になる。
2. **`/etc/sukhi/instance.json` は手で置く。** preflight は存在と非空を要求するが、`prepare-root.sh` も同期も作らない。中身は `overlays/<env>/instance.json` と同じにする。
3. **最初の適用には戻し先が無い。** `applied`(前回の適用の記録)が無いと、同期は今の Quadlet を「手で置かれた上書き」とみなし、`--clear-overrides` を要求する。適用は、消える unit を先に止めてから入れ替える。ヘルスが通らなければ「戻す先が無い」と通知して止まる。動いている箱では、切り替えの前に旧の Quadlet を退避し、手で見ながら進める。
4. **base は全環境に配られる。** 同期は base を重ねて全 unit を書き出すので、overlay では unit を止められない(例: `web-simple` `web-board`)。止めるには base から外すか、同期の仕組みを変える。
