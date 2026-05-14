defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured agent.
  """

  require Logger

  alias SymphonyElixir.{
    AgentLabels,
    AgentTools,
    AgentTools.Linear.CommentRegistry,
    AuditLog,
    CiPoller,
    Config,
    DependencyAudit,
    Linear.Issue,
    Notifications,
    PromptBuilder,
    PrReviewPoller,
    SelfReview,
    Tracker,
    URLUtils,
    Verification,
    Workspace
  }

  @dev_server_pid_key {__MODULE__, :verification_dev_server_pid}
  @dependency_review_state "In Review"

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    repo_key = run_repo_key(issue, opts)
    settings = Config.settings_for_repo!(repo_key)
    opts = opts |> Keyword.put(:repo_key, repo_key) |> Keyword.put(:settings, settings)

    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), settings.worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")
    settings = Keyword.fetch!(opts, :settings)

    case Verification.context_for_agent(issue, Keyword.put(opts, :worker_host, worker_host)) do
      {:ok, verification} ->
        verification_env = Verification.env(verification)

        case workspace_for_issue(issue, opts, worker_host) do
          {:ok, workspace} ->
            send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

            try do
              with :ok <-
                     Workspace.run_before_run_hook(workspace, issue, worker_host,
                       env: verification_env,
                       settings: settings
                     ),
                   {:ok, dev_server_pid} <-
                     Verification.start_dev_server(verification, workspace, settings: settings) do
                remember_verification_dev_server(dev_server_pid)
                enriched_issue = enrich_issue_for_dispatch(issue, opts)
                run_codex_turns(workspace, enriched_issue, codex_update_recipient, opts, worker_host)
              end
            after
              Workspace.run_after_run_hook(workspace, issue, worker_host,
                env: verification_env,
                settings: settings
              )

              stop_remembered_verification_dev_server()
              Verification.release(verification, "after_run completed")
            end

          {:error, reason} ->
            Verification.release(verification, "workspace setup failed")
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remember_verification_dev_server(pid) when is_pid(pid), do: Process.put(@dev_server_pid_key, pid)
  defp remember_verification_dev_server(_pid), do: :ok

  defp stop_remembered_verification_dev_server do
    case Process.delete(@dev_server_pid_key) do
      pid when is_pid(pid) -> Verification.stop_dev_server(pid)
      _ -> :ok
    end
  end

  defp enrich_issue_for_dispatch(issue, opts) do
    issue_enricher = Keyword.get(opts, :issue_enricher, &Tracker.enrich_issue/1)

    try do
      case issue_enricher.(issue) do
        {:ok, enriched_issue} ->
          enriched_issue

        {:error, reason} ->
          Logger.warning("issue_enrichment_failed #{issue_context(issue)} reason=#{inspect(reason)}")
          issue
      end
    rescue
      exception ->
        Logger.warning("issue_enrichment_failed #{issue_context(issue)} reason=#{inspect(exception)}")
        issue
    end
  end

  defp workspace_for_issue(issue, opts, worker_host) do
    case Keyword.get(opts, :workspace_path) do
      workspace when is_binary(workspace) and workspace != "" -> {:ok, workspace}
      _ -> Workspace.create_for_issue(issue, worker_host, Keyword.get(opts, :repo_key))
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    payload = SymphonyElixir.ClaudeCode.AppServer.event_to_update(message) || message
    send(recipient, {:codex_worker_update, issue_id, payload})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp send_agent_session_info(recipient, %Issue{id: issue_id}, agent_module, session)
       when is_binary(issue_id) and is_pid(recipient) and is_atom(agent_module) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         agent_module: agent_module,
         agent_session: session
       }}
    )

    :ok
  end

  defp send_agent_session_info(_recipient, _issue, _agent_module, _session), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    settings = Keyword.fetch!(opts, :settings)
    max_turns = Keyword.get(opts, :max_turns, settings.agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    seed_ids = AgentTools.Linear.recover_comment_registry_seeds(issue, settings.tracker.kind)

    with {:ok, agent_module} <- agent_module(),
         {:ok, linear_comment_registry} <- CommentRegistry.start_link(seed_ids: seed_ids),
         {:ok, session} <-
           agent_module.start_session(workspace,
             worker_host: worker_host,
             settings: settings,
             issue: issue,
             run_id: Keyword.get(opts, :run_id),
             repo_key: Keyword.get(opts, :repo_key),
             linear_comment_registry: linear_comment_registry
           ) do
      send_agent_session_info(codex_update_recipient, issue, agent_module, session)

      run_context = %{
        workspace: workspace,
        issue: issue,
        codex_update_recipient: codex_update_recipient,
        opts: Keyword.put(opts, :linear_comment_registry, linear_comment_registry),
        issue_state_fetcher: issue_state_fetcher,
        worker_host: worker_host,
        self_review: initial_self_review_state(),
        next_prompt: nil
      }

      try do
        do_run_codex_turns(agent_module, session, run_context, 1, max_turns)
      after
        agent_module.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(agent_module, app_session, run_context, turn_number, max_turns) do
    %{
      workspace: workspace,
      issue: issue,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher
    } = run_context

    prompt = run_context.next_prompt || build_turn_prompt(issue, opts, turn_number, max_turns)
    run_context = %{run_context | next_prompt: nil}
    audit_prompt_sent(issue, Keyword.get(opts, :run_id), prompt, turn_number, max_turns, agent_module, opts)

    with {:ok, turn_session} <-
           agent_module.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue),
             settings: Keyword.fetch!(opts, :settings),
             repo_key: Keyword.get(opts, :repo_key),
             run_id: Keyword.get(opts, :run_id),
             linear_comment_registry: Keyword.get(opts, :linear_comment_registry),
             dependency_audit_module: dependency_audit_module(opts),
             dependency_audit_base_ref: Keyword.get(opts, :dependency_audit_base_ref),
             dependency_audit_command_runner: Keyword.get(opts, :dependency_audit_command_runner)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      case maybe_hold_for_dependency_approval(workspace, issue, turn_session, opts) do
        :ok ->
          continue_after_completed_turn(
            issue,
            issue_state_fetcher,
            opts,
            run_context,
            agent_module,
            app_session,
            turn_number,
            max_turns
          )

        {:hold, _items} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp continue_after_completed_turn(issue, issue_state_fetcher, opts, run_context, agent_module, app_session, turn_number, max_turns) do
    case continue_with_issue?(issue, issue_state_fetcher, opts) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        run_context = %{run_context | issue: refreshed_issue}
        continue_active_issue(agent_module, app_session, run_context, refreshed_issue, turn_number, max_turns)

      {:continue, refreshed_issue} ->
        Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_hold_for_dependency_approval(workspace, issue, turn_session, opts) do
    audit_module = dependency_audit_module(opts)

    audit_opts =
      opts
      |> Keyword.take([:repo_key, :settings])
      |> maybe_put_option(:base_ref, Keyword.get(opts, :dependency_audit_base_ref))
      |> maybe_put_option(:command_runner, Keyword.get(opts, :dependency_audit_command_runner))

    case audit_module.audit(workspace, audit_opts) do
      {:ok, []} ->
        :ok

      {:hold, items} ->
        hold_dependency_approval(issue, items, turn_session, opts)

      {:error, reason} ->
        {:error, {:dependency_audit_failed, reason}}
    end
  end

  defp dependency_audit_module(opts) do
    Keyword.get(opts, :dependency_audit_module) || DependencyAudit
  end

  defp hold_dependency_approval(%Issue{id: issue_id} = issue, items, turn_session, opts)
       when is_binary(issue_id) do
    case Tracker.update_issue_state(issue_id, @dependency_review_state) do
      :ok ->
        Notifications.emit_issue_event(
          :dependency_pending_approval,
          issue,
          dependency_approval_attrs(items, turn_session, opts)
        )

        Logger.warning("Dependency approval required for #{issue_context(issue)} items=#{length(items)}")
        {:hold, items}

      {:error, reason} ->
        {:error, {:dependency_approval_state_update_failed, reason}}
    end
  end

  defp hold_dependency_approval(issue, items, turn_session, opts) do
    Notifications.emit_issue_event(
      :dependency_pending_approval,
      issue,
      dependency_approval_attrs(items, turn_session, opts)
    )

    {:hold, items}
  end

  defp dependency_approval_attrs(items, turn_session, opts) do
    %{
      repo_key: Keyword.get(opts, :repo_key),
      run_id: Keyword.get(opts, :run_id),
      session_id: turn_session[:session_id],
      state: @dependency_review_state,
      reason: "dependency_source_requires_approval",
      metadata: DependencyAudit.approval_metadata(items)
    }
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp continue_active_issue(agent_module, app_session, run_context, refreshed_issue, turn_number, max_turns) do
    case maybe_self_review_next_turn(run_context, turn_number, max_turns) do
      {:self_review_turn, next_context} ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} with self-review guidance turn=#{turn_number}/#{max_turns}")

        do_run_codex_turns(agent_module, app_session, next_context, turn_number + 1, max_turns)

      {:normal_continuation, next_context} ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_codex_turns(
          agent_module,
          app_session,
          next_context,
          turn_number + 1,
          max_turns
        )

      :normal_continuation ->
        Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

        do_run_codex_turns(
          agent_module,
          app_session,
          run_context,
          turn_number + 1,
          max_turns
        )
    end
  end

  defp initial_self_review_state, do: %{phase: :not_run, request_change_rounds: 0}

  defp maybe_self_review_next_turn(run_context, turn_number, max_turns) do
    config = run_context.opts |> Keyword.fetch!(:settings) |> Map.fetch!(:self_review)

    if self_review_enabled?(config) do
      self_review_next_turn(run_context, config, turn_number, max_turns)
    else
      :normal_continuation
    end
  end

  defp self_review_enabled?(%SymphonyElixir.Config.Schema.SelfReview{enabled: true}), do: true
  defp self_review_enabled?(_config), do: false

  defp self_review_next_turn(%{self_review: %{phase: :not_run}} = run_context, config, _turn_number, _max_turns) do
    result = evaluate_self_review(run_context, config)

    cond do
      SelfReview.request_changes?(result) and correction_round_available?(run_context, config) ->
        {:self_review_turn,
         %{
           run_context
           | self_review: %{
               phase: :awaiting_correction,
               findings: result.findings,
               request_change_rounds: next_request_change_round(run_context)
             },
             next_prompt: SelfReview.request_changes_prompt(result)
         }}

      SelfReview.fail_open?(result) ->
        {:self_review_turn,
         %{
           run_context
           | self_review: %{phase: :complete, request_change_rounds: request_change_rounds(run_context)},
             next_prompt: SelfReview.fail_open_prompt(result)
         }}

      SelfReview.request_changes?(result) ->
        {:self_review_turn,
         %{
           run_context
           | self_review: %{
               phase: :complete,
               final_findings: result.findings,
               request_change_rounds: request_change_rounds(run_context)
             },
             next_prompt: SelfReview.push_prompt(result)
         }}

      true ->
        {:normal_continuation,
         %{
           run_context
           | self_review: %{phase: :complete, request_change_rounds: request_change_rounds(run_context)}
         }}
    end
  end

  defp self_review_next_turn(%{self_review: %{phase: :awaiting_correction}} = run_context, config, _turn_number, _max_turns) do
    result = evaluate_self_review(run_context, config)

    {:self_review_turn,
     %{
       run_context
       | self_review: %{
           phase: :complete,
           final_findings: result.findings,
           request_change_rounds: request_change_rounds(run_context)
         },
         next_prompt: SelfReview.push_prompt(result)
     }}
  end

  defp self_review_next_turn(_run_context, _config, _turn_number, _max_turns), do: :normal_continuation

  defp correction_round_available?(run_context, config) do
    request_change_rounds(run_context) < config.max_rounds
  end

  defp next_request_change_round(run_context), do: request_change_rounds(run_context) + 1

  defp request_change_rounds(%{self_review: %{request_change_rounds: rounds}}) when is_integer(rounds), do: rounds

  defp evaluate_self_review(%{issue: issue, workspace: workspace, opts: opts, worker_host: worker_host} = run_context, config) do
    provider_module = Keyword.get(opts, :self_review_provider_module)
    review_opts = [worker_host: worker_host, base_branch: self_review_base_branch(opts)]
    review_opts = if provider_module, do: Keyword.put(review_opts, :provider_module, provider_module), else: review_opts

    result = SelfReview.evaluate(issue, workspace, config, review_opts)
    audit_self_review(issue, Keyword.get(opts, :run_id), result, self_review_round(run_context), opts)
    result
  end

  defp self_review_base_branch(opts) do
    repo_key = Keyword.get(opts, :repo_key)

    case Config.repo_base_branch(repo_key) do
      {:ok, base_branch} ->
        base_branch

      {:error, reason} ->
        Logger.warning("SelfReview base_branch lookup failed repo_key=#{inspect(repo_key)} reason=#{inspect(reason)}")
        nil
    end
  end

  defp audit_self_review(issue, run_id, result, round, opts) do
    issue
    |> AuditLog.record_self_review(run_id, result, audit_opts(opts, round: round))
    |> log_audit_error("record self_review")
  end

  defp self_review_round(%{self_review: %{phase: :awaiting_correction}}), do: 2
  defp self_review_round(_run_context), do: 1

  defp agent_module do
    case Config.settings!().agent.kind do
      "codex" -> {:ok, SymphonyElixir.Codex.AppServer}
      "claude" -> {:ok, SymphonyElixir.ClaudeCode.AppServer}
      kind -> {:error, {:unknown_agent_kind, kind}}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    PromptBuilder.build_prompt(
      issue,
      opts
      |> put_reviewer_comments(issue)
      |> put_ci_failure(issue)
    )
  end

  defp build_turn_prompt(_issue, opts, turn_number, max_turns) do
    agent_name =
      opts
      |> Keyword.get(:settings)
      |> agent_kind_from_settings()
      |> AgentLabels.display_name()

    """
    Continuation guidance:

    - The previous #{agent_name} turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp agent_kind_from_settings(%{agent: %{kind: kind}}), do: kind
  defp agent_kind_from_settings(_settings), do: nil

  defp audit_prompt_sent(issue, run_id, prompt, turn_number, max_turns, agent_module, opts) do
    issue
    |> AuditLog.record_prompt_sent(
      run_id,
      prompt,
      audit_opts(opts,
        turn_number: turn_number,
        max_turns: max_turns,
        agent: inspect(agent_module)
      )
    )
    |> log_audit_error("record prompt_sent")
  end

  defp audit_opts(opts, extra \\ []) do
    opts
    |> Keyword.take([:repo_key])
    |> Keyword.merge(extra)
  end

  defp put_reviewer_comments(opts, issue) when is_list(opts) do
    if Keyword.has_key?(opts, :reviewer_comments) do
      opts
    else
      Keyword.put(opts, :reviewer_comments, pending_reviewer_comments(issue))
    end
  end

  defp pending_reviewer_comments(%Issue{id: issue_id}) when is_binary(issue_id) do
    PrReviewPoller.pending_reviewer_comments(issue_id)
  end

  defp pending_reviewer_comments(_issue), do: []

  defp put_ci_failure(opts, issue) when is_list(opts) do
    if Keyword.has_key?(opts, :ci_failure) do
      opts
    else
      Keyword.put(opts, :ci_failure, pending_ci_failure(issue))
    end
  end

  defp pending_ci_failure(%Issue{id: issue_id}) when is_binary(issue_id) do
    CiPoller.pending_ci_failure(issue_id)
  end

  defp pending_ci_failure(_issue), do: nil

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, opts) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        audit_linear_state_transition(issue, refreshed_issue, Keyword.get(opts, :run_id), opts)

        cond do
          post_pr_quiet_continuation?(issue, refreshed_issue) ->
            Logger.info("Stopping agent run for #{issue_context(refreshed_issue)} after PR opened; waiting for review, CI, or manual rework signal")
            {:done, refreshed_issue}

          active_issue_state?(refreshed_issue.state) ->
            {:continue, refreshed_issue}

          true ->
            {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _opts), do: {:done, issue}

  defp post_pr_quiet_continuation?(%Issue{} = previous_issue, %Issue{} = refreshed_issue) do
    if attached_pr?(previous_issue) or attached_pr?(refreshed_issue) do
      active_issue_state?(refreshed_issue.state) and
        !rework_state?(refreshed_issue.state) and
        pending_reviewer_comments(refreshed_issue) == [] and
        is_nil(pending_ci_failure(refreshed_issue))
    else
      false
    end
  end

  defp attached_pr?(%Issue{} = issue), do: is_binary(URLUtils.pull_request_url(issue))

  defp rework_state?(state_name) when is_binary(state_name) do
    normalize_issue_state(state_name) == "rework"
  end

  defp rework_state?(_state_name), do: false

  defp audit_linear_state_transition(issue, refreshed_issue, run_id, opts) do
    issue
    |> AuditLog.record_linear_state_transition(refreshed_issue, run_id, audit_opts(opts))
    |> log_audit_error("record linear_state_change")
  end

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp run_repo_key(issue, opts) do
    Keyword.get(opts, :repo_key) || issue_repo_key(issue) || Config.repo_key!()
  end

  defp issue_repo_key(%Issue{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp issue_repo_key(%{repo_key: repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp issue_repo_key(%{"repo_key" => repo_key}) when is_binary(repo_key) and repo_key != "", do: repo_key
  defp issue_repo_key(_issue), do: nil

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp log_audit_error(:ok, _action), do: :ok

  defp log_audit_error({:error, reason}, action) do
    Logger.warning("Audit log failed to #{action}: #{inspect(reason)}")
    :ok
  end
end
