defmodule SymphonyElixir.AgentSandboxConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentSandboxConfig
  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.Config.Schema.Workspace.Sandbox

  @persistence_deny_write_paths [
    "~/.zshrc",
    "~/.zshenv",
    "~/.zprofile",
    "~/.bashrc",
    "~/.bash_profile",
    "~/.profile",
    "~/.gitconfig",
    "~/Library/LaunchAgents",
    "~/Library/LaunchDaemons"
  ]

  test "Claude filesystem settings expose the default deny lists" do
    assert AgentSandboxConfig.deny_read_paths() == [
             "/Volumes",
             "~/.ssh",
             "~/.config/gh",
             "~/.claude/.credentials.json",
             "~/.claude/projects",
             "~/.claude/file-history",
             "/etc/sudoers",
             "/etc/sudoers.d",
             "/private/etc/sudoers",
             "/private/etc/sudoers.d",
             "/var/root",
             "~/.aws",
             "~/.gnupg",
             "~/Library/Application Support",
             "~/Library/Keychains",
             "~/Library/Preferences",
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
             "./.git",
             "./mise.toml",
             "./.tool-versions",
             "~/.zshrc",
             "~/.zshenv",
             "~/.zprofile",
             "~/.bashrc",
             "~/.bash_profile",
             "~/.profile",
             "~/.gitconfig",
             "~/Library/LaunchAgents",
             "~/Library/LaunchDaemons"
           ]

    for path <- @persistence_deny_write_paths do
      assert path in AgentSandboxConfig.deny_write_paths()
    end

    assert "/Volumes" in AgentSandboxConfig.deny_read_paths()
    assert "~/Library/Keychains" in AgentSandboxConfig.deny_read_paths()
    assert "~/Library/Preferences" in AgentSandboxConfig.deny_read_paths()
    refute "~/.config/gh" in AgentSandboxConfig.deny_write_paths()

    assert AgentSandboxConfig.claude_filesystem_settings() == %{
             "denyRead" => AgentSandboxConfig.deny_read_paths(),
             "denyWrite" => AgentSandboxConfig.deny_write_paths()
           }
  end

  test "Claude filesystem settings drop operator allow_read_paths from denyRead" do
    settings = AgentSandboxConfig.claude_filesystem_settings(["~/.npmrc", "~/.cargo/credentials", "~/.claude/projects"])

    refute "~/.npmrc" in settings["denyRead"]
    refute "~/.cargo/credentials" in settings["denyRead"]
    refute "~/.claude/projects" in settings["denyRead"]
    assert "~/.ssh" in settings["denyRead"]
    assert "~/.claude/.credentials.json" in settings["denyRead"]
    assert settings["denyWrite"] == AgentSandboxConfig.deny_write_paths()
  end

  test "Claude filesystem settings normalize malformed operator allow_read_paths" do
    settings = AgentSandboxConfig.claude_filesystem_settings(["", " ~/.npmrc ", "~/.npmrc", :bad])
    refute "~/.npmrc" in settings["denyRead"]

    defaults = AgentSandboxConfig.claude_filesystem_settings(:bad)
    assert "~/.npmrc" in defaults["denyRead"]
  end

  test "Codex allowlist config denies sensitive reads and protects workflow files from writes" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", ["github.com", "api.openai.com"])

    assert ~s(default_permissions="workspace_write") in overrides
    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s(":project_roots"={)
    assert filesystem =~ ~s("."="write")
    assert filesystem =~ ~s("WORKFLOW.md"="read")
    assert filesystem =~ ~s(".claude/settings.json"="read")
    assert filesystem =~ ~s(".git"="read")
    assert filesystem =~ ~s("/Volumes"="none")
    assert filesystem =~ ~s("~/.ssh"="none")
    assert filesystem =~ ~s("~/.claude/.credentials.json"="none")
    assert filesystem =~ ~s("~/.claude/projects"="none")
    assert filesystem =~ ~s("~/.claude/file-history"="none")
    assert filesystem =~ ~s("~/.netrc"="none")
    assert filesystem =~ ~s("~/.npmrc"="none")
    assert filesystem =~ ~s("/etc/sudoers"="none")
    assert filesystem =~ ~s("/private/etc/sudoers"="none")
    assert filesystem =~ ~s("/var/root"="none")
    assert filesystem =~ ~s("~/Library/Application Support"="none")
    assert filesystem =~ ~s("~/Library/Keychains"="none")
    assert filesystem =~ ~s("~/Library/Preferences"="none")
    assert filesystem =~ ~s("~/.zshrc"="read")
    assert filesystem =~ ~s("~/Library/LaunchAgents"="read")
    refute filesystem =~ "~/.codex"

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

  test "srt settings render network and filesystem guardrails" do
    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings(
               "allowlist",
               ["GitHub.com", "api.openai.com", "github.com"],
               [" API.GitHub.com "],
               ["~/.npmrc"]
             )

    assert settings["network"] == %{
             "allowedDomains" => ["github.com", "api.openai.com"],
             "deniedDomains" => ["api.github.com"],
             "allowLocalBinding" => false
           }

    assert settings["filesystem"]["allowRead"] == ["~/.npmrc"]
    assert "." in settings["filesystem"]["allowWrite"]
    assert System.tmp_dir!() in settings["filesystem"]["allowWrite"]
    assert "~/.codex" in settings["filesystem"]["allowWrite"]
    assert "/Volumes" in settings["filesystem"]["denyRead"]
    refute "~/.npmrc" in settings["filesystem"]["denyRead"]
    assert "~/.ssh" in settings["filesystem"]["denyRead"]
    assert "~/.claude/.credentials.json" in settings["filesystem"]["denyRead"]
    assert "~/.claude/projects" in settings["filesystem"]["denyRead"]
    assert "~/.claude/file-history" in settings["filesystem"]["denyRead"]
    assert "/private/etc/sudoers" in settings["filesystem"]["denyRead"]
    assert "/var/root" in settings["filesystem"]["denyRead"]
    assert "./WORKFLOW.md" in settings["filesystem"]["denyWrite"]
    assert "./.git" in settings["filesystem"]["denyWrite"]
    refute "/Volumes" in settings["filesystem"]["denyWrite"]

    for path <- @persistence_deny_write_paths do
      assert path in settings["filesystem"]["denyWrite"]
    end

    assert "~/.codex/auth.json" in settings["filesystem"]["denyWrite"]
    assert "~/.codex/config.toml" in settings["filesystem"]["denyWrite"]
    assert "~/.codex/AGENTS.md" in settings["filesystem"]["denyWrite"]
    refute "~/.codex/skills" in settings["filesystem"]["denyWrite"]
    assert settings["enableWeakerNestedSandbox"] == true
    assert settings["enableWeakerNetworkIsolation"] == false
  end

  test "srt settings accept extra read and write paths for runtime-managed roots" do
    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings(
               "allowlist",
               [],
               [],
               ["~/.ssh/known_hosts"],
               allow_write_paths: ["/repo/.git/worktrees/MT-1", "relative/git"],
               deny_write_paths: ["/repo/.git/hooks"]
             )

    assert "~/.ssh" in settings["filesystem"]["denyRead"]
    assert "~/.ssh/known_hosts" in settings["filesystem"]["allowRead"]
    assert "/repo/.git/worktrees/MT-1" in settings["filesystem"]["allowWrite"]
    assert "./relative/git" in settings["filesystem"]["allowWrite"]
    assert "/repo/.git/hooks" in settings["filesystem"]["denyWrite"]
  end

  test "srt settings normalize malformed domain and sandbox path inputs" do
    assert {:ok, settings} =
             AgentSandboxConfig.srt_settings(
               "allowlist",
               :bad_allowed_domains,
               :bad_denied_domains,
               :bad_allow_read_paths,
               allow_write_paths: :bad_allow_write_paths,
               deny_write_paths: :bad_deny_write_paths
             )

    assert settings["network"]["allowedDomains"] == []
    assert settings["network"]["deniedDomains"] == []
    assert settings["filesystem"]["allowRead"] == []
    assert "." in settings["filesystem"]["allowWrite"]
    assert "~/.codex" in settings["filesystem"]["allowWrite"]
    assert settings["filesystem"]["denyWrite"] == AgentSandboxConfig.deny_write_paths() ++ ["~/.codex/auth.json", "~/.codex/config.toml", "~/.codex/AGENTS.md"]
  end

  test "srt settings map open and block network modes" do
    assert {:error, :srt_open_network_unsupported} = AgentSandboxConfig.srt_settings("open", ["github.com"], [])
    assert {:ok, %{"network" => %{"allowedDomains" => []}}} = AgentSandboxConfig.srt_settings("block", ["github.com"], [])
  end

  test "srt settings normalize malformed domains and relative temp dirs" do
    relative_tmp = "symphony-relative-tmp-#{System.unique_integer([:positive])}"
    previous_tmpdir = System.get_env("TMPDIR")

    on_exit(fn ->
      restore_env("TMPDIR", previous_tmpdir)
      File.rm_rf(relative_tmp)
    end)

    File.mkdir_p!(relative_tmp)
    System.put_env("TMPDIR", relative_tmp)

    assert {:ok, settings} = AgentSandboxConfig.srt_settings("allowlist", :bad, :bad)
    assert settings["network"]["allowedDomains"] == []
    assert settings["network"]["deniedDomains"] == []
    assert "./#{relative_tmp}" in settings["filesystem"]["allowWrite"]
  end

  test "Codex filesystem config allows operator overrides for default read denies" do
    overrides = AgentSandboxConfig.codex_config_overrides("allowlist", [], ["~/.npmrc", "~/.cargo/credentials", "~/.claude/projects"])

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("~/.npmrc"="read")
    assert filesystem =~ ~s("~/.cargo/credentials"="read")
    assert filesystem =~ ~s("~/.claude/projects"="read")
    refute filesystem =~ ~s("~/.npmrc"="none")
    refute filesystem =~ ~s("~/.cargo/credentials"="none")
    refute filesystem =~ ~s("~/.claude/projects"="none")
  end

  test "Codex filesystem config renders runtime writable roots in the permission profile" do
    overrides =
      AgentSandboxConfig.codex_config_overrides(
        "allowlist",
        [],
        ["~/.npmrc"],
        ["/repo/.git/worktrees/MT-1", "relative/cache", "", :bad]
      )

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("/repo/.git/worktrees/MT-1"="write")
    assert filesystem =~ ~s("relative/cache"="write")
    assert filesystem =~ ~s("~/.npmrc"="read")
    assert filesystem =~ ~s("~/.ssh"="none")
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
               "workspace" => %{"sandbox" => %{"allow_read_paths" => ["~/.npmrc", "~/.claude/projects"]}},
               "agent" => %{"kind" => "codex", "command" => "codex app-server"}
             })

    assert {:ok, settings} = system_config |> SystemSchema.to_config_map() |> Schema.parse()
    assert settings.workspace.sandbox.allow_read_paths == ["~/.npmrc", "~/.claude/projects"]

    overrides =
      AgentSandboxConfig.codex_config_overrides(
        settings.agent.network_access.mode,
        Schema.codex_effective_network_allowed_domains(settings),
        settings.workspace.sandbox.allow_read_paths
      )

    assert filesystem = Enum.find(overrides, &String.starts_with?(&1, "permissions.workspace_write.filesystem="))
    assert filesystem =~ ~s("~/.npmrc"="read")
    assert filesystem =~ ~s("~/.claude/projects"="read")
    refute filesystem =~ ~s("~/.npmrc"="none")
    refute filesystem =~ ~s("~/.claude/projects"="none")
    assert filesystem =~ ~s("~/.netrc"="none")
    assert filesystem =~ ~s("~/.claude/.credentials.json"="none")

    claude_settings = AgentSandboxConfig.claude_filesystem_settings(settings.workspace.sandbox.allow_read_paths)
    refute "~/.npmrc" in claude_settings["denyRead"]
    refute "~/.claude/projects" in claude_settings["denyRead"]
    assert "~/.netrc" in claude_settings["denyRead"]
    assert "~/.claude/.credentials.json" in claude_settings["denyRead"]
  end

  test "workspace sandbox allow_read_paths defaults to an empty list" do
    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{allow_read_paths: nil})
      |> Ecto.Changeset.apply_changes()

    assert sandbox.allow_read_paths == []
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
