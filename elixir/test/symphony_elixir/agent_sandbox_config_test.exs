defmodule SymphonyElixir.AgentSandboxConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentSandboxConfig

  test "Claude filesystem settings expose the default deny lists" do
    assert AgentSandboxConfig.deny_read_paths() == [
             "~/.ssh",
             "~/.config/gh",
             "~/.aws",
             "~/.gnupg",
             "~/Library/Application Support",
             "~/.docker"
           ]

    assert AgentSandboxConfig.deny_write_paths() == [
             "./WORKFLOW.md",
             "./symphony.yml",
             "./symphony.local.yml",
             "./.git/hooks",
             "./mise.toml",
             "./.tool-versions"
           ]

    assert AgentSandboxConfig.claude_filesystem_settings() == %{
             "denyRead" => AgentSandboxConfig.deny_read_paths(),
             "denyWrite" => AgentSandboxConfig.deny_write_paths()
           }
  end

  test "Codex allowlist config denies sensitive reads and protects workflow files from writes" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", ["github.com", "api.openai.com"])

    assert ~s(default_permissions="workspace_write") in overrides
    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s(":project_roots"={)
    assert filesystem =~ ~s("."="write")
    assert filesystem =~ ~s("WORKFLOW.md"="read")
    assert filesystem =~ ~s(".git/hooks"="read")
    assert filesystem =~ ~s("~/.ssh"="none")
    assert filesystem =~ ~s("~/Library/Application Support"="none")

    assert ~s(permissions.workspace_write.network={"enabled"=true,"mode"="limited"}) in overrides
    assert domains = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.network.domains="))
    assert domains =~ ~s("api.openai.com"="allow")
    assert domains =~ ~s("github.com"="allow")
    refute domains =~ "evil.example.com"
  end

  test "Codex open mode keeps full network mode without domain narrowing" do
    overrides = AgentSandboxConfig.codex_config_overrides("open", ["github.com"])

    assert ~s(permissions.workspace_write.network={"enabled"=true,"mode"="full"}) in overrides
    assert "permissions.workspace_write.network.domains={}" in overrides
  end

  test "Codex block mode emits limited network with an empty domain allowlist" do
    overrides = AgentSandboxConfig.codex_config_overrides("block", ["github.com"])

    assert ~s(permissions.workspace_write.network={"enabled"=true,"mode"="limited"}) in overrides
    assert "permissions.workspace_write.network.domains={}" in overrides
  end
end
