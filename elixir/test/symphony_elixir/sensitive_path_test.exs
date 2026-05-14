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
