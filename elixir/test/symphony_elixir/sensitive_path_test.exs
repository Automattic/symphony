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

  test "detects expanded credential stores and leaves runtime auth stores alone" do
    denied_paths = [
      "~/.netrc",
      "~/.git-credentials",
      "~/.npmrc",
      "~/.cargo/credentials",
      "~/.claude/.credentials.json",
      "~/.claude/projects/symphony-run.jsonl",
      "~/.claude/file-history/snapshot.json",
      "~/.config/op/config",
      "~/.config/gcloud/application_default_credentials.json",
      "~/.azure/accessTokens.json",
      "~/.kube/config",
      "~/.bash_history",
      "~/.zsh_history",
      "~/.history",
      "~/.python_history",
      "~/.node_repl_history",
      "/Users/test/.netrc",
      "/Users/test/.git-credentials",
      "/Users/test/.npmrc",
      "/Users/test/.cargo/credentials",
      "/Users/test/.config/op/config",
      "/Users/test/.config/gcloud/configurations/config_default",
      "/Users/test/.azure/accessTokens.json",
      "/Users/test/.kube/config",
      "/Users/test/.bash_history"
    ]

    for path <- denied_paths do
      assert SensitivePath.secret_path(path) == path
    end

    refute SensitivePath.secret_path("~/.codex/auth.json")
    refute SensitivePath.secret_path(".npmrc")
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
