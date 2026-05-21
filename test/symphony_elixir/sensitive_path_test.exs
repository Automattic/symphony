defmodule SymphonyElixir.SensitivePathTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SensitivePath

  test "detects denied secret paths from command tokens" do
    assert SensitivePath.denied_secret_path(["cat", "~/.ssh/id_rsa"]) == "~/.ssh/id_rsa"
    assert SensitivePath.denied_secret_path(["--config=/home/user/.aws/credentials"]) == "/home/user/.aws/credentials"

    assert SensitivePath.denied_secret_path(["cat", "/home/user/.config/gh/hosts.yml"]) ==
             "/home/user/.config/gh/hosts.yml"

    assert SensitivePath.denied_secret_path(["cat", "workspace/.env.local:"]) == "workspace/.env.local"
    assert SensitivePath.denied_secret_path(["cat", "cert.PEM"]) == "cert.PEM"
    assert SensitivePath.denied_secret_path(["cat", "notes.txt"]) == nil
  end

  test "detects expanded credential stores and targeted runtime auth files" do
    denied_paths = [
      "~/.netrc",
      "~/.git-credentials",
      "~/.npmrc",
      "~/.cargo/credentials",
      "~/.claude/.credentials.json",
      "~/.claude/projects/symphony-run.jsonl",
      "~/.claude/file-history/snapshot.json",
      "/etc/sudoers",
      "/etc/sudoers.d/custom",
      "/private/etc/sudoers",
      "/private/etc/sudoers.d/custom",
      "/var/root/.zsh_history",
      "/var/root/config",
      "~/.config/op/config",
      "~/.config/gcloud/application_default_credentials.json",
      "~/.azure/accessTokens.json",
      "~/.kube/config",
      "~/Library/Keychains/login.keychain-db",
      "~/.zshrc",
      "~/.zshenv",
      "~/.zprofile",
      "~/.bashrc",
      "~/.bash_profile",
      "~/.profile",
      "~/.bash_history",
      "~/.zsh_history",
      "~/.history",
      "~/.python_history",
      "~/.node_repl_history",
      "~/.codex/auth.json",
      "~/.codex/config.toml",
      "~/.codex/AGENTS.md",
      "~/.codex/cloud-requirements-cache.json",
      "/Users/test/.netrc",
      "/Users/test/.git-credentials",
      "/Users/test/.npmrc",
      "/Users/test/.cargo/credentials",
      "/Users/test/.config/op/config",
      "/Users/test/.config/gcloud/configurations/config_default",
      "/Users/test/.azure/accessTokens.json",
      "/Users/test/.kube/config",
      "/Users/test/Library/Keychains/login.keychain-db",
      "/Users/test/.zshrc",
      "/Users/test/.zshenv",
      "/Users/test/.zprofile",
      "/Users/test/.bashrc",
      "/Users/test/.bash_profile",
      "/Users/test/.profile",
      "/Users/test/.bash_history",
      "/Users/test/.codex/auth.json",
      "/Users/test/.codex/config.toml",
      "/Users/test/.codex/AGENTS.md",
      "/Users/test/.codex/cloud-requirements-cache.json"
    ]

    for path <- denied_paths do
      assert SensitivePath.secret_path(path) == path
    end

    refute SensitivePath.secret_path("~/.codex/sessions/session.jsonl")
    refute SensitivePath.secret_path(".npmrc")
    refute SensitivePath.secret_path("/private/etc/hosts")
    refute SensitivePath.secret_path("/var/log/system.log")
  end

  test "detects mounted external volume paths without broadening unrelated paths" do
    volumes_path = "/Volumes/Backup Drive/Users/alice/Documents/plain.txt"

    assert SensitivePath.secret_path(volumes_path) == volumes_path
    assert SensitivePath.denied_secret_path(["cat", volumes_path]) == volumes_path
    refute SensitivePath.secret_path("/var/log/system.log")
  end

  test "detects sensitive basenames without requiring a sensitive parent path" do
    assert SensitivePath.sensitive_basename?("/workspace/.env")
    assert SensitivePath.sensitive_basename?("/workspace/.env.production")
    assert SensitivePath.sensitive_basename?("/workspace/private.pem")
    assert SensitivePath.sensitive_basename?("/workspace/private.KEY")

    refute SensitivePath.sensitive_basename?("/workspace/screenshot.png")
    refute SensitivePath.sensitive_basename?("/workspace/keynote.txt")
  end

  test "ignores non-string and non-list inputs" do
    assert SensitivePath.denied_secret_path(:not_tokens) == nil
    assert SensitivePath.denied_secret_path([:not_a_string]) == nil
    assert SensitivePath.secret_path(:not_a_string) == nil
    refute SensitivePath.sensitive_basename?(:not_a_string)
  end
end
