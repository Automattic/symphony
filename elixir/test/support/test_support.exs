defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.RunStore
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [write_workflow_file!: 1, write_workflow_file!: 2, restore_env: 2, stop_default_http_server: 0]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        :ok = SymphonyElixir.RunStore.clear()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_team: nil,
          tracker_labels: [],
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          workspace_strategy: "clone",
          workspace_repo: nil,
          workspace_fetch_before_dispatch: true,
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          max_tokens_per_issue: nil,
          max_tokens_per_day: nil,
          agent_kind: "codex",
          agent_command: "codex app-server",
          agent_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          agent_thread_sandbox: "workspace-write",
          agent_turn_sandbox_policy: nil,
          agent_network_access: nil,
          agent_turn_timeout_ms: 3_600_000,
          agent_read_timeout_ms: 5_000,
          agent_stall_timeout_ms: 300_000,
          agent_command_timeout_ms: 600_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          routing: nil,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          observability_transcript_buffer_size: 200,
          pr_review_mode: "tracker",
          pr_review_cooldown_minutes: nil,
          pr_review_stale_days: nil,
          pr_review_github_user: nil,
          pr_review_bot_users: nil,
          pr_review_auto_reply: nil,
          pr_review_auto_request_review: nil,
          ci: nil,
          server_port: nil,
          server_host: nil,
          quality_gate: nil,
          notifications: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_team = Keyword.get(config, :tracker_team)
    tracker_labels = Keyword.get(config, :tracker_labels)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    workspace_strategy = Keyword.get(config, :workspace_strategy)
    workspace_repo = Keyword.get(config, :workspace_repo)
    workspace_fetch_before_dispatch = Keyword.get(config, :workspace_fetch_before_dispatch)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    max_tokens_per_issue = Keyword.get(config, :max_tokens_per_issue)
    max_tokens_per_day = Keyword.get(config, :max_tokens_per_day)
    agent_kind = Keyword.get(config, :agent_kind)
    agent_command = Keyword.get(config, :agent_command)
    agent_approval_policy = Keyword.get(config, :agent_approval_policy)
    agent_thread_sandbox = Keyword.get(config, :agent_thread_sandbox)
    agent_turn_sandbox_policy = Keyword.get(config, :agent_turn_sandbox_policy)
    agent_network_access = Keyword.get(config, :agent_network_access)
    agent_turn_timeout_ms = Keyword.get(config, :agent_turn_timeout_ms)
    agent_read_timeout_ms = Keyword.get(config, :agent_read_timeout_ms)
    agent_stall_timeout_ms = Keyword.get(config, :agent_stall_timeout_ms)
    agent_command_timeout_ms = Keyword.get(config, :agent_command_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    routing = Keyword.get(config, :routing)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    observability_transcript_buffer_size = Keyword.get(config, :observability_transcript_buffer_size)
    pr_review_mode = Keyword.get(config, :pr_review_mode)
    pr_review_cooldown_minutes = Keyword.get(config, :pr_review_cooldown_minutes)
    pr_review_stale_days = Keyword.get(config, :pr_review_stale_days)
    pr_review_github_user = Keyword.get(config, :pr_review_github_user)
    pr_review_bot_users = Keyword.get(config, :pr_review_bot_users)
    pr_review_auto_reply = Keyword.get(config, :pr_review_auto_reply)
    pr_review_auto_request_review = Keyword.get(config, :pr_review_auto_request_review)
    ci = Keyword.get(config, :ci)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    quality_gate = Keyword.get(config, :quality_gate)
    notifications = Keyword.get(config, :notifications)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  team: #{yaml_value(tracker_team)}",
        "  labels: #{yaml_value(tracker_labels)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        "  strategy: #{yaml_value(workspace_strategy)}",
        "  repo: #{yaml_value(workspace_repo)}",
        "  fetch_before_dispatch: #{yaml_value(workspace_fetch_before_dispatch)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  kind: #{yaml_value(agent_kind)}",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "  max_tokens_per_issue: #{yaml_value(max_tokens_per_issue)}",
        "  max_tokens_per_day: #{yaml_value(max_tokens_per_day)}",
        "  command: #{yaml_value(agent_command)}",
        "  approval_policy: #{yaml_value(agent_approval_policy)}",
        "  thread_sandbox: #{yaml_value(agent_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(agent_turn_sandbox_policy)}",
        agent_network_access && "  network_access: #{yaml_value(agent_network_access)}",
        "  turn_timeout_ms: #{yaml_value(agent_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(agent_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(agent_stall_timeout_ms)}",
        "  command_timeout_ms: #{yaml_value(agent_command_timeout_ms)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        routing_yaml(routing),
        observability_yaml(
          observability_enabled,
          observability_refresh_ms,
          observability_render_interval_ms,
          observability_transcript_buffer_size
        ),
        pr_review_yaml(
          pr_review_mode,
          pr_review_cooldown_minutes,
          pr_review_stale_days,
          pr_review_github_user,
          pr_review_bot_users,
          pr_review_auto_reply,
          pr_review_auto_request_review
        ),
        ci_yaml(ci),
        server_yaml(server_port, server_host),
        quality_gate_yaml(quality_gate),
        notifications_yaml(notifications),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp routing_yaml(nil), do: nil
  defp routing_yaml(routes), do: "routing: #{yaml_value(routes)}"

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms, transcript_buffer_size) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}",
      "  transcript_buffer_size: #{yaml_value(transcript_buffer_size)}"
    ]
    |> Enum.join("\n")
  end

  defp pr_review_yaml(mode, cooldown_minutes, stale_days, github_user, bot_users, auto_reply, auto_request_review) do
    [
      "pr_review:",
      "  mode: #{yaml_value(mode)}",
      !is_nil(cooldown_minutes) && "  cooldown_minutes: #{yaml_value(cooldown_minutes)}",
      !is_nil(stale_days) && "  stale_days: #{yaml_value(stale_days)}",
      !is_nil(github_user) && "  github_user: #{yaml_value(github_user)}",
      !is_nil(bot_users) && "  bot_users: #{yaml_value(bot_users)}",
      !is_nil(auto_reply) && "  auto_reply: #{yaml_value(auto_reply)}",
      !is_nil(auto_request_review) && "  auto_request_review: #{yaml_value(auto_request_review)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp ci_yaml(nil), do: nil

  defp ci_yaml(opts) when is_list(opts) or is_map(opts) do
    config = map_from(opts)

    fields =
      [
        kv("enabled", Map.get(config, :enabled)),
        kv("poll_interval_ms", Map.get(config, :poll_interval_ms)),
        kv("log_excerpt_lines", Map.get(config, :log_excerpt_lines)),
        kv("flaky_retry", Map.get(config, :flaky_retry)),
        kv("max_retries", Map.get(config, :max_retries)),
        kv("escalation_state", Map.get(config, :escalation_state))
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> nil
      lines -> Enum.join(["ci:" | lines], "\n")
    end
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp quality_gate_yaml(nil), do: nil

  defp quality_gate_yaml(opts) when is_list(opts) or is_map(opts) do
    fields =
      [
        kv("enabled", Map.get(map_from(opts), :enabled)),
        kv("provider", Map.get(map_from(opts), :provider)),
        kv("model", Map.get(map_from(opts), :model)),
        kv("min_score", Map.get(map_from(opts), :min_score)),
        kv("pass_threshold", Map.get(map_from(opts), :pass_threshold)),
        kv("clarification_floor", Map.get(map_from(opts), :clarification_floor)),
        kv("max_clarification_rounds", Map.get(map_from(opts), :max_clarification_rounds)),
        kv("on_error", Map.get(map_from(opts), :on_error))
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> nil
      lines -> Enum.join(["quality_gate:" | lines], "\n")
    end
  end

  defp notifications_yaml(nil), do: nil

  defp notifications_yaml(opts) when is_list(opts) or is_map(opts) do
    config = map_from(opts)

    fields =
      [
        kv("enabled", Map.get(config, :enabled)),
        kv("redact_titles", Map.get(config, :redact_titles)),
        notification_channels_yaml(Map.get(config, :channels))
      ]
      |> Enum.reject(&is_nil/1)

    case fields do
      [] -> nil
      lines -> Enum.join(["notifications:" | lines], "\n")
    end
  end

  defp notification_channels_yaml(nil), do: nil
  defp notification_channels_yaml([]), do: "  channels: []"

  defp notification_channels_yaml(channels) when is_list(channels) do
    channel_lines =
      channels
      |> Enum.map(&notification_channel_yaml/1)
      |> Enum.reject(&is_nil/1)

    if channel_lines == [] do
      nil
    else
      Enum.join(["  channels:" | channel_lines], "\n")
    end
  end

  defp notification_channels_yaml(_channels), do: nil

  defp notification_channel_yaml(channel) when is_list(channel) or is_map(channel) do
    channel = map_from(channel)

    [
      "    - kind: #{yaml_value(Map.get(channel, :kind))}",
      notification_channel_entry("webhook_url", Map.get(channel, :webhook_url)),
      notification_channel_entry("url", Map.get(channel, :url)),
      notification_channel_entry("events", Map.get(channel, :events)),
      notification_headers_yaml(Map.get(channel, :headers))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp notification_channel_yaml(_channel), do: nil

  defp notification_channel_entry(_name, nil), do: nil
  defp notification_channel_entry(name, value), do: "      #{name}: #{yaml_value(value)}"

  defp notification_headers_yaml(nil), do: nil
  defp notification_headers_yaml(headers) when headers == %{}, do: nil

  defp notification_headers_yaml(headers) when is_map(headers) do
    entries =
      Enum.map_join(headers, "\n", fn {key, value} -> "        #{key}: #{yaml_value(value)}" end)

    "      headers:\n" <> entries
  end

  defp notification_headers_yaml(_headers), do: nil

  defp map_from(opts) when is_list(opts), do: Enum.into(opts, %{})
  defp map_from(opts) when is_map(opts), do: opts

  defp kv(_name, nil), do: nil
  defp kv(name, value), do: "  #{name}: #{yaml_value(value)}"

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
