defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """
  @default_server_port 0
  @codex_auto_approve_all_approval_policy "auto_approve_all"
  @codex_legacy_auto_approve_approval_policy "never"
  @codex_auto_approve_all_wire_approval_policy "never"

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          thread_config: map() | nil,
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec hooks_for_issue(term()) :: Schema.Hooks.t()
  def hooks_for_issue(issue_or_labels) do
    settings!()
    |> Schema.hooks_for_issue(issue_or_labels)
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> default_server_port(settings!())
    end
  end

  @spec server_host() :: String.t()
  def server_host do
    case Application.get_env(:symphony_elixir, :server_host_override) do
      host when is_binary(host) and host != "" -> host
      _ -> settings!().server.host
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec linear_scoping_filter_configured?(map() | nil) :: boolean()
  def linear_scoping_filter_configured?(%{project_slug: project_slug, team: team, labels: labels}) do
    present_string?(project_slug) or present_string?(team) or non_empty_list?(labels)
  end

  def linear_scoping_filter_configured?(_tracker), do: false

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      {approval_policy, auto_approve_requests} = codex_runtime_approval_policy(settings.agent.approval_policy)

      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: approval_policy,
           auto_approve_requests: auto_approve_requests,
           thread_sandbox: settings.agent.thread_sandbox,
           thread_config: Schema.resolve_codex_thread_config(settings),
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.agent.kind) ->
        {:error,
         {:invalid_workflow_config,
          "agent.kind is required. Add `kind: codex` (or `kind: claude`) and `command: <your-command>` under your `agent:` key. The top-level `codex:` section has moved to `agent:`. Rename each field accordingly."}}

      settings.agent.kind not in ["codex", "claude"] ->
        {:error, {:unsupported_agent_kind, settings.agent.kind}}

      true ->
        with :ok <- validate_tracker_semantics(settings),
             :ok <- validate_workspace_semantics(settings),
             :ok <- validate_notifications_semantics(settings) do
          warn_if_deprecated_codex_approval_policy(settings)
          warn_if_budget_token_reporting_unavailable(settings)
          :ok
        end
    end
  end

  defp codex_runtime_approval_policy(@codex_auto_approve_all_approval_policy) do
    {@codex_auto_approve_all_wire_approval_policy, true}
  end

  defp codex_runtime_approval_policy(@codex_legacy_auto_approve_approval_policy) do
    {@codex_auto_approve_all_wire_approval_policy, true}
  end

  defp codex_runtime_approval_policy(approval_policy), do: {approval_policy, false}

  defp validate_tracker_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not linear_scoping_filter_configured?(settings.tracker) ->
        {:error, :missing_linear_scoping_filter}

      true ->
        :ok
    end
  end

  defp default_server_port(settings) do
    cond do
      not settings.observability.dashboard_enabled -> nil
      is_integer(settings.server.port) -> settings.server.port
      true -> @default_server_port
    end
  end

  defp warn_if_deprecated_codex_approval_policy(%Schema{agent: agent}) do
    if agent.kind == "codex" and agent.approval_policy == @codex_legacy_auto_approve_approval_policy do
      Logger.warning(~s(agent.approval_policy: "never" is deprecated for Codex because it auto-approves all approval requests; use "auto_approve_all" instead.))
    end

    :ok
  end

  defp warn_if_budget_token_reporting_unavailable(%Schema{} = settings) do
    budget_keys = configured_budget_keys(settings.agent)

    if budget_keys != [] and not codex_app_server_command?(settings.agent.command) do
      Logger.warning("#{budget_warning_subject(budget_keys)} but agent.command may not report token usage command=#{inspect(settings.agent.command)}")
    end

    :ok
  end

  defp budget_warning_subject([budget_key]), do: "#{budget_key} is configured"
  defp budget_warning_subject(budget_keys), do: "#{Enum.join(budget_keys, ", ")} are configured"

  defp configured_budget_keys(agent) do
    [
      {"agent.max_tokens_per_issue", agent.max_tokens_per_issue},
      {"agent.max_tokens_per_day", agent.max_tokens_per_day}
    ]
    |> Enum.filter(fn {_key, value} -> is_integer(value) end)
    |> Enum.map(fn {key, _value} -> key end)
  end

  defp codex_app_server_command?(command) when is_binary(command) do
    command
    |> String.split()
    |> Enum.member?("app-server")
  end

  defp codex_app_server_command?(_command), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp non_empty_list?(values) when is_list(values), do: Enum.any?(values, &present_string?/1)
  defp non_empty_list?(_values), do: false

  defp validate_workspace_semantics(%Schema{workspace: %{strategy: "worktree"} = workspace, worker: worker}) do
    cond do
      not is_binary(workspace.repo) or String.trim(workspace.repo) == "" ->
        {:error, {:invalid_workflow_config, "workspace.repo is required when workspace.strategy is worktree"}}

      worker.ssh_hosts != [] ->
        :ok

      true ->
        workspace.repo
        |> Path.expand()
        |> validate_local_worktree_repo()
    end
  end

  defp validate_workspace_semantics(_settings), do: :ok

  defp validate_notifications_semantics(%Schema{notifications: %{enabled: true, channels: channels}})
       when is_list(channels) do
    Enum.reduce_while(channels, :ok, fn channel, :ok ->
      case validate_notification_channel(channel) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_notifications_semantics(_settings), do: :ok

  defp validate_notification_channel(%{kind: "slack", webhook_url: url}) when is_binary(url), do: :ok

  defp validate_notification_channel(%{kind: "slack"}) do
    {:error, {:invalid_workflow_config, "notifications.channels entries with kind: slack require webhook_url (or a $VAR that resolves to one)"}}
  end

  defp validate_notification_channel(%{kind: "webhook", url: url}) when is_binary(url), do: :ok

  defp validate_notification_channel(%{kind: "webhook"}) do
    {:error, {:invalid_workflow_config, "notifications.channels entries with kind: webhook require url (or a $VAR that resolves to one)"}}
  end

  defp validate_notification_channel(_channel), do: :ok

  defp validate_local_worktree_repo(repo) when is_binary(repo) do
    with :ok <- validate_local_worktree_repo_path(repo),
         :ok <- validate_local_worktree_git_repo(repo) do
      warn_if_local_worktree_repo_dirty(repo)
      :ok
    end
  end

  defp validate_local_worktree_repo_path(repo) do
    cond do
      not File.exists?(repo) ->
        {:error, {:invalid_workflow_config, "workspace.repo does not exist: #{repo}"}}

      not File.dir?(repo) ->
        {:error, {:invalid_workflow_config, "workspace.repo is not a directory: #{repo}"}}

      true ->
        :ok
    end
  end

  defp validate_local_worktree_git_repo(repo) do
    case System.cmd("git", ["-C", repo, "rev-parse", "--git-dir"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, {:invalid_workflow_config, "workspace.repo is not a valid git repository: #{repo} (git rev-parse exited #{status}: #{String.trim(output)})"}}
    end
  end

  defp warn_if_local_worktree_repo_dirty(repo) do
    case System.cmd("git", ["-C", repo, "status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} ->
        :ok

      {output, 0} ->
        Logger.warning("Worktree primary clone has uncommitted changes workspace_repo=#{repo} dirty=#{inspect(String.trim(output))}")
        :ok

      {_output, _status} ->
        :ok
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
