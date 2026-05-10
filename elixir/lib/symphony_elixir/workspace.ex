defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil
  @type lifecycle_action :: %{
          optional(:repo_key) => String.t(),
          optional(:identifier) => String.t(),
          optional(:path) => Path.t(),
          optional(:destination) => Path.t(),
          optional(:worker_host) => worker_host(),
          optional(:action) => :deleted | :logged | :trashed | :failed,
          optional(:reason) => :age_gc | :orphan,
          optional(:error) => term()
        }

  @spec safe_identifier(term()) :: String.t()
  def safe_identifier(identifier) do
    identifier =
      cond do
        is_binary(identifier) and identifier != "" -> identifier
        is_nil(identifier) -> "issue"
        true -> to_string(identifier)
      end

    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  @spec create_for_issue(map() | String.t() | nil, worker_host(), String.t() | nil) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil, repo_key \\ nil) do
    issue_context = issue_context(issue_or_identifier, repo_key)

    try do
      safe_repo_key = safe_identifier(issue_context.repo_key)
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_repo_key, safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, issue_context, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, issue_context, worker_host) do
    settings = settings_for_issue_context(issue_context)

    case settings.workspace.strategy do
      "worktree" ->
        ensure_worktree_workspace(workspace, issue_context, worker_host, settings)

      _strategy ->
        ensure_directory_workspace(workspace, issue_context, worker_host, settings)
    end
  end

  defp ensure_directory_workspace(workspace, _issue_context, nil, _settings) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_directory_workspace(workspace, _issue_context, worker_host, settings) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, settings.hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_worktree_workspace(workspace, issue_context, nil, settings) do
    with {:ok, repo} <- local_worktree_repo(settings),
         :ok <- maybe_fetch_worktree_repo(repo, settings),
         {:ok, created?} <- add_or_reuse_local_worktree(repo, workspace, worktree_branch(issue_context)) do
      {:ok, workspace, created?}
    end
  end

  defp ensure_worktree_workspace(workspace, issue_context, worker_host, settings) when is_binary(worker_host) do
    branch = worktree_branch(issue_context)

    script =
      [
        "set -eu",
        remote_shell_assign("repo", settings.workspace.repo || ""),
        remote_shell_assign("workspace", workspace),
        "branch=#{shell_escape(branch)}",
        "if [ -z \"$repo\" ]; then",
        "  echo \"workspace_repo_missing: workspace.repo is required for worktree strategy\"",
        "  exit 41",
        "fi",
        "if [ ! -d \"$repo\" ]; then",
        "  echo \"workspace_repo_missing: $repo\"",
        "  exit 41",
        "fi",
        "git -C \"$repo\" rev-parse --git-dir >/dev/null",
        settings.workspace.fetch_before_dispatch && "git -C \"$repo\" fetch origin",
        "if [ -d \"$workspace\" ]; then",
        "  if ! worktrees=$(git -C \"$repo\" worktree list --porcelain); then",
        "    echo \"workspace_worktree_list_failed: $repo\"",
        "    exit 43",
        "  fi",
        "  registered=$(printf '%s\\n' \"$worktrees\" | awk '/^worktree / {print substr($0, 10)}' | grep -Fx \"$workspace\" || true)",
        "  if [ -z \"$registered\" ]; then",
        "    echo \"workspace_not_registered_worktree: $workspace\"",
        "    exit 42",
        "  fi",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  #{remote_worktree_add_command()}",
        "  created=1",
        "else",
        "  #{remote_worktree_add_command()}",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 in ["", nil, false]))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, settings.hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  defp local_worktree_repo(settings) do
    repo = settings.workspace.repo

    if is_binary(repo) and String.trim(repo) != "" do
      {:ok, Path.expand(repo)}
    else
      {:error, :missing_workspace_repo}
    end
  end

  defp maybe_fetch_worktree_repo(repo, settings) do
    case settings.workspace.fetch_before_dispatch do
      true -> run_git(repo, ["fetch", "origin"])
      false -> :ok
    end
  end

  defp add_or_reuse_local_worktree(repo, workspace, branch) do
    cond do
      File.dir?(workspace) ->
        case registered_worktree?(repo, workspace) do
          true -> {:ok, false}
          false -> {:error, {:workspace_not_registered_worktree, workspace}}
        end

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        add_local_worktree(repo, workspace, branch)

      true ->
        add_local_worktree(repo, workspace, branch)
    end
  end

  defp add_local_worktree(repo, workspace, branch) do
    File.mkdir_p!(Path.dirname(workspace))

    with :ok <- run_git(repo, worktree_add_args(repo, workspace, branch)) do
      {:ok, true}
    end
  end

  defp worktree_add_args(repo, workspace, branch) do
    case git_branch_exists?(repo, branch) do
      true -> ["worktree", "add", workspace, branch]
      false -> ["worktree", "add", "-b", branch, workspace, "HEAD"]
    end
  end

  defp remote_worktree_add_command do
    "if git -C \"$repo\" rev-parse --verify \"refs/heads/$branch\" >/dev/null 2>&1; then git -C \"$repo\" worktree add \"$workspace\" \"$branch\"; else git -C \"$repo\" worktree add -b \"$branch\" \"$workspace\" HEAD; fi"
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    issue_context = workspace_issue_context(workspace)

    remove_workspace(workspace, issue_context, nil)
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    issue_context = workspace_issue_context(workspace)

    remove_workspace(workspace, issue_context, worker_host)
  end

  defp remove_workspace(workspace, issue_context, nil) do
    settings = settings_for_issue_context(issue_context)

    if settings.workspace.strategy == "worktree" do
      remove_worktree_workspace(workspace, issue_context, nil, settings)
    else
      remove_directory_workspace(workspace, issue_context, nil, settings)
    end
  end

  defp remove_workspace(workspace, issue_context, worker_host) when is_binary(worker_host) do
    settings = settings_for_issue_context(issue_context)

    if settings.workspace.strategy == "worktree" do
      remove_worktree_workspace(workspace, issue_context, worker_host, settings)
    else
      remove_directory_workspace(workspace, issue_context, worker_host, settings)
    end
  end

  defp remove_directory_workspace(workspace, issue_context, nil, _settings) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, issue_context, nil)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  defp remove_directory_workspace(workspace, issue_context, worker_host, settings) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, issue_context, worker_host)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, settings.hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp remove_worktree_workspace(workspace, issue_context, nil, settings) do
    with {:ok, repo} <- local_worktree_repo(settings),
         :ok <- validate_workspace_path(workspace, nil),
         :ok <- remove_local_worktree(repo, workspace, issue_context) do
      {:ok, [workspace]}
    else
      {:error, reason, output} -> {:error, reason, output}
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_worktree_workspace(workspace, issue_context, worker_host, settings) when is_binary(worker_host) do
    branch = worktree_branch(issue_context)

    maybe_run_before_remove_hook(workspace, issue_context, worker_host)

    script =
      [
        "set -eu",
        remote_shell_assign("repo", settings.workspace.repo || ""),
        remote_shell_assign("workspace", workspace),
        "branch=#{shell_escape(branch)}",
        "if [ -z \"$repo\" ]; then",
        "  echo \"workspace_repo_missing: workspace.repo is required for worktree strategy\"",
        "  exit 41",
        "fi",
        "if [ ! -d \"$repo\" ]; then",
        "  echo \"workspace_repo_missing: $repo\"",
        "  exit 41",
        "fi",
        "git -C \"$repo\" rev-parse --git-dir >/dev/null",
        "if ! worktrees=$(git -C \"$repo\" worktree list --porcelain); then",
        "  echo \"workspace_worktree_list_failed: $repo\"",
        "  exit 43",
        "fi",
        "registered=$(printf '%s\\n' \"$worktrees\" | awk '/^worktree / {print substr($0, 10)}' | grep -Fx \"$workspace\" || true)",
        "if [ -n \"$registered\" ]; then",
        "  git -C \"$repo\" worktree remove --force \"$workspace\"",
        "elif [ -e \"$workspace\" ]; then",
        "  echo \"workspace_not_registered_worktree: $workspace\"",
        "  exit 42",
        "fi",
        "if git -C \"$repo\" rev-parse --verify \"refs/heads/$branch\" >/dev/null 2>&1; then",
        "  git -C \"$repo\" branch -D \"$branch\"",
        "fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, settings.hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(%{identifier: identifier} = issue, worker_host)
      when is_binary(identifier) and is_binary(worker_host) do
    remove_issue_workspace(identifier, issue_context(issue), worker_host)
  end

  def remove_issue_workspaces(%{identifier: identifier} = issue, nil) when is_binary(identifier) do
    issue_context = issue_context(issue)

    case settings_for_issue_context(issue_context).worker.ssh_hosts do
      [] ->
        remove_issue_workspace(identifier, issue_context, nil)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(issue, &1))
    end

    :ok
  end

  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    remove_issue_workspace(identifier, issue_context(identifier), worker_host)
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    issue_context = issue_context(identifier)

    case settings_for_issue_context(issue_context).worker.ssh_hosts do
      [] ->
        remove_issue_workspace(identifier, issue_context, nil)

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspace(identifier, issue_context, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec free_bytes() :: {:ok, non_neg_integer()} | {:error, term()}
  def free_bytes, do: free_bytes(nil)

  @spec free_bytes(worker_host()) :: {:ok, non_neg_integer()} | {:error, term()}
  def free_bytes(nil) do
    root = Config.settings!().workspace.root

    with :ok <- File.mkdir_p(root),
         {output, 0} <- System.cmd("df", ["-Pk", root], stderr_to_stdout: true),
         {:ok, bytes} <- parse_df_available_bytes(output) do
      {:ok, bytes}
    else
      {:error, reason} ->
        {:error, {:workspace_free_space_check_failed, root, reason}}

      {output, status} ->
        {:error, {:workspace_free_space_check_failed, root, status, output}}
    end
  end

  def free_bytes(worker_host) when is_binary(worker_host) do
    root = Config.settings!().workspace.root

    script =
      [
        "set -eu",
        remote_shell_assign("root", root),
        "mkdir -p \"$root\"",
        "df -Pk \"$root\" | awk 'NR==2 {print $4}'"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_df_available_bytes(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_free_space_check_failed, worker_host, root, status, output}}

      {:error, reason} ->
        {:error, {:workspace_free_space_check_failed, worker_host, root, reason}}
    end
  end

  @spec reclaim_stale_workspaces() :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces, do: reclaim_stale_workspaces(Config.repo_key!(), MapSet.new(), DateTime.utc_now())

  @spec reclaim_stale_workspaces(term()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces(protected_identifiers),
    do: reclaim_stale_workspaces(Config.repo_key!(), protected_identifiers, DateTime.utc_now())

  @spec reclaim_stale_workspaces(String.t(), term()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces(repo_key, protected_identifiers) when is_binary(repo_key),
    do: reclaim_stale_workspaces(repo_key, protected_identifiers, DateTime.utc_now())

  @spec reclaim_stale_workspaces(term(), DateTime.t()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces(protected_identifiers, %DateTime{} = now) do
    reclaim_stale_workspaces(Config.repo_key!(), protected_identifiers, now)
  end

  @spec reclaim_stale_workspaces(String.t(), term(), DateTime.t()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def reclaim_stale_workspaces(repo_key, protected_identifiers, %DateTime{} = now) when is_binary(repo_key) do
    lifecycle = Config.settings!().workspace.lifecycle

    if lifecycle.age_gc_enabled == true do
      protected = normalize_identifier_set(protected_identifiers)
      cutoff = DateTime.to_unix(now) - lifecycle.max_age_days * 86_400

      with {:ok, entries} <- local_workspace_entries(repo_key) do
        actions =
          entries
          |> Enum.filter(&(&1.mtime <= cutoff))
          |> Enum.reject(&MapSet.member?(protected, &1.identifier))
          |> Enum.map(&delete_lifecycle_workspace(&1, :age_gc))

        {:ok, actions}
      end
    else
      {:ok, []}
    end
  end

  @spec sweep_orphan_workspaces(Enumerable.t()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def sweep_orphan_workspaces(tracked_identifiers) do
    sweep_orphan_workspaces(Config.repo_key!(), tracked_identifiers)
  end

  @spec sweep_orphan_workspaces(String.t(), Enumerable.t()) :: {:ok, [lifecycle_action()]} | {:error, term()}
  def sweep_orphan_workspaces(repo_key, tracked_identifiers) when is_binary(repo_key) do
    lifecycle = Config.settings!().workspace.lifecycle
    tracked = normalize_identifier_set(tracked_identifiers)

    with {:ok, entries} <- local_workspace_entries(repo_key) do
      actions =
        entries
        |> Enum.reject(&MapSet.member?(tracked, &1.identifier))
        |> Enum.map(&perform_orphan_action(&1, lifecycle))

      {:ok, actions}
    end
  end

  @spec local_workspace_entries() :: {:ok, [map()]} | {:error, term()}
  def local_workspace_entries do
    local_workspace_entries(Config.repo_key!())
  end

  @spec local_workspace_entries(String.t()) :: {:ok, [map()]} | {:error, term()}
  def local_workspace_entries(repo_key) when is_binary(repo_key) do
    settings = Config.settings!()
    safe_repo_key = safe_identifier(repo_key)
    root = Path.join(settings.workspace.root, safe_repo_key)
    trash_dir = settings.workspace.lifecycle.trash_dir |> Path.split() |> List.first()

    cond do
      !File.exists?(root) ->
        {:ok, []}

      !File.dir?(root) ->
        {:error, {:workspace_root_not_directory, root}}

      true ->
        case File.ls(root) do
          {:ok, names} ->
            entries =
              names
              |> Enum.reject(&(&1 == trash_dir))
              |> Enum.flat_map(&local_workspace_entry(root, safe_repo_key, &1))

            {:ok, entries}

          {:error, reason} ->
            {:error, {:workspace_root_list_failed, root, reason}}
        end
    end
  end

  defp local_workspace_entry(root, repo_key, name) do
    path = Path.join(root, name)

    case File.stat(path, time: :posix) do
      {:ok, %{type: :directory, mtime: mtime}} when is_integer(mtime) ->
        [%{repo_key: repo_key, identifier: safe_identifier(name), name: name, path: path, mtime: mtime}]

      _ ->
        []
    end
  end

  defp normalize_identifier_set(identifiers) do
    identifiers
    |> Enum.flat_map(fn
      identifier when is_binary(identifier) -> [safe_identifier(identifier)]
      %{identifier: identifier} when is_binary(identifier) -> [safe_identifier(identifier)]
      %{issue_identifier: identifier} when is_binary(identifier) -> [safe_identifier(identifier)]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp perform_orphan_action(entry, %{orphan_action: "delete"}) do
    delete_lifecycle_workspace(entry, :orphan)
  end

  defp perform_orphan_action(entry, %{orphan_action: "trash"} = lifecycle) do
    trash_lifecycle_workspace(entry, :orphan, lifecycle)
  end

  defp perform_orphan_action(entry, _lifecycle) do
    Logger.warning("Workspace orphan found repo_key=#{entry.repo_key} identifier=#{entry.identifier} workspace=#{entry.path} action=log")

    %{
      repo_key: entry.repo_key,
      identifier: entry.identifier,
      path: entry.path,
      worker_host: nil,
      action: :logged,
      reason: :orphan
    }
  end

  defp delete_lifecycle_workspace(entry, reason) do
    case remove(entry.path) do
      {:ok, _removed_paths} ->
        Logger.warning("Workspace lifecycle removed repo_key=#{entry.repo_key} identifier=#{entry.identifier} workspace=#{entry.path} reason=#{reason} action=delete")

        %{
          repo_key: entry.repo_key,
          identifier: entry.identifier,
          path: entry.path,
          worker_host: nil,
          action: :deleted,
          reason: reason
        }

      {:error, error, output} ->
        log_workspace_removal_failure(entry.path, issue_context(%{identifier: entry.identifier, repo_key: entry.repo_key}), nil, error, output)

        %{
          repo_key: entry.repo_key,
          identifier: entry.identifier,
          path: entry.path,
          worker_host: nil,
          action: :failed,
          reason: reason,
          error: error
        }
    end
  end

  defp trash_lifecycle_workspace(entry, reason, lifecycle) do
    root = Config.settings!().workspace.root
    trash_root = Path.join([root, entry.repo_key, lifecycle.trash_dir])
    destination = unique_trash_destination(trash_root, entry.identifier)

    with :ok <- validate_workspace_path(entry.path, nil),
         :ok <- File.mkdir_p(trash_root),
         :ok <- File.rename(entry.path, destination) do
      Logger.warning("Workspace orphan found repo_key=#{entry.repo_key} identifier=#{entry.identifier} workspace=#{entry.path} action=trash destination=#{destination}")

      %{
        repo_key: entry.repo_key,
        identifier: entry.identifier,
        path: entry.path,
        destination: destination,
        worker_host: nil,
        action: :trashed,
        reason: reason
      }
    else
      {:error, error} ->
        Logger.warning("Workspace lifecycle trash failed repo_key=#{entry.repo_key} identifier=#{entry.identifier} workspace=#{entry.path} destination=#{destination} reason=#{inspect(error)}")

        %{
          repo_key: entry.repo_key,
          identifier: entry.identifier,
          path: entry.path,
          destination: destination,
          worker_host: nil,
          action: :failed,
          reason: reason,
          error: error
        }
    end
  end

  defp unique_trash_destination(trash_root, identifier) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H%M%S")
    base = Path.join(trash_root, "#{timestamp}-#{identifier}")

    if File.exists?(base) do
      Path.join(trash_root, "#{timestamp}-#{System.unique_integer([:positive])}-#{identifier}")
    else
      base
    end
  end

  defp parse_df_available_bytes(output) do
    output
    |> IO.iodata_to_binary()
    |> String.split("\n", trim: true)
    |> Enum.find_value(&parse_df_available_line/1)
    |> case do
      blocks when is_integer(blocks) and blocks >= 0 -> {:ok, blocks * 1024}
      _ -> {:error, {:invalid_df_output, output}}
    end
  end

  defp parse_df_available_line(line) do
    fields = String.split(line, ~r/\s+/, trim: true)

    cond do
      fields == [] or hd(fields) == "Filesystem" ->
        nil

      length(fields) == 1 ->
        parse_non_negative_integer(hd(fields))

      length(fields) >= 4 ->
        fields |> Enum.at(3) |> parse_non_negative_integer()

      true ->
        nil
    end
  end

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp remove_issue_workspace(identifier, issue_context, worker_host) when is_binary(identifier) do
    safe_repo_key = safe_identifier(issue_context.repo_key)
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_repo_key, safe_id, worker_host) do
      {:ok, workspace} ->
        case remove_workspace(workspace, issue_context, worker_host) do
          {:ok, _removed_paths} ->
            :ok

          {:error, reason, output} ->
            log_workspace_removal_failure(workspace, issue_context, worker_host, reason, output)
        end

        :ok

      {:error, reason} ->
        Logger.warning("Workspace removal skipped #{issue_log_context(issue_context)} identifier=#{identifier} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}")
        :ok
    end
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier, Keyword.get(opts, :repo_key))
    hooks = hooks_for_issue_context(issue_context, opts)
    env = Keyword.get(opts, :env, [])

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(
          command,
          workspace,
          issue_context,
          "before_run",
          worker_host,
          hooks.timeout_ms,
          env
        )
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host(), keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier, Keyword.get(opts, :repo_key))
    hooks = hooks_for_issue_context(issue_context, opts)
    env = Keyword.get(opts, :env, [])

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(
          command,
          workspace,
          issue_context,
          "after_run",
          worker_host,
          hooks.timeout_ms,
          env
        )
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_repo_key, safe_id, nil) when is_binary(safe_repo_key) and is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_repo_key)
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_repo_key, safe_id, worker_host)
       when is_binary(safe_repo_key) and is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join([Config.settings!().workspace.root, safe_repo_key, safe_id])}
  end

  defp worktree_branch(%{issue_identifier: identifier}) when is_binary(identifier) and identifier != "" do
    "auto/#{identifier}"
  end

  defp worktree_branch(_issue_context), do: "auto/issue"

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = hooks_for_issue_context(issue_context)

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              issue_context,
              "after_create",
              worker_host,
              hooks.timeout_ms
            )
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, issue_context, nil) do
    hooks = hooks_for_issue_context(issue_context)

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              issue_context,
              "before_remove",
              nil,
              hooks.timeout_ms
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, issue_context, worker_host) when is_binary(worker_host) do
    hooks = hooks_for_issue_context(issue_context)

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              issue_context,
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp hooks_for_issue_context(issue_context, opts \\ []) do
    case Keyword.get(opts, :settings) do
      %{hooks: hooks} ->
        hooks

      _settings ->
        issue_context
        |> Map.get(:repo_key)
        |> settings_for_issue_context()
        |> Map.fetch!(:hooks)
    end
  end

  defp settings_for_issue_context(%{repo_key: repo_key}), do: settings_for_issue_context(repo_key)

  defp settings_for_issue_context(repo_key) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} ->
        settings

      {:error, {:unknown_repo_key, _repo_key}} ->
        Config.settings!()

      {:error, _reason} ->
        Config.settings_for_repo!(repo_key)
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, timeout_ms, env \\ [])

  defp run_hook(command, workspace, issue_context, hook_name, nil, timeout_ms, env) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    task =
      Task.async(fn ->
        opts =
          [cd: workspace, stderr_to_stdout: true]
          |> maybe_put_env(env)

        System.cmd("sh", ["-lc", command], opts)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, timeout_ms, env) when is_binary(worker_host) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    script =
      env
      |> remote_env_assignments()
      |> Kernel.++(["cd #{shell_escape(workspace)} && #{command}"])
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp maybe_put_env(opts, []), do: opts
  defp maybe_put_env(opts, env), do: Keyword.put(opts, :env, env)

  defp remote_env_assignments(env) when is_list(env) do
    Enum.map(env, fn {key, value} ->
      "export #{key}=#{shell_escape(to_string(value))}"
    end)
  end

  defp remote_env_assignments(_env), do: []

  defp log_workspace_removal_failure(workspace, issue_context, worker_host, reason, output) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning(
      "Workspace removal failed #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)} output=#{inspect(sanitized_output)}"
    )
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp remove_local_worktree(repo, workspace, issue_context) do
    cond do
      registered_worktree?(repo, workspace) ->
        maybe_run_before_remove_hook(workspace, issue_context, nil)

        with :ok <- run_git(repo, ["worktree", "remove", "--force", workspace]) do
          delete_local_worktree_branch(repo, worktree_branch(issue_context))
        end

      File.exists?(workspace) ->
        {:error, {:workspace_not_registered_worktree, workspace}, ""}

      true ->
        delete_local_worktree_branch(repo, worktree_branch(issue_context))
    end
  end

  defp delete_local_worktree_branch(repo, branch) do
    case git_branch_exists?(repo, branch) do
      true -> run_git(repo, ["branch", "-D", branch])
      false -> :ok
    end
  end

  defp registered_worktree?(repo, workspace) do
    workspace = Path.expand(workspace)

    case git_output(repo, ["worktree", "list", "--porcelain"]) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "worktree "))
        |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))
        |> Enum.any?(&(Path.expand(&1) == workspace))

      {:error, reason, output} ->
        sanitized_output = sanitize_hook_output_for_log(output)

        Logger.warning("Git worktree list failed repo=#{repo} workspace=#{workspace} reason=#{inspect(reason)} output=#{inspect(sanitized_output)}")

        false
    end
  end

  defp git_branch_exists?(repo, branch) do
    case System.cmd("git", ["-C", repo, "rev-parse", "--verify", "refs/heads/#{branch}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp run_git(repo, args) when is_binary(repo) and is_list(args) do
    case git_output(repo, args) do
      {:ok, _output} -> :ok
      {:error, reason, output} -> {:error, reason, output}
    end
  end

  defp git_output(repo, args) when is_binary(repo) and is_list(args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error, {:git_failed, repo, args, status}, output}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp workspace_issue_context(workspace) do
    path_parts = Path.split(Path.expand(workspace))

    %{
      issue_id: nil,
      repo_key: workspace_repo_key(path_parts),
      issue_identifier: Path.basename(workspace),
      labels: []
    }
  end

  defp issue_context(issue_or_identifier, repo_key \\ nil)

  defp issue_context(%{id: issue_id, identifier: identifier} = issue, repo_key) do
    %{
      issue_id: issue_id,
      repo_key: issue_repo_key(issue, repo_key),
      issue_identifier: identifier || "issue",
      labels: issue_labels(issue)
    }
  end

  defp issue_context(identifier, repo_key) when is_binary(identifier) do
    %{
      issue_id: nil,
      repo_key: normalize_repo_key(repo_key),
      issue_identifier: identifier,
      labels: []
    }
  end

  defp issue_context(_identifier, repo_key) do
    %{
      issue_id: nil,
      repo_key: normalize_repo_key(repo_key),
      issue_identifier: "issue",
      labels: []
    }
  end

  defp issue_repo_key(%{repo_key: repo_key}, _fallback), do: normalize_repo_key(repo_key)
  defp issue_repo_key(%{"repo_key" => repo_key}, _fallback), do: normalize_repo_key(repo_key)
  defp issue_repo_key(_issue, fallback), do: normalize_repo_key(fallback)

  defp normalize_repo_key(repo_key) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp normalize_repo_key(_repo_key), do: Config.repo_key!()

  defp workspace_repo_key(path_parts) when is_list(path_parts) do
    case Enum.reverse(path_parts) do
      [_identifier, repo_key | _rest] -> repo_key
      _ -> Config.repo_key!()
    end
  end

  defp issue_labels(%{labels: labels}) when is_list(labels), do: labels
  defp issue_labels(%{"labels" => labels}) when is_list(labels), do: labels
  defp issue_labels(_issue), do: []

  defp issue_log_context(%{issue_id: issue_id, repo_key: repo_key, issue_identifier: issue_identifier}) do
    "repo_key=#{repo_key || "default"} issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
