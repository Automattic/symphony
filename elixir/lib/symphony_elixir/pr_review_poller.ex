defmodule SymphonyElixir.PrReviewPoller do
  @moduledoc """
  Polling-mode pull request review poller.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, RunStore, Tracker, Workspace}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue

  @in_review_state "In Review"
  @active_state "In Progress"
  @changes_requested "CHANGES_REQUESTED"
  @approved "APPROVED"
  @closed_pr_states ["CLOSED", "MERGED"]
  @github_error_backoff_threshold 3
  @max_github_error_backoff_ms 300_000

  defmodule State do
    @moduledoc false
    defstruct [:timer_ref, :poll_interval_ms, opts: []]
  end

  @type poll_summary :: %{
          mode: :polling | :tracker,
          discovered: non_neg_integer(),
          processed: non_neg_integer(),
          actions: [term()]
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    poll_interval_ms = poll_interval_ms(opts)
    opts = Keyword.put(opts, :poll_interval_ms, poll_interval_ms)

    {:ok, schedule_poll(%State{opts: opts, poll_interval_ms: poll_interval_ms}, 0)}
  end

  @impl true
  def handle_info(:poll, %State{} = state) do
    try do
      case poll_once(state.opts) do
        {:ok, summary} ->
          Logger.debug("PR review poll completed: #{inspect(summary)}")
          log_poll_action_warnings(summary)

        {:error, reason} ->
          Logger.warning("PR review poll failed: #{inspect(reason)}")
      end
    rescue
      exception ->
        Logger.error("PR review poll raised: #{Exception.format(:error, exception, __STACKTRACE__)}")
    catch
      kind, reason ->
        Logger.error("PR review poll failed with #{kind}: #{Exception.format(kind, reason, __STACKTRACE__)}")
    end

    {:noreply, schedule_poll(state, state.poll_interval_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec poll_once(keyword()) :: {:ok, poll_summary()} | {:error, term()}
  def poll_once(opts \\ []) when is_list(opts) do
    with {:ok, settings} <- poll_settings(opts) do
      case settings.pr_review.mode do
        "polling" ->
          do_poll_once(settings, opts)

        _mode ->
          {:ok, %{mode: :tracker, discovered: 0, processed: 0, actions: []}}
      end
    end
  end

  defp poll_settings(opts) do
    case Keyword.fetch(opts, :settings) do
      {:ok, settings} -> {:ok, settings}
      :error -> Config.settings()
    end
  end

  defp do_poll_once(settings, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    run_store = Keyword.get(opts, :run_store, RunStore)
    tracker = Keyword.get(opts, :tracker, Tracker)

    with {:ok, discovered} <- discover_reviews(run_store, tracker, now),
         {:ok, reviews} <- list_pr_reviews(run_store) do
      actions =
        reviews
        |> Enum.map(&process_review(&1, settings, opts, now))

      {:ok, %{mode: :polling, discovered: discovered, processed: length(reviews), actions: actions}}
    end
  end

  defp discover_reviews(run_store, tracker, now) do
    with {:ok, issues} <- tracker.fetch_issues_by_states([@in_review_state]),
         {:ok, runs} <- list_runs(run_store),
         {:ok, existing} <- list_pr_reviews(run_store) do
      existing_by_issue = Map.new(existing, &{Map.get(&1, :issue_id), &1})

      discovered =
        issues
        |> Enum.filter(&match?(%Issue{}, &1))
        |> Enum.count(&persist_discovered_review?(&1, runs, existing_by_issue, run_store, now))

      {:ok, discovered}
    end
  end

  defp persist_discovered_review?(%Issue{} = issue, runs, existing_by_issue, run_store, now) do
    existing = Map.get(existing_by_issue, issue.id)

    case discover_review_record(issue, runs, existing, now) do
      nil ->
        false

      record ->
        case persist_pr_review(run_store, record) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning("Failed to persist discovered PR review record issue_id=#{issue.id}: #{inspect(reason)}")

            false
        end
    end
  end

  defp discover_review_record(%Issue{} = issue, runs, existing, now) when is_list(runs) do
    with pr_url when is_binary(pr_url) <- first_pr_url(issue),
         %{workspace_path: workspace_path} = run when is_binary(workspace_path) <-
           latest_run_for_issue(runs, issue.id) do
      base = %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_url: issue.url,
        pr_url: pr_url,
        workspace_path: workspace_path,
        worker_host: Map.get(run, :worker_host),
        status: Map.get(existing || %{}, :status, "watching"),
        inserted_at: Map.get(existing || %{}, :inserted_at, now),
        updated_at: now
      }

      Map.merge(existing || %{}, base)
    else
      nil ->
        nil

      other ->
        Logger.debug("discover_review_record skipped issue_id=#{issue.id}: #{inspect(other)}")
        nil
    end
  end

  defp discover_review_record(_issue, _runs, _existing, _now), do: nil

  defp log_poll_action_warnings(%{actions: actions}) when is_list(actions) do
    Enum.each(actions, &log_poll_action_warning/1)
  end

  defp log_poll_action_warning({:cleanup_error, issue_id, reason}) do
    Logger.warning("PR review cleanup error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:poll_error, issue_id, reason}) do
    Logger.warning("PR review poll error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:poll_error_update_failed, issue_id, reason, update_reason}) do
    Logger.warning("PR review poll error update failed issue_id=#{issue_id} reason=#{inspect(reason)}: #{inspect(update_reason)}")
  end

  defp log_poll_action_warning({:state_transition_error, issue_id, action, reason}) do
    Logger.warning("PR review transition error issue_id=#{issue_id} action=#{action}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:state_transition_update_error, issue_id, action, reason}) do
    Logger.warning("PR review transition update error issue_id=#{issue_id} action=#{action}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:state_transition_error_update_failed, issue_id, action, reason, update_reason}) do
    Logger.warning("PR review transition error update failed issue_id=#{issue_id} action=#{action} reason=#{inspect(reason)}: #{inspect(update_reason)}")
  end

  defp log_poll_action_warning({:update_error, issue_id, reason}) do
    Logger.warning("PR review update error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning(_action), do: :ok

  defp process_review(record, settings, opts, now) when is_map(record) do
    case backoff_active_until(record, now) do
      {:backing_off, next_poll_at} ->
        {:backing_off, Map.get(record, :issue_id), next_poll_at}

      :ready ->
        fetch_and_process_review(record, settings, opts, now)
    end
  end

  defp fetch_and_process_review(record, settings, opts, now) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_activity(Map.get(record, :pr_url), cwd: Map.get(record, :workspace_path)) do
      {:ok, activity} ->
        handle_activity(record, activity, settings, opts, now)

      {:error, reason} ->
        record_poll_error(record, reason, opts, now)
    end
  end

  defp record_poll_error(record, reason, opts, now) do
    attrs = poll_error_attrs(record, reason, opts, now)

    case update_review(opts, record, attrs) do
      :ok ->
        {:poll_error, Map.get(record, :issue_id), reason}

      {:error, update_reason} ->
        {:poll_error_update_failed, Map.get(record, :issue_id), reason, update_reason}
    end
  end

  defp handle_activity(record, activity, settings, opts, now) do
    {attrs, latest_activity_at} = review_activity_attrs(record, activity, now)

    case review_action(activity, latest_activity_at, settings, now) do
      :closed ->
        cleanup_review(record, opts, now, "closed")

      :changes_requested ->
        maybe_transition_rework(record, attrs, settings, opts, now)

      :approved ->
        maybe_transition_merge(record, attrs, opts, now)

      :stale ->
        cleanup_review(record, opts, now, "stale")

      :watching ->
        complete_review_update(opts, record, attrs, {:watching, Map.get(record, :issue_id)})
    end
  end

  defp review_activity_attrs(record, activity, now) do
    latest_activity_at =
      Map.get(activity, :latest_activity_at) ||
        Map.get(record, :last_activity_at) ||
        Map.get(record, :updated_at) ||
        now

    latest_review_activity_at =
      Map.get(activity, :latest_review_activity_at) ||
        Map.get(record, :last_review_activity_at) ||
        latest_activity_at

    attrs = %{
      status: "watching",
      error: nil,
      consecutive_errors: 0,
      next_poll_at: nil,
      last_activity_at: latest_activity_at,
      last_review_activity_at: latest_review_activity_at,
      last_review_decision: Map.get(activity, :review_decision),
      updated_at: now
    }

    {attrs, latest_activity_at}
  end

  defp review_action(activity, latest_activity_at, settings, now) do
    review_decision = normalize_decision(Map.get(activity, :review_decision))

    cond do
      closed_pr_state?(Map.get(activity, :state)) -> :closed
      review_decision == @changes_requested -> :changes_requested
      review_decision == @approved -> :approved
      stale?(latest_activity_at, now, settings.pr_review.stale_days) -> :stale
      true -> :watching
    end
  end

  defp maybe_transition_rework(record, attrs, settings, opts, now) do
    latest_activity_at = action_activity_at(attrs)

    cond do
      handled_activity?(record, latest_activity_at) ->
        complete_review_update(opts, record, attrs, {:already_handled, Map.get(record, :issue_id), :rework})

      !cooldown_elapsed?(latest_activity_at, now, settings.pr_review.cooldown_minutes) ->
        complete_review_update(opts, record, Map.merge(attrs, %{status: "cooling_down"}), {:cooling_down, Map.get(record, :issue_id)})

      true ->
        transition_issue_for_action(record, attrs, opts, now, "rework")
    end
  end

  defp maybe_transition_merge(record, attrs, opts, now) do
    latest_activity_at = action_activity_at(attrs)

    if handled_activity?(record, latest_activity_at) do
      complete_review_update(opts, record, attrs, {:already_handled, Map.get(record, :issue_id), :merge})
    else
      transition_issue_for_action(record, attrs, opts, now, "merge")
    end
  end

  defp action_activity_at(attrs) do
    Map.get(attrs, :last_review_activity_at) || Map.fetch!(attrs, :last_activity_at)
  end

  defp transition_issue_for_action(record, attrs, opts, now, action) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)

    case tracker.update_issue_state(issue_id, @active_state) do
      :ok ->
        complete_transition_action(record, attrs, opts, now, action)

      {:error, reason} ->
        record_transition_error(record, attrs, opts, now, action, reason)
    end
  end

  defp complete_transition_action(record, attrs, opts, now, action) do
    case update_review(
           opts,
           record,
           Map.merge(attrs, %{
             status: "#{action}_requested",
             target_issue_state: @active_state,
             last_action: action,
             last_action_at: now,
             updated_at: now
           })
         ) do
      :ok ->
        {:state_transitioned, Map.get(record, :issue_id), action_atom(action), @active_state}

      {:error, reason} ->
        {:state_transition_update_error, Map.get(record, :issue_id), action_atom(action), reason}
    end
  end

  defp record_transition_error(record, attrs, opts, now, action, reason) do
    case update_review(
           opts,
           record,
           Map.merge(attrs, %{
             status: "state_transition_error",
             error: inspect(reason),
             last_action: action,
             last_action_at: nil,
             updated_at: now
           })
         ) do
      :ok ->
        {:state_transition_error, Map.get(record, :issue_id), action_atom(action), reason}

      {:error, update_reason} ->
        {:state_transition_error_update_failed, Map.get(record, :issue_id), action_atom(action), reason, update_reason}
    end
  end

  defp cleanup_review(record, opts, now, reason) do
    workspace = Keyword.get(opts, :workspace, Workspace)
    run_store = Keyword.get(opts, :run_store, RunStore)

    if workspace_removed?(record) do
      delete_review_after_cleanup(run_store, record, reason)
    else
      case workspace.remove(Map.get(record, :workspace_path), Map.get(record, :worker_host)) do
        {:ok, _removed_paths} ->
          finish_workspace_cleanup(record, opts, now, reason)

        {:error, cleanup_reason, output} ->
          complete_review_update(
            opts,
            record,
            %{
              status: "cleanup_error",
              error: inspect({cleanup_reason, output}),
              updated_at: now
            },
            {:cleanup_error, Map.get(record, :issue_id), cleanup_reason}
          )

        other ->
          complete_review_update(
            opts,
            record,
            %{
              status: "cleanup_error",
              error: inspect(other),
              updated_at: now
            },
            {:cleanup_error, Map.get(record, :issue_id), other}
          )
      end
    end
  end

  defp finish_workspace_cleanup(record, opts, now, reason) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    case mark_workspace_removed(record, opts, now) do
      {:ok, updated_record} ->
        delete_review_after_cleanup(run_store, updated_record, reason)

      {:error, update_reason} ->
        {:cleanup_error, Map.get(record, :issue_id), update_reason}
    end
  end

  defp mark_workspace_removed(record, opts, now) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    attrs = %{
      status: "cleanup_pending",
      error: nil,
      workspace_removed_at: now,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok ->
        {:ok, Map.merge(record, attrs)}

      {:error, reason} ->
        persist_workspace_removed_after_update_error(run_store, record, attrs, reason)
    end
  end

  defp persist_workspace_removed_after_update_error(run_store, record, attrs, update_reason) do
    issue_id = Map.get(record, :issue_id)
    updated_record = Map.merge(record, attrs)

    Logger.warning("Failed to update PR review workspace removal issue_id=#{issue_id}; attempting full record write: #{inspect(update_reason)}")

    case persist_pr_review(run_store, updated_record) do
      :ok ->
        {:ok, updated_record}

      {:error, put_reason} ->
        Logger.warning("Failed to persist PR review workspace removal issue_id=#{issue_id}: #{inspect(put_reason)}")

        {:error, {:workspace_removed_update_failed, update_reason, put_reason}}
    end
  end

  defp workspace_removed?(record) do
    match?(%DateTime{}, Map.get(record, :workspace_removed_at)) or
      Map.get(record, :status) == "cleanup_pending"
  end

  defp delete_review_after_cleanup(run_store, record, reason) do
    case run_store.delete_pr_review(Map.get(record, :issue_id)) do
      :ok ->
        {:cleanup, Map.get(record, :issue_id), reason}

      {:error, delete_reason} ->
        Logger.warning("Failed to delete PR review record issue_id=#{Map.get(record, :issue_id)} after cleanup: #{inspect(delete_reason)}")

        {:cleanup_error, Map.get(record, :issue_id), delete_reason}
    end
  end

  defp first_pr_url(%Issue{pr_urls: [url | _rest]}) when is_binary(url), do: url
  defp first_pr_url(_issue), do: nil

  defp latest_run_for_issue(runs, issue_id) when is_list(runs) and is_binary(issue_id) do
    runs
    |> Enum.filter(&review_run_for_issue?(&1, issue_id))
    |> Enum.max_by(&run_started_at_sort_key/1, fn -> nil end)
  end

  defp review_run_for_issue?(run, issue_id) do
    Map.get(run, :issue_id) == issue_id and
      Map.get(run, :status) in ["success", "stopped"] and
      is_binary(Map.get(run, :workspace_path))
  end

  defp run_started_at_sort_key(run) do
    case Map.get(run, :started_at) do
      %DateTime{} = started_at -> DateTime.to_unix(started_at, :microsecond)
      _started_at -> 0
    end
  end

  defp handled_activity?(record, latest_activity_at) do
    case {Map.get(record, :last_action_at), latest_activity_at} do
      {%DateTime{} = last_action_at, %DateTime{} = latest} ->
        DateTime.compare(last_action_at, latest) in [:gt, :eq]

      _ ->
        false
    end
  end

  defp cooldown_elapsed?(%DateTime{} = latest_activity_at, %DateTime{} = now, cooldown_minutes) do
    DateTime.diff(now, latest_activity_at, :second) >= cooldown_minutes * 60
  end

  defp cooldown_elapsed?(_latest_activity_at, _now, _cooldown_minutes), do: true

  defp stale?(%DateTime{} = latest_activity_at, %DateTime{} = now, stale_days) do
    DateTime.diff(now, latest_activity_at, :day) >= stale_days
  end

  defp stale?(_latest_activity_at, _now, _stale_days), do: false

  defp closed_pr_state?(state) do
    state
    |> normalize_decision()
    |> then(&(&1 in @closed_pr_states))
  end

  defp normalize_decision(value) when is_binary(value) do
    value |> String.trim() |> String.upcase()
  end

  defp normalize_decision(_value), do: nil

  defp list_runs(run_store) do
    case run_store.list_runs(:all) do
      runs when is_list(runs) -> {:ok, runs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_pr_reviews(run_store) do
    case run_store.list_pr_reviews() do
      reviews when is_list(reviews) -> {:ok, reviews}
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_pr_review(run_store, record) do
    case run_store.put_pr_review(record) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_review(opts, record, attrs) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    issue_id = Map.get(record, :issue_id)

    case run_store.update_pr_review(issue_id, attrs) do
      :ok ->
        :ok

      {:error, :pr_review_not_found} ->
        upsert_review(run_store, record, attrs)

      {:error, reason} ->
        log_review_store_error("update", issue_id, attrs, reason)
        {:error, {:update_pr_review_failed, reason}}
    end
  end

  defp upsert_review(run_store, record, attrs) do
    issue_id = Map.get(record, :issue_id)

    case run_store.put_pr_review(Map.merge(record, attrs)) do
      :ok ->
        :ok

      {:error, reason} ->
        log_review_store_error("upsert", issue_id, attrs, reason)
        {:error, {:put_pr_review_failed, reason}}
    end
  end

  defp complete_review_update(opts, record, attrs, success_action) do
    case update_review(opts, record, attrs) do
      :ok -> success_action
      {:error, reason} -> {:update_error, Map.get(record, :issue_id), reason}
    end
  end

  defp log_review_store_error(operation, issue_id, attrs, reason) do
    Logger.warning("Failed to #{operation} PR review record issue_id=#{issue_id} target_status=#{inspect(Map.get(attrs, :status))}: #{inspect(reason)}")
  end

  defp backoff_active_until(record, now) do
    case Map.get(record, :next_poll_at) do
      %DateTime{} = next_poll_at ->
        if DateTime.compare(next_poll_at, now) == :gt do
          {:backing_off, next_poll_at}
        else
          :ready
        end

      _next_poll_at ->
        :ready
    end
  end

  defp poll_error_attrs(record, reason, opts, now) do
    consecutive_errors = consecutive_errors(record) + 1

    attrs = %{
      status: "poll_error",
      error: inspect(reason),
      consecutive_errors: consecutive_errors,
      updated_at: now
    }

    if consecutive_errors >= @github_error_backoff_threshold do
      Map.put(attrs, :next_poll_at, DateTime.add(now, github_error_backoff_ms(consecutive_errors, opts), :millisecond))
    else
      Map.put(attrs, :next_poll_at, nil)
    end
  end

  defp consecutive_errors(record) do
    case Map.get(record, :consecutive_errors) do
      value when is_integer(value) and value >= 0 -> value
      _value -> 0
    end
  end

  defp github_error_backoff_ms(consecutive_errors, opts) do
    exponent = max(consecutive_errors - @github_error_backoff_threshold, 0)

    poll_interval_ms(opts)
    |> Kernel.*(Integer.pow(2, exponent))
    |> min(@max_github_error_backoff_ms)
  end

  defp action_atom("rework"), do: :rework
  defp action_atom("merge"), do: :merge

  defp schedule_poll(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.timer_ref) do
      Process.cancel_timer(state.timer_ref)
    end

    %{state | timer_ref: Process.send_after(self(), :poll, delay_ms)}
  end

  defp poll_interval_ms(opts) do
    case Keyword.get(opts, :poll_interval_ms) do
      interval when is_integer(interval) and interval > 0 ->
        interval

      _ ->
        Config.settings!().polling.interval_ms
    end
  end
end
