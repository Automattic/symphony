defmodule SymphonyElixir.AgentSandboxConfig do
  @moduledoc """
  Shared sandbox defaults for agent runtimes.

  Produces Claude Code `sandbox.filesystem` settings and Codex
  `permissions.workspace_write.*` `--config` overrides from a single deny
  list so both adapters stay in sync. Operator-supplied
  `workspace.sandbox.allow_read_paths` entries are subtracted from the
  shared `denyRead` set for both runtimes.

  Currently covered credential / config stores (read-deny):

    * `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.docker`
    * `~/.config/gh`, `~/.config/op`, `~/.config/gcloud`, `~/.azure`, `~/.kube`
    * `~/.netrc`, `~/.git-credentials`, `~/.npmrc`, `~/.cargo/credentials`
    * `~/.claude/.credentials.json` (Claude Code credentials)
    * `~/.claude/projects`, `~/.claude/file-history` (Claude Code session state)
    * `/etc/sudoers`, `/private/etc/sudoers`, `/var/root` (macOS admin/root state)
    * `~/Library/Application Support`, `~/Library/Keychains`, `~/Library/Preferences` (macOS app data)
    * shell and REPL history files

  Codex command sandboxing additionally denies reads of selected runtime
  files under `~/.codex` while leaving the parent Codex process able to
  authenticate before the tool sandbox applies.

  Workflow guardrail files and user persistence paths protected from writes:

    * `WORKFLOW.md`, `symphony.yml`, `symphony.local.yml`
    * `.git`, `mise.toml`, `.tool-versions`
    * shell startup files, `~/.gitconfig`, and macOS launch agent roots
  """

  @codex_profile "workspace_write"

  @deny_read_paths [
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

  @deny_write_paths [
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

  @srt_codex_runtime_write_paths [
    "~/.codex"
  ]

  @srt_codex_runtime_deny_write_paths [
    "~/.codex/auth.json",
    "~/.codex/config.toml",
    "~/.codex/AGENTS.md"
  ]

  # Codex reads these before tool sandboxing applies. Shell/tool commands should
  # not be able to read them through the workspace_write permission profile.
  @codex_runtime_deny_read_paths [
    "~/.codex/auth.json",
    "~/.codex/config.toml",
    "~/.codex/AGENTS.md"
  ]

  @doc false
  @spec deny_read_paths() :: [String.t()]
  def deny_read_paths, do: @deny_read_paths

  @doc false
  @spec deny_write_paths() :: [String.t()]
  def deny_write_paths, do: @deny_write_paths

  @doc false
  @spec claude_filesystem_settings([String.t()]) :: map()
  def claude_filesystem_settings(allow_read_paths \\ []) do
    allow_read_paths = normalize_allow_read_paths(allow_read_paths)

    %{
      "denyRead" => @deny_read_paths |> Enum.reject(&(&1 in allow_read_paths)) |> expand_home_paths(),
      "denyWrite" => expand_home_paths(@deny_write_paths)
    }
  end

  @doc false
  @spec codex_config_overrides(String.t(), [String.t()], [String.t()]) :: [String.t()]
  def codex_config_overrides(network_mode, allowed_domains, allow_read_paths \\ []) do
    [
      ~s(default_permissions="#{@codex_profile}"),
      "permissions.#{@codex_profile}.filesystem=#{codex_filesystem_policy(allow_read_paths)}",
      "permissions.#{@codex_profile}.network=#{codex_network_policy(network_mode)}",
      "permissions.#{@codex_profile}.network.domains=#{codex_network_domains(network_mode, allowed_domains)}"
    ]
  end

  @doc false
  @spec srt_settings(String.t(), [String.t()], [String.t()]) :: {:ok, map()} | {:error, term()}
  def srt_settings(network_mode, allowed_domains, denied_domains),
    do: srt_settings(network_mode, allowed_domains, denied_domains, [], [])

  @doc false
  @spec srt_settings(String.t(), [String.t()], [String.t()], [String.t()]) :: {:ok, map()} | {:error, term()}
  def srt_settings(network_mode, allowed_domains, denied_domains, allow_read_paths),
    do: srt_settings(network_mode, allowed_domains, denied_domains, allow_read_paths, [])

  @doc false
  @spec srt_settings(String.t(), [String.t()], [String.t()], [String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def srt_settings("open", _allowed_domains, _denied_domains, _allow_read_paths, _opts),
    do: {:error, :srt_open_network_unsupported}

  def srt_settings(network_mode, allowed_domains, denied_domains, allow_read_paths, opts) do
    allow_read_paths = normalize_allow_read_paths(allow_read_paths)

    {:ok,
     %{
       "network" => %{
         "allowedDomains" => srt_allowed_domains(network_mode, allowed_domains),
         "deniedDomains" => normalize_domains(denied_domains),
         "allowLocalBinding" => false
       },
       "filesystem" => %{
         "denyRead" => @deny_read_paths |> Enum.reject(&(&1 in allow_read_paths)) |> expand_home_paths(),
         "allowRead" => allow_read_paths,
         "allowWrite" => srt_allow_write_paths(Keyword.get(opts, :allow_write_paths, [])),
         "denyWrite" => srt_deny_write_paths(Keyword.get(opts, :deny_write_paths, []))
       },
       "enableWeakerNestedSandbox" => true,
       "enableWeakerNetworkIsolation" => Keyword.get(opts, :enable_weaker_network_isolation, false)
     }}
  end

  defp codex_filesystem_policy(allow_read_paths) do
    allow_read_paths = normalize_allow_read_paths(allow_read_paths)
    operator_allow_read_paths = Enum.reject(allow_read_paths, &codex_runtime_read_override_path?/1)

    project_entries =
      [{".", "write"}] ++
        Enum.map(expand_home_paths(@deny_write_paths), fn path ->
          {String.trim_leading(path, "./"), "read"}
        end)

    deny_read_paths =
      @deny_read_paths
      |> Enum.reject(fn path -> path in operator_allow_read_paths end)
      |> Kernel.++(@codex_runtime_deny_read_paths)
      |> expand_home_paths()

    deny_read_paths
    |> Enum.map(&{&1, "none"})
    |> List.insert_at(0, {":project_roots", project_entries})
    |> Kernel.++(Enum.map(operator_allow_read_paths, &{&1, "read"}))
    |> toml_inline_table()
  end

  defp codex_runtime_read_override_path?(path) do
    Enum.any?(@codex_runtime_deny_read_paths, fn denied_path ->
      path == denied_path or String.starts_with?(denied_path, path <> "/")
    end)
  end

  defp normalize_allow_read_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_allow_read_paths(_paths), do: []

  # Defense-in-depth: emit each home-relative deny entry in BOTH tilde form
  # and its `Path.expand`-resolved absolute form, so the deny list still
  # matches if a downstream sandbox layer ever compares against an already-
  # expanded path without re-expanding `~` itself. Non-tilde entries
  # (`./...`, `/...`) are left untouched.
  defp expand_home_paths(paths) do
    paths
    |> Enum.flat_map(fn
      "~/" <> _ = path -> [path, Path.expand(path)]
      other -> [other]
    end)
    |> Enum.uniq()
  end

  defp normalize_domains(domains) when is_list(domains) do
    domains
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_domains(_domains), do: []

  defp srt_allowed_domains("block", _allowed_domains), do: []
  defp srt_allowed_domains(_mode, allowed_domains), do: normalize_domains(allowed_domains)

  defp srt_allow_write_paths(extra_paths) do
    ([".", "/tmp", System.tmp_dir!()] ++ @srt_codex_runtime_write_paths ++ normalize_sandbox_paths(extra_paths))
    |> Enum.map(fn
      "." -> "."
      "~/" <> _rest = path -> path
      "/" <> _rest = path -> path
      path -> "./#{path}"
    end)
    |> Enum.uniq()
  end

  defp srt_deny_write_paths(extra_paths),
    do:
      (@deny_write_paths ++ @srt_codex_runtime_deny_write_paths ++ normalize_sandbox_paths(extra_paths))
      |> expand_home_paths()

  defp normalize_sandbox_paths(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_sandbox_paths(_paths), do: []

  defp codex_network_policy("open"), do: toml_inline_table(enabled: true, mode: "full")
  defp codex_network_policy("block"), do: toml_inline_table(enabled: false)
  defp codex_network_policy(_mode), do: toml_inline_table(enabled: true, mode: "limited")

  defp codex_network_domains("open", _allowed_domains), do: toml_inline_table([])

  defp codex_network_domains("block", _allowed_domains), do: toml_inline_table([])

  defp codex_network_domains(_mode, allowed_domains) do
    allowed_domains
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, "allow"})
    |> toml_inline_table()
  end

  defp toml_inline_table(entries) do
    entries
    |> Enum.map_join(",", fn {key, value} ->
      toml_string(to_string(key)) <> "=" <> toml_value(value)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp toml_value(value) when is_binary(value), do: toml_string(value)
  defp toml_value(value) when is_boolean(value), do: to_string(value)
  defp toml_value(value) when is_list(value), do: toml_inline_table(value)

  defp toml_string(value) when is_binary(value), do: Jason.encode!(value)
end
