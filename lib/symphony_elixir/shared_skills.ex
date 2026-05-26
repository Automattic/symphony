defmodule SymphonyElixir.SharedSkills do
  @moduledoc """
  Repo-agnostic skills (`commit`, `pull`, `linear`) that Symphony provisions into
  every agent session from outside the workspace worktree.

  Symphony's agent runs `cd`'d into a per-issue clone of the *target* repo, so a
  skill only lives in that worktree if the target repo ships it. Copying these
  files into the worktree would dirty the tree and trip scope-check / diff-review
  gates. Instead Symphony materializes them in the agent's managed home:

    * Codex discovers user-scope skills under `$CODEX_HOME/skills/<name>/SKILL.md`,
      and Symphony already writes a per-session `CODEX_HOME`.
    * Claude loads a session-only plugin via `--plugin-dir`, so Symphony writes a
      plugin tree (`.claude-plugin/plugin.json` + `skills/<name>/SKILL.md`) next to
      the other Claude runtime files and points the CLI at it.

  The `SKILL.md` bytes are embedded at compile time via `@external_resource` so
  they ride along even in escript builds where `priv/` is dropped (mirroring
  `SymphonyElixir.McpServer`'s shim embedding).
  """

  @plugin_name "symphony-shared-skills"
  @plugin_version "0.1.0"
  @shared_skill_names ~w(commit pull linear)
  @skills_source_root Path.expand(Path.join([__DIR__, "..", "..", "priv", "skills"]))

  for name <- @shared_skill_names do
    @external_resource Path.join([@skills_source_root, name, "SKILL.md"])
  end

  @skill_contents (for name <- @shared_skill_names, into: %{} do
                     {name, File.read!(Path.join([@skills_source_root, name, "SKILL.md"]))}
                   end)

  @doc "Names of the shared skills, in declaration order."
  @spec names() :: [String.t()]
  def names, do: @shared_skill_names

  @doc "Plugin name advertised to Claude via the generated plugin manifest."
  @spec plugin_name() :: String.t()
  def plugin_name, do: @plugin_name

  @doc """
  Absolute `{path, contents}` pairs to materialize the shared skills under a Codex
  `CODEX_HOME`, where Codex discovers them at user scope.
  """
  @spec codex_home_files(Path.t()) :: [{Path.t(), binary()}]
  def codex_home_files(codex_home) when is_binary(codex_home) do
    Enum.map(@shared_skill_names, fn name ->
      {Path.join([codex_home, "skills", name, "SKILL.md"]), Map.fetch!(@skill_contents, name)}
    end)
  end

  @doc """
  Absolute `{path, contents}` pairs for a Claude `--plugin-dir` plugin tree: the
  plugin manifest plus one `SKILL.md` per shared skill.
  """
  @spec claude_plugin_files(Path.t()) :: [{Path.t(), binary()}]
  def claude_plugin_files(plugin_dir) when is_binary(plugin_dir) do
    manifest = {Path.join([plugin_dir, ".claude-plugin", "plugin.json"]), plugin_manifest_json()}

    skills =
      Enum.map(@shared_skill_names, fn name ->
        {Path.join([plugin_dir, "skills", name, "SKILL.md"]), Map.fetch!(@skill_contents, name)}
      end)

    [manifest | skills]
  end

  @doc """
  Writes `{path, contents}` pairs to the local filesystem, creating parent dirs and locking each
  file to `0600`. Used by the local Codex provisioning; the remote paths emit equivalent shell
  commands from the same `*_files/1` lists.
  """
  @spec write_local_files([{Path.t(), binary()}]) ::
          :ok | {:error, {:shared_skill_write_failed, Path.t(), term()}}
  def write_local_files(files) when is_list(files) do
    Enum.reduce_while(files, :ok, fn {path, contents}, :ok ->
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, contents),
           :ok <- File.chmod(path, 0o600) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:shared_skill_write_failed, path, reason}}}
      end
    end)
  end

  @doc "JSON manifest written to `.claude-plugin/plugin.json` for the shared-skills plugin."
  @spec plugin_manifest_json() :: binary()
  def plugin_manifest_json do
    Jason.encode!(%{
      "name" => @plugin_name,
      "version" => @plugin_version,
      "description" => "Symphony-provided repo-agnostic skills: #{Enum.join(@shared_skill_names, ", ")}."
    })
  end
end
