#!/usr/bin/env ruby
# frozen_string_literal: true

# SPDX-License-Identifier: AGPL-3.0-or-later
#
# bin/sukhi-render と bin/sukhi-gitops-sync の試験。systemctl / podman / cosign は偽物に差し替える
# (実機では何も動かさない)。署名は、ssh は「署名なしを断る」だけ、gpg は実際の gpg で通る・断るを確かめる。それ以外は VERIFY_COMMITS=none。
#   ruby test/sync_test.rb

# unit やコメントに日本語が入る。systemd の user service は LANG が無い(US-ASCII)ことがあるので UTF-8 に決める
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = nil

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "time"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
load File.join(ROOT, "bin", "sukhi-render")

class RenderTest < Minitest::Test
  def manifest(extra = "")
    "requires-sync: 1\nversion: 1.0.0  # 注釈\ndigest.combined: sha256:#{'1' * 64}\n#{extra}"
  end

  def render(text, man = manifest)
    Dir.mktmpdir do |d|
      File.write(File.join(d, "sukhi.version"), man)
      File.write(File.join(d, "u.container"), text)
      Sukhi::Render.render_dir(File.join(d, "sukhi.version"), d)
      File.read(File.join(d, "u.container"))
    end
  end

  def test_fills_version_and_digest
    assert_equal "Image=x/c:1.0.0@sha256:#{'1' * 64}\n", render("Image=x/c:{{version}}@{{digest:combined}}\n")
  end

  def test_leaves_plain_text_alone
    assert_equal "Image=nats:2@sha256:abc\n", render("Image=nats:2@sha256:abc\n")
  end

  def test_unknown_token_fails
    assert_raises(Sukhi::Render::Error) { render("a={{nope}}\n") }
  end

  def test_missing_key_fails
    assert_raises(Sukhi::Render::Error) { render("a={{digest:web-next}}\n") }
  end
end

class SyncTest < Minitest::Test
  D1 = "1" * 64
  D2 = "2" * 64
  ZERO = "0" * 64
  SYNC = File.join(ROOT, "bin", "sukhi-gitops-sync")

  def sh(*cmd, dir: nil, env: {})
    opts = dir ? { chdir: dir } : {}
    out, st = Open3.capture2e(env, *cmd, **opts)
    raise "#{cmd.join(' ')} failed: #{out}" unless st.success?

    out
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def commit(msg)
    sh("git", "add", "-A", dir: @src)
    sh("git", "commit", "-qm", msg, dir: @src)
    sh("git", "push", "-q", "origin", "main", dir: @src)
  end

  def manifest(env, version, combined, web_next, requires: 1)
    write(File.join(@src, "overlays", env, "sukhi.version"),
          "requires-sync: #{requires}\nversion: #{version}   # 注釈\n" \
          "digest.combined: sha256:#{combined}\ndigest.web-next: sha256:#{web_next}\n")
  end

  def container(name, image)
    write(File.join(@src, "base", "#{name}.container"), "[Unit]\nDescription=#{name}\n\n[Container]\nImage=#{image}\n")
  end

  def run_sync(*args, unhealthy: "")
    File.write(@log, "")
    out, st = Open3.capture2e(@env.merge("FAKE_UNHEALTHY" => unhealthy), SYNC, *args)
    @last_out = out
    st.exitstatus
  end

  def calls = File.readlines(@log, chomp: true).grep(/restart|stop/).map { |l| l.sub("--user ", "") }

  def setup
    @tmp = Dir.mktmpdir
    @bin = File.join(@tmp, "bin")
    @log = File.join(@tmp, "calls")
    FileUtils.mkdir_p(@bin)
    # 偽物: systemctl は呼ばれ方を記録、podman inspect は FAKE_UNHEALTHY の unit だけ unhealthy、cosign は成功
    File.write(File.join(@bin, "systemctl"), "#!/bin/sh\necho \"$*\" >>\"$FAKE_LOG\"\n")
    File.write(File.join(@bin, "podman"), "#!/bin/sh\n[ \"$1\" = pull ] && echo \"podman $*\" >>\"$FAKE_LOG\"\nfor last; do :; done\ncase \" $FAKE_UNHEALTHY \" in *\" $last \"*) echo unhealthy;; *) echo healthy;; esac\n")
    File.write(File.join(@bin, "cosign"), "#!/bin/sh\nexit 0\n")
    FileUtils.chmod(0o755, Dir.glob(File.join(@bin, "*")))

    sh("git", "init", "-q", "--bare", "-b", "main", File.join(@tmp, "origin.git"))
    @src = File.join(@tmp, "src")
    sh("git", "init", "-q", "-b", "main", @src)
    sh("git", "config", "user.email", "t@t", dir: @src)
    sh("git", "config", "user.name", "t", dir: @src)
    sh("git", "remote", "add", "origin", File.join(@tmp, "origin.git"), dir: @src)
    container("sukhi-nats", "docker.io/library/nats:2-alpine@sha256:#{D1}")
    container("sukhi-gateway", "ghcr.io/sukhi-social/sukhi-fedi-combined:{{version}}@{{digest:combined}}")
    container("sukhi-web-next", "ghcr.io/sukhi-social/sukhi-fedi-web-next:{{version}}@{{digest:web-next}}")
    %w[test other].each do |e|
      manifest(e, "sha-aaaaaaa", D1, D1)
      write(File.join(@src, "overlays", e, "sukhi-gateway.container.d", "override.conf"), "[Container]\nEnvironment=DOMAIN=#{e}.invalid\n")
    end
    commit("c1")
    sh("git", "clone", "-q", File.join(@tmp, "origin.git"), File.join(@tmp, "infra"))

    @quadlet = File.join(@tmp, "quadlet")
    @state = File.join(@tmp, "state")
    @env = {
      "PATH" => "#{@bin}:#{ENV['PATH']}", "FAKE_LOG" => @log, "HOME" => File.join(@tmp, "home"),
      "SUKHI_GITOPS_ENV" => "/dev/null", "SUKHI_ENV" => "test", "INFRA_DIR" => File.join(@tmp, "infra"),
      "QUADLET_DIR" => @quadlet, "STATE_DIR" => @state, "VERIFY_COMMITS" => "none", "HOLD_SECS" => "0",
      "PREFLIGHT" => "0", "APPROVE_DIR" => File.join(@tmp, "approve"),
    }
  end

  def teardown = FileUtils.rm_rf(@tmp)

  def test_check_changes_nothing
    assert_equal 0, run_sync("--check")
    refute File.exist?(@quadlet)
  end

  def test_first_apply_is_ordered_and_flattened
    assert_equal 0, run_sync("--apply")
    assert_equal %w[restart\ sukhi-nats.service restart\ sukhi-gateway.service restart\ sukhi-web-next.service], calls
    assert_match(/test\.invalid/, File.read(File.join(@quadlet, "sukhi-gateway.container.d/override.conf")))
    refute File.exist?(File.join(@quadlet, "overlays"))
    refute File.exist?(File.join(@quadlet, "sukhi.version"))
    refute_match(/\{\{/, Dir.glob(File.join(@quadlet, "**/*")).select { |f| File.file?(f) }.map { |f| File.read(f) }.join)
  end

  def pulls = File.readlines(@log, chomp: true).grep(/\Apodman pull/)

  def test_check_prepulls_images_of_units_to_restart_once
    assert_equal 0, run_sync("--check")
    assert_equal 3, pulls.size
    assert(pulls.all? { |l| l.match?(/@sha256:/) })
    assert_equal 0, run_sync("--check") # run_sync は記録を空にして始める
    assert_empty pulls # 引いたものは、もう引かない
  end

  def test_prepull_skips_units_that_do_not_change
    run_sync("--apply")
    manifest("test", "sha-aaaaaaa", D2, D1)
    commit("c5")
    run_sync("--check")
    new = pulls.last(1)
    assert_match(/sukhi-fedi-combined/, new.first)
  end

  def test_prepull_can_be_turned_off
    @env["PREPULL"] = "0"
    run_sync("--check")
    assert_empty pulls
  end

  def test_up_to_date_is_a_noop
    run_sync("--apply")
    assert_equal 0, run_sync("--apply")
    assert_empty calls
  end

  def test_other_env_change_restarts_nothing
    run_sync("--apply")
    write(File.join(@src, "overlays/other/sukhi-gateway.container.d/override.conf"), "[Container]\nEnvironment=DOMAIN=other2.invalid\n")
    commit("c2")
    assert_equal 0, run_sync("--apply")
    assert_empty calls
  end

  def test_only_the_changed_unit_is_try_restarted
    run_sync("--apply")
    manifest("test", "sha-aaaaaaa", D2, D1)
    commit("c3")
    assert_equal 0, run_sync("--apply")
    assert_equal ["try-restart sukhi-gateway.service"], calls
  end

  def test_version_bump_restarts_sukhi_units_but_not_nats
    run_sync("--apply")
    manifest("test", "1.0.0", D2, D2)
    commit("c4")
    assert_equal 0, run_sync("--apply")
    assert_equal ["try-restart sukhi-gateway.service", "try-restart sukhi-web-next.service"], calls
  end

  def test_unhealthy_rolls_back_rejects_and_is_not_retried
    run_sync("--apply")
    good = File.read(File.join(@state, "last-good"))
    manifest("test", "sha-bbbbbbb", D2, D2)
    commit("c5")
    assert_equal 1, run_sync("--apply", unhealthy: "sukhi-web-next")
    assert_equal good, File.read(File.join(@state, "last-good"))
    assert_match(/sha-aaaaaaa/, File.read(File.join(@quadlet, "sukhi-web-next.container")))
    assert_includes File.read(File.join(@state, "rejected")), sh("git", "rev-parse", "origin/main", dir: File.join(@tmp, "infra")).strip
    assert_equal 0, run_sync("--apply")
    assert_empty calls
  end

  def test_rollback_starts_units_that_were_down
    run_sync("--apply")
    manifest("test", "sha-bbbbbbb", D2, D2)
    commit("c5b")
    assert_equal 1, run_sync("--apply", unhealthy: "sukhi-web-next")
    # 止まっている unit は、前の版で起こす(try-restart は止まっているものには何もしない)
    assert_equal ["try-restart sukhi-gateway.service", "try-restart sukhi-web-next.service",
                  "restart sukhi-gateway.service", "restart sukhi-web-next.service"], calls
  end

  def test_rollback_starts_units_the_new_version_removed
    run_sync("--apply")
    File.delete(File.join(@src, "base", "sukhi-nats.container"))
    manifest("test", "sha-bbbbbbb", D2, D2)
    commit("c6")
    assert_equal 1, run_sync("--apply", unhealthy: "sukhi-web-next")
    # 新しい版で消えた unit は、前の版では動いていたので、戻すときに起こす(依存の先頭から)
    assert_equal ["stop sukhi-nats.service", "try-restart sukhi-gateway.service", "try-restart sukhi-web-next.service",
                  "restart sukhi-nats.service", "restart sukhi-gateway.service", "restart sukhi-web-next.service"], calls
  end

  def status_json = JSON.parse(File.read(File.join(@state, "public", "status.json")))

  def test_status_json_reports_available_update_on_check
    assert_equal 0, run_sync("--check")
    st = status_json
    assert_equal 1, st["schema"]
    assert_equal "update_available", st["state"]
    assert_equal "test", st["env"]
    assert_equal "sha-aaaaaaa", st["available"]["version"]
    assert_equal true, st["available"]["verified"]
    assert_match(/\A\h{40}\z/, st["available"]["commit"])
    assert_nil st["applied"]
    assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/, st["checked_at"])
    assert_empty Dir.glob(File.join(@state, "public", ".status.json.*"))
  end

  def test_status_json_after_apply_and_when_up_to_date
    assert_equal 0, run_sync("--apply")
    st = status_json
    assert_equal "up_to_date", st["state"]
    assert_nil st["available"]
    assert_equal File.read(File.join(@state, "last-good")).strip, st["applied"]["commit"]
    assert_equal "sha-aaaaaaa", st["applied"]["version"]
    applied = st["applied"]
    assert_equal 0, run_sync("--apply") # 変更なし。applied の version と時刻は引き継ぐ
    assert_equal "up_to_date", status_json["state"]
    assert_equal applied, status_json["applied"]
  end

  def test_status_json_reports_rejected_and_keeps_applied
    run_sync("--apply")
    applied = status_json["applied"]
    manifest("test", "sha-bbbbbbb", D2, D2)
    commit("c-rej")
    assert_equal 1, run_sync("--apply", unhealthy: "sukhi-web-next")
    st = status_json
    assert_equal "rejected", st["state"]
    assert_equal "sha-bbbbbbb", st["available"]["version"]
    assert_equal applied, st["applied"]
    assert_equal [st["available"]["commit"]], st["rejected"]
    assert_equal 0, run_sync("--check") # 見送り中の版は、待つだけ
    assert_equal "rejected", status_json["state"]
  end

  def test_status_json_reports_error_when_refused
    run_sync("--apply")
    manifest("test", "sha-ccccccc", ZERO, D2)
    commit("c-ref")
    assert_equal 2, run_sync("--apply")
    st = status_json
    assert_equal "error", st["state"]
    assert_match(/placeholder digest/, st["last_error"])
    assert_nil st["available"]
  end

  # ---- 承認(--apply --approved) ----

  def approve_file = File.join(@tmp, "approve", "approve.json")

  def head = sh("git", "rev-parse", "HEAD", dir: @src).strip

  def approve(commit: head, by: "kuro_admin", at: Time.now.utc.iso8601)
    write(approve_file, JSON.generate({ commit: commit, by: by, at: at }))
  end

  def test_approved_apply_runs_and_consumes_the_approval
    approve
    assert_equal 0, run_sync("--apply", "--approved")
    assert_equal "up_to_date", status_json["state"]
    refute_empty calls
    assert_match(/approved_by=kuro_admin/, File.read(File.join(@state, "history")))
    refute File.exist?(approve_file)
  end

  def test_approved_without_a_file_applies_nothing
    assert_equal 0, run_sync("--apply", "--approved")
    assert_empty calls
    assert_equal "update_available", status_json["state"]
  end

  def test_approval_for_another_commit_is_discarded
    approve(commit: "f" * 40)
    assert_equal 0, run_sync("--apply", "--approved")
    assert_empty calls
    assert_match(/approval is for ffffffffffff/, status_json["last_error"])
    refute File.exist?(approve_file)
  end

  def test_expired_approval_is_discarded
    approve(at: (Time.now.utc - 3601).iso8601)
    assert_equal 0, run_sync("--apply", "--approved")
    assert_empty calls
    assert_match(/expired/, status_json["last_error"])
    refute File.exist?(approve_file)
  end

  def test_malformed_approval_is_discarded
    write(approve_file, "{nope")
    assert_equal 0, run_sync("--apply", "--approved")
    assert_empty calls
    assert_match(/malformed/, status_json["last_error"])
    refute File.exist?(approve_file)
    approve(by: "a b; rm -rf /")
    assert_equal 0, run_sync("--apply", "--approved")
    assert_empty calls
  end

  def test_approval_never_overrides_a_failed_verification
    run_sync("--apply")
    manifest("test", "sha-ccccccc", ZERO, D2)
    commit("c-ref")
    approve
    assert_equal 2, run_sync("--apply", "--approved")
    assert_empty calls
  end

  def test_check_ignores_the_approval
    approve
    assert_equal 0, run_sync("--check")
    assert_empty calls
    assert File.exist?(approve_file)
  end

  def test_approved_is_only_for_apply
    assert_equal 64, run_sync("--check", "--approved")
  end

  def test_approval_is_dropped_when_already_up_to_date
    run_sync("--apply")
    approve
    assert_equal 0, run_sync("--apply", "--approved")
    assert_empty calls
    refute File.exist?(approve_file)
  end

  def test_status_json_reports_error_when_fetch_fails
    run_sync("--apply")
    FileUtils.rm_rf(File.join(@tmp, "origin.git"))
    assert_equal 1, run_sync("--check")
    st = status_json
    assert_equal "error", st["state"]
    assert_match(/git fetch failed/, st["last_error"])
    refute_nil st["applied"] # 動いている版は分かる
  end

  def test_placeholder_digest_is_refused
    run_sync("--apply")
    manifest("test", "sha-ccccccc", ZERO, D2)
    commit("c6")
    assert_equal 2, run_sync("--apply")
    assert_empty calls
  end

  def test_preflight_rejects_placeholder_domain
    @env["PREFLIGHT"] = "1"
    config = File.join(@tmp, "instance.json")
    File.write(config, "{}")
    @env["SUKHI_INSTANCE_CONFIG"] = config
    assert_equal 2, run_sync("--apply")
    assert_includes @last_out, "placeholder DOMAIN/config value"
    assert_empty calls
  end

  def test_manual_override_needs_clear_overrides
    run_sync("--apply")
    FileUtils.mkdir_p(File.join(@quadlet, "sukhi-gateway.container.d"))
    File.write(File.join(@quadlet, "sukhi-gateway.container.d/10-image.conf"), "[Container]\nImage=localhost/x\n")
    manifest("test", "sha-ddddddd", D2, D1)
    commit("c7")
    assert_equal 2, run_sync("--apply")
    assert_equal 0, run_sync("--apply", "--clear-overrides")
    refute File.exist?(File.join(@quadlet, "sukhi-gateway.container.d/10-image.conf"))
  end

  def test_newer_manifest_format_is_refused
    run_sync("--apply")
    manifest("test", "sha-eeeeeee", D1, D1, requires: 99)
    commit("c8")
    assert_equal 2, run_sync("--apply")
    assert_empty calls
  end

  def test_unfilled_digest_is_refused
    run_sync("--apply")
    write(File.join(@src, "overlays/test/sukhi.version"), "requires-sync: 1\nversion: sha-fffffff\ndigest.combined: sha256:#{D1}\n")
    commit("c9")
    assert_equal 2, run_sync("--apply")
    assert_empty calls
  end

  def test_unsigned_commit_is_refused_when_signatures_are_required
    @env["VERIFY_COMMITS"] = "ssh"
    @env["ALLOWED_SIGNERS"] = File.join(@tmp, "allowed_signers")
    File.write(@env["ALLOWED_SIGNERS"], "")
    assert_equal 2, run_sync("--apply")
    refute File.exist?(@quadlet)
  end

  def test_unwritable_quadlet_dir_stops_nothing
    # 置き場所の親がファイル(= mkdir できない)。unit を止める前に失敗して、何も止めない
    parent = File.join(@tmp, "blocked")
    File.write(parent, "")
    @env["QUADLET_DIR"] = File.join(parent, "systemd")
    assert_equal 1, run_sync("--apply")
    assert_match(/cannot write/, @last_out)
    assert_empty calls
  end

  # --- gpg: 専用の鍵束に入れた鍵の署名だけを許す(実際の gpg を使う) ---
  def gpg_key(name)
    home = File.join(@tmp, "gpg-#{name}")
    FileUtils.mkdir_p(home, mode: 0o700)
    sh("gpg", "-q", "--batch", "--passphrase", "", "--quick-gen-key", "#{name} <#{name}@t>", "ed25519", "sign", "never", env: { "GNUPGHOME" => home })
    fpr = sh("gpg", "--list-keys", "--with-colons", name, env: { "GNUPGHOME" => home })[/^fpr:+([0-9A-F]+)/, 1]
    [home, fpr]
  end

  def signed_commit(msg, home, fpr)
    write(File.join(@src, "note"), msg)
    sh("git", "add", "-A", dir: @src)
    sh("git", "-c", "gpg.format=openpgp", "-c", "user.signingkey=#{fpr}", "commit", "-q", "-S", "-m", msg, dir: @src, env: { "GNUPGHOME" => home })
    sh("git", "push", "-q", "origin", "main", dir: @src)
  end

  def gpg_env(home) = @env.merge("VERIFY_COMMITS" => "gpg", "GPG_HOME" => home)

  def test_gpg_signed_commit_from_keyring_is_applied
    skip "gpg がない" unless system("gpg --version >/dev/null 2>&1")
    home, fpr = gpg_key("good")
    signed_commit("c-signed", home, fpr)
    @env = gpg_env(home)
    assert_equal 0, run_sync("--apply"), @last_out
    assert File.exist?(@quadlet)
  end

  def test_gpg_unsigned_commit_is_refused
    skip "gpg がない" unless system("gpg --version >/dev/null 2>&1")
    home, = gpg_key("good")
    @env = gpg_env(home)
    assert_equal 2, run_sync("--apply"), @last_out
    refute File.exist?(@quadlet)
  end

  def test_gpg_commit_from_key_outside_keyring_is_refused
    skip "gpg がない" unless system("gpg --version >/dev/null 2>&1")
    evil_home, evil_fpr = gpg_key("evil")
    signed_commit("c-evil", evil_home, evil_fpr)
    good_home, = gpg_key("good")
    @env = gpg_env(good_home)
    assert_equal 2, run_sync("--apply"), @last_out
    refute File.exist?(@quadlet)
  end
end
