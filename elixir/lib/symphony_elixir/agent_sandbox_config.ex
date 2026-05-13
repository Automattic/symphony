defmodule SymphonyElixir.AgentSandboxConfig do
  @moduledoc """
  Shared sandbox defaults for agent runtimes.

  Produces Claude Code `sandbox.filesystem` settings and Codex
  `permissions.workspace_write.*` `--config` overrides from a single deny
  list so both adapters stay in sync.

  Currently covered credential / config stores (read-deny):

    * `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.docker`
    * `~/.config/gh`
    * `~/Library/Application Support` (macOS app data)

  Workflow guardrail files protected from writes (relative to workspace):

    * `WORKFLOW.md`, `symphony.yml`, `symphony.local.yml`
    * `.git/hooks`, `mise.toml`, `.tool-versions`

  Known gaps not covered by the default deny list — add explicitly if your
  environment uses them: `~/.netrc`, `~/.kube`, `~/.config/op`,
  `~/.config/gcloud`, `~/.azure`, `~/.npmrc`, `~/.cargo/credentials`,
  shell history files.
  """

  @codex_profile "workspace_write"

  @deny_read_paths [
    "~/.ssh",
    "~/.config/gh",
    "~/.aws",
    "~/.gnupg",
    "~/Library/Application Support",
    "~/.docker"
  ]

  @deny_write_paths [
    "./WORKFLOW.md",
    "./symphony.yml",
    "./symphony.local.yml",
    "./.git/hooks",
    "./mise.toml",
    "./.tool-versions"
  ]

  @doc false
  @spec deny_read_paths() :: [String.t()]
  def deny_read_paths, do: @deny_read_paths

  @doc false
  @spec deny_write_paths() :: [String.t()]
  def deny_write_paths, do: @deny_write_paths

  @doc false
  @spec claude_filesystem_settings() :: map()
  def claude_filesystem_settings do
    %{
      "denyRead" => @deny_read_paths,
      "denyWrite" => @deny_write_paths
    }
  end

  @doc false
  @spec codex_config_overrides(String.t(), [String.t()]) :: [String.t()]
  def codex_config_overrides(network_mode, allowed_domains) do
    [
      ~s(default_permissions="#{@codex_profile}"),
      "permissions.#{@codex_profile}.filesystem=#{codex_filesystem_policy()}",
      "permissions.#{@codex_profile}.network=#{codex_network_policy(network_mode)}",
      "permissions.#{@codex_profile}.network.domains=#{codex_network_domains(network_mode, allowed_domains)}"
    ]
  end

  defp codex_filesystem_policy do
    project_entries =
      [{".", "write"}] ++
        Enum.map(@deny_write_paths, fn path ->
          {String.trim_leading(path, "./"), "read"}
        end)

    @deny_read_paths
    |> Enum.map(&{&1, "none"})
    |> List.insert_at(0, {":project_roots", project_entries})
    |> toml_inline_table()
  end

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
