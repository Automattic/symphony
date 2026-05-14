defmodule SymphonyElixir.AgentSandboxConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentSandboxConfig
  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.Config.Schema.Workspace.Sandbox

  test "Claude filesystem settings expose the default deny lists" do
    assert AgentSandboxConfig.deny_read_paths() == [
             "~/.ssh",
             "~/.config/gh",
             "~/.aws",
             "~/.gnupg",
             "~/Library/Application Support",
             "~/.docker",
             "~/.netrc",
             "~/.git-credentials",
             "~/.npmrc",
             "~/.cargo/credentials",
             "~/.config/op",
             "~/.config/gcloud",
             "~/.azure",
             "~/.kube",
             "~/.bash_history",
             "~/.zsh_history",
             "~/.history",
             "~/.python_history",
             "~/.node_repl_history"
           ]

    refute "~/.codex" in AgentSandboxConfig.deny_read_paths()
    refute "~/.claude" in AgentSandboxConfig.deny_read_paths()

    assert AgentSandboxConfig.deny_write_paths() == [
             "./WORKFLOW.md",
             "./symphony.yml",
             "./symphony.local.yml",
             "./.claude/settings.json",
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
    assert filesystem =~ ~s(".claude/settings.json"="read")
    assert filesystem =~ ~s(".git/hooks"="read")
    assert filesystem =~ ~s("~/.ssh"="none")
    assert filesystem =~ ~s("~/.netrc"="none")
    assert filesystem =~ ~s("~/.npmrc"="none")
    assert filesystem =~ ~s("~/Library/Application Support"="none")
    refute filesystem =~ "~/.codex"
    refute filesystem =~ "~/.claude"

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

  test "Codex block mode disables network outright instead of relying on empty domains" do
    overrides = AgentSandboxConfig.codex_config_overrides("block", ["github.com"])

    assert ~s(permissions.workspace_write.network={"enabled"=false}) in overrides
    assert "permissions.workspace_write.network.domains={}" in overrides
  end

  test "Codex filesystem config allows operator overrides for default read denies" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [], ["~/.npmrc", "~/.cargo/credentials"])

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("~/.npmrc"="read")
    assert filesystem =~ ~s("~/.cargo/credentials"="read")
    refute filesystem =~ ~s("~/.npmrc"="none")
    refute filesystem =~ ~s("~/.cargo/credentials"="none")
  end

  test "Codex filesystem config normalizes malformed operator allow_read_paths" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [], ["", " ~/.npmrc ", "~/.npmrc", :bad])

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("~/.npmrc"="read")
    refute filesystem =~ ~s("~/.npmrc"="none")

    defaults = AgentSandboxConfig.codex_config_overrides("allowlist", [], :bad)
    assert default_filesystem = Enum.find(defaults, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert default_filesystem =~ ~s("~/.npmrc"="none")
  end

  test "operator workspace sandbox allow_read_paths flows into rendered Codex deny list" do
    assert {:ok, system_config} =
             SystemSchema.parse(%{
               "repos" => [%{"name" => "default"}],
               "workspace" => %{"sandbox" => %{"allow_read_paths" => ["~/.npmrc"]}},
               "agent" => %{"kind" => "codex", "command" => "codex app-server"}
             })

    assert {:ok, settings} = system_config |> SystemSchema.to_config_map() |> Schema.parse()
    assert settings.workspace.sandbox.allow_read_paths == ["~/.npmrc"]

    overrides =
      AgentSandboxConfig.codex_config_overrides(
        settings.agent.network_access.mode,
        Schema.codex_effective_network_allowed_domains(settings),
        settings.workspace.sandbox.allow_read_paths
      )

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("~/.npmrc"="read")
    refute filesystem =~ ~s("~/.npmrc"="none")
    assert filesystem =~ ~s("~/.netrc"="none")
  end

  test "workspace sandbox allow_read_paths defaults to an empty list" do
    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{allow_read_paths: nil})
      |> Ecto.Changeset.apply_changes()

    assert sandbox.allow_read_paths == []
  end
end
