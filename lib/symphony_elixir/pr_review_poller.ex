defmodule SymphonyElixir.PrReviewPoller do
  @moduledoc """
  Polling-mode pull request review poller.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{CiPoller, Config, Notifications, RunStore, Tracker, Workspace}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Learnings.Reflection
  alias SymphonyElixir.Linear.Issue

  @in_review_state "In Review"
  @active_state "In Progress"
  @changes_requested "CHANGES_REQUESTED"
  @approved "APPROVED"
  @closed_pr_states ["CLOSED"]
  @merged_pr_state "MERGED"
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

  @doc false
  @spec pending_reviewer_comments(String.t(), keyword()) :: [map()]
  def pending_reviewer_comments(issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = repo_key_from_opts(opts)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    pending_reviewer_comments(issue_id, run_store, repo_key, now)
  end

  defp pending_reviewer_comments(issue_id, run_store, repo_key, now) when is_binary(issue_id) do
    case list_pr_reviews(run_store, repo_key) do
      {:ok, reviews} ->
        comments_from_review_record(reviews, issue_id, run_store, now)

      {:error, reason} ->
        record_pending_comment_lookup_error(run_store, repo_key, issue_id, reason, now)
        []
    end
  end

  defp pending_reviewer_comments(_issue_id, _run_store, _repo_key, _now), do: []

  defp comments_from_review_record(reviews, issue_id, run_store, now) do
    case Enum.find(reviews, &(Map.get(&1, :issue_id) == issue_id)) do
      %{} = record ->
        clear_pending_comment_lookup_error(run_store, record, now)

        record
        |> Map.get(:pending_reviewer_comments, [])
        |> normalize_comments()

      nil ->
        []
    end
  end

  @doc false
  @spec complete_pending_reviewer_comments(String.t(), keyword()) :: :ok | {:error, term()}
  def complete_pending_reviewer_comments(issue_id, opts \\ []) do
    if is_binary(issue_id) do
      do_complete_pending_reviewer_comments(issue_id, opts)
    else
      :ok
    end
  end

  defp do_complete_pending_reviewer_comments(issue_id, opts) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = repo_key_from_opts(opts)

    case fetch_pr_review_record(run_store, repo_key, issue_id) do
      {:ok, record} -> complete_reviewer_comment_record(record, opts)
      :missing -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_pr_review_record(run_store, repo_key, issue_id) do
    case list_pr_reviews(run_store, repo_key) do
      {:ok, reviews} ->
        case Enum.find(reviews, &(Map.get(&1, :issue_id) == issue_id)) do
          %{} = record -> {:ok, record}
          nil -> :missing
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp complete_reviewer_comment_record(record, opts) do
    if Map.get(record, :status) == "rework_requested" do
      do_complete_reviewer_comment_record(record, opts)
    else
      :ok
    end
  end

  defp do_complete_reviewer_comment_record(record, opts) do
    github = Keyword.get(opts, :github, PullRequest)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    comments = record |> Map.get(:pending_reviewer_comments, []) |> normalize_comments()
    cursor = Map.get(record, :pending_last_addressed_comment_id) || latest_comment_id(comments)

    if comments == [] and is_nil(cursor) do
      :ok
    else
      complete_reviewer_comment_record(record, comments, cursor, github, opts, now)
    end
  end

  defp complete_reviewer_comment_record(record, comments, cursor, github, opts, now) do
    with {:ok, settings} <- poll_settings(opts),
         :ok <- ensure_pending_comment_lookup_succeeded(record),
         {:ok, record} <- maybe_backfill_review_issue_details(record, opts, now),
         {:ok, record} <- maybe_reply_to_comments(record, comments, settings, github, opts, now),
         {:ok, record} <- advance_reviewer_comment_cursor(record, cursor, opts, now) do
      maybe_request_review(record, comments, settings, github, opts, now)
      emit_rework_pushed(record, comments, cursor, now)
    end
  end

  defp ensure_pending_comment_lookup_succeeded(record) do
    case Map.get(record, :pending_reviewer_comments_lookup_error) do
      value when value in [nil, ""] -> :ok
      reason -> {:error, {:pending_reviewer_comments_lookup_error, reason}}
    end
  end

  defp advance_reviewer_comment_cursor(record, cursor, opts, now) do
    attrs = %{
      last_addressed_comment_id: cursor,
      last_addressed_comment_at: now,
      pending_reviewer_comments: [],
      pending_last_addressed_comment_id: nil,
      replied_comment_ids: [],
      pending_reviewer_comments_lookup_error: nil,
      pending_reviewer_comments_lookup_error_at: nil,
      auto_reply_state_update_error: nil,
      auto_reply_state_update_error_at: nil,
      auto_request_review_error: nil,
      auto_request_review_error_at: nil,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok -> {:ok, Map.merge(record, attrs)}
      {:error, reason} -> {:error, reason}
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
    repo_key = repo_key_from_opts(opts)
    tracker = Keyword.get(opts, :tracker, Tracker)
    current_gh_user = resolve_current_gh_user(opts)

    with {:ok, discovered} <- discover_reviews(run_store, tracker, repo_key, now),
         {:ok, reviews} <- list_pr_reviews(run_store, repo_key) do
      actions =
        reviews
        |> Enum.map(&process_review(&1, settings, current_gh_user, opts, now))

      {:ok, %{mode: :polling, discovered: discovered, processed: length(reviews), actions: actions}}
    end
  end

  defp resolve_current_gh_user(opts) do
    case Keyword.fetch(opts, :current_gh_user) do
      {:ok, value} ->
        normalize_user(value)

      :error ->
        opts |> detect_current_gh_user() |> normalize_user()
    end
  end

  defp detect_current_gh_user(opts) do
    github = Keyword.get(opts, :github, PullRequest)

    if function_exported?(github, :current_user, 1) do
      case github.current_user(opts) do
        {:ok, login} when is_binary(login) ->
          login

        {:error, reason} ->
          Logger.debug("PR review current gh user detection failed: #{inspect(reason)}")
          nil

        _other ->
          nil
      end
    else
      nil
    end
  end

  defp discover_reviews(run_store, tracker, repo_key, now) do
    with {:ok, issues} <- tracker.fetch_issues_by_states([@in_review_state]),
         {:ok, runs} <- list_runs(run_store, repo_key),
         {:ok, existing} <- list_pr_reviews(run_store, repo_key) do
      existing_by_issue = Map.new(existing, &{Map.get(&1, :issue_id), &1})

      discovered =
        issues
        |> Enum.filter(&match?(%Issue{}, &1))
        |> Enum.count(&persist_discovered_review?(&1, runs, existing_by_issue, run_store, repo_key, now))

      {:ok, discovered}
    end
  end

  defp persist_discovered_review?(%Issue{} = issue, runs, existing_by_issue, run_store, repo_key, now) do
    existing = Map.get(existing_by_issue, issue.id)

    case discover_review_record(issue, runs, existing, now) do
      nil ->
        false

      record ->
        case persist_pr_review(run_store, Map.put(record, :repo_key, repo_key)) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning("Failed to persist discovered PR review record issue_id=#{issue.id}: #{inspect(reason)}")

            false
        end
    end
  end

  defp discover_review_record(%Issue{} = issue, runs, %{workspace_path: workspace_path} = existing, now)
       when is_binary(workspace_path) and workspace_path != "" do
    attrs =
      existing
      |> missing_review_detail_attrs(issue)
      |> missing_run_detail_attrs(existing, latest_run_for_issue(runs, issue.id))
      |> maybe_put_updated_at(now)

    if map_size(attrs) > 0 do
      Map.merge(existing, attrs)
    end
  end

  defp discover_review_record(%Issue{} = issue, runs, existing, now) when is_list(runs) do
    with pr_url when is_binary(pr_url) <- first_pr_url(issue),
         %{workspace_path: workspace_path} = run when is_binary(workspace_path) <-
           latest_run_for_issue(runs, issue.id) do
      base = %{
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_title: issue.title,
        issue_url: issue.url,
        pr_url: pr_url,
        run_id: Map.get(run, :run_id),
        transcript_path: Map.get(run, :transcript_path),
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

  defp log_poll_action_warning({:state_transition_deferred, issue_id, action, _target_state}) do
    Logger.info("PR review transition deferred while dispatch is paused issue_id=#{issue_id} action=#{action}")
  end

  defp log_poll_action_warning({:update_error, issue_id, reason}) do
    Logger.warning("PR review update error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning(_action), do: :ok

  defp process_review(record, settings, current_gh_user, opts, now) when is_map(record) do
    case backoff_active_until(record, now) do
      {:backing_off, next_poll_at} ->
        {:backing_off, Map.get(record, :issue_id), next_poll_at}

      :ready ->
        fetch_and_process_review(record, settings, current_gh_user, opts, now)
    end
  end

  defp fetch_and_process_review(record, settings, current_gh_user, opts, now) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_activity(Map.get(record, :pr_url), cwd: Map.get(record, :workspace_path)) do
      {:ok, activity} ->
        handle_activity(record, activity, settings, current_gh_user, opts, now)

      {:error, reason} ->
        record_poll_error(record, reason, opts, now)
    end
  end

  defp record_poll_error(record, reason, opts, now) do
    attrs = poll_error_attrs(record, reason, opts, now)
    maybe_emit_poll_run_failed(record, attrs, reason)

    case update_review(opts, record, attrs) do
      :ok ->
        {:poll_error, Map.get(record, :issue_id), reason}

      {:error, update_reason} ->
        {:poll_error_update_failed, Map.get(record, :issue_id), reason, update_reason}
    end
  end

  defp handle_activity(record, activity, settings, current_gh_user, opts, now) do
    {attrs, latest_activity_at, unaddressed_comments} =
      review_activity_attrs(record, activity, settings, current_gh_user, now)

    case review_action(activity, latest_activity_at, unaddressed_comments, settings, now) do
      :merged ->
        record
        |> maybe_capture_learnings(activity, settings, opts, now)
        |> cleanup_review(opts, now, "merged")

      :closed ->
        cleanup_review(record, opts, now, "closed")

      :changes_requested ->
        maybe_transition_rework(record, attrs, settings, opts, now)

      :review_comments ->
        maybe_transition_rework(record, attrs, settings, opts, now)

      :approved ->
        maybe_transition_merge(record, attrs, opts, now)

      :stale ->
        cleanup_review(record, opts, now, "stale")

      :watching ->
        complete_review_update(opts, record, attrs, {:watching, Map.get(record, :issue_id)})
    end
  end

  defp review_activity_attrs(record, activity, settings, current_gh_user, now) do
    latest_activity_at =
      Map.get(activity, :latest_activity_at) ||
        Map.get(record, :last_activity_at) ||
        Map.get(record, :updated_at) ||
        now

    latest_review_activity_at =
      Map.get(activity, :latest_review_activity_at) ||
        Map.get(record, :last_review_activity_at) ||
        latest_activity_at

    ignored_users = ignored_review_users(settings, activity, current_gh_user)
    unaddressed_comments = unaddressed_reviewer_comments(record, Map.get(activity, :comments, []), ignored_users)
    latest_unaddressed_comment_at = latest_comment_activity_at(unaddressed_comments)

    attrs =
      %{
        status: "watching",
        error: nil,
        consecutive_errors: 0,
        next_poll_at: nil,
        last_activity_at: latest_activity_at,
        last_review_activity_at: latest_review_activity_at,
        last_unaddressed_comment_at: latest_unaddressed_comment_at,
        last_review_decision: Map.get(activity, :review_decision),
        updated_at: now
      }
      |> maybe_put_pending_comments(record, unaddressed_comments)

    {attrs, latest_activity_at, unaddressed_comments}
  end

  defp review_action(activity, latest_activity_at, unaddressed_comments, settings, now) do
    review_decision = normalize_decision(Map.get(activity, :review_decision))

    cond do
      merged_pr_state?(Map.get(activity, :state)) -> :merged
      closed_pr_state?(Map.get(activity, :state)) -> :closed
      review_decision == @changes_requested -> :changes_requested
      review_decision == @approved -> :approved
      unaddressed_comments != [] -> :review_comments
      stale?(latest_activity_at, now, settings.pr_review.stale_days) -> :stale
      true -> :watching
    end
  end

  defp maybe_transition_rework(record, attrs, settings, opts, now) do
    latest_activity_at = action_activity_at(attrs)
    issue_id = Map.get(record, :issue_id)

    cond do
      CiPoller.ci_owned_issue?(issue_id, Keyword.take(opts, [:run_store])) ->
        complete_review_update(opts, record, Map.merge(attrs, %{status: "ci_owned"}), {:ci_owned, issue_id, :rework})

      handled_activity?(record, latest_activity_at) ->
        complete_review_update(opts, record, attrs, {:already_handled, issue_id, :rework})

      !cooldown_elapsed?(latest_activity_at, now, settings.pr_review.cooldown_minutes) ->
        complete_review_update(opts, record, Map.merge(attrs, %{status: "cooling_down"}), {:cooling_down, issue_id})

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
    Map.get(attrs, :last_unaddressed_comment_at) ||
      Map.get(attrs, :last_review_activity_at) ||
      Map.fetch!(attrs, :last_activity_at)
  end

  defp transition_issue_for_action(record, attrs, opts, now, action) do
    issue_id = Map.get(record, :issue_id)

    if dispatch_paused?(opts) do
      defer_transition_action(record, attrs, opts, now, action)
    else
      tracker = Keyword.get(opts, :tracker, Tracker)

      case tracker.update_issue_state(issue_id, @active_state) do
        :ok ->
          complete_transition_action(record, attrs, opts, now, action)

        {:error, reason} ->
          record_transition_error(record, attrs, opts, now, action, reason)
      end
    end
  end

  defp defer_transition_action(record, attrs, opts, now, action) do
    complete_review_update(
      opts,
      record,
      Map.merge(attrs, %{
        status: "#{action}_deferred",
        target_issue_state: @active_state,
        last_action: nil,
        last_action_at: nil,
        error: nil,
        updated_at: now
      }),
      {:state_transition_deferred, Map.get(record, :issue_id), action_atom(action), @active_state}
    )
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
        maybe_emit_reviewer_commented(record, attrs, action, now)
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
            cleanup_error_attrs(record, {cleanup_reason, output}, opts, now),
            {:cleanup_error, Map.get(record, :issue_id), cleanup_reason}
          )

        other ->
          complete_review_update(
            opts,
            record,
            cleanup_error_attrs(record, other, opts, now),
            {:cleanup_error, Map.get(record, :issue_id), other}
          )
      end
    end
  end

  defp maybe_capture_learnings(record, activity, settings, opts, now) do
    learnings = Map.get(settings, :learnings)

    cond do
      not learnings_enabled?(learnings) ->
        record

      learning_reflection_attempted?(record) ->
        record

      true ->
        do_capture_learnings(record, activity, learnings, opts, now)
    end
  end

  defp do_capture_learnings(record, activity, learnings, opts, now) do
    case mark_learning_reflection_started(record, opts, now) do
      {:ok, started_record} ->
        issue = learning_reflection_issue(started_record, opts)

        result =
          capture_learnings_safely(
            started_record,
            %{record: started_record, activity: activity, issue: issue},
            learnings,
            opts_for_reflection(opts, now)
          )

        started_record
        |> learning_reflection_result_attrs(result, now)
        |> persist_learning_reflection_result(started_record, opts)

      {:error, reason} ->
        Logger.warning("Failed to mark learning reflection started issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
        record
    end
  end

  defp capture_learnings_safely(record, source, learnings, opts) do
    Reflection.capture(source, learnings, opts)
  rescue
    exception ->
      stacktrace = __STACKTRACE__
      log_learning_reflection_crash(record, :error, exception, stacktrace)
      {:error, {:capture_crashed, :error, exception}}
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      log_learning_reflection_crash(record, kind, reason, stacktrace)
      {:error, {:capture_crashed, kind, reason}}
  end

  defp log_learning_reflection_crash(record, kind, reason, stacktrace) do
    issue_id = Map.get(record, :issue_id)

    Logger.error(
      "Learning reflection crashed issue_id=#{issue_id}: " <>
        Exception.format(kind, reason, stacktrace)
    )
  end

  defp opts_for_reflection(opts, now) do
    opts
    |> Keyword.put(:now, now)
    |> Keyword.put_new(:run_store, Keyword.get(opts, :run_store, RunStore))
  end

  defp learnings_enabled?(%{enabled: true}), do: true
  defp learnings_enabled?(_learnings), do: false

  defp learning_reflection_attempted?(record) do
    Map.get(record, :learning_reflection_started_at) != nil or Map.get(record, :learning_reflected_at) != nil
  end

  defp mark_learning_reflection_started(record, opts, now) do
    attrs = %{
      learning_reflection_started_at: now,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok -> {:ok, Map.merge(record, attrs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp learning_reflection_result_attrs(_record, {:ok, count}, now) do
    %{
      learning_reflected_at: now,
      learning_reflection_count: count,
      learning_reflection_error: nil,
      updated_at: now
    }
  end

  defp learning_reflection_result_attrs(_record, {:discarded, reason}, now) do
    %{
      learning_reflected_at: now,
      learning_reflection_count: 0,
      learning_reflection_error: inspect({:discarded, reason}),
      updated_at: now
    }
  end

  defp learning_reflection_result_attrs(_record, {:error, reason}, now) do
    %{
      learning_reflected_at: now,
      learning_reflection_count: 0,
      learning_reflection_error: inspect(reason),
      updated_at: now
    }
  end

  defp persist_learning_reflection_result(attrs, record, opts) do
    case update_review(opts, record, attrs) do
      :ok ->
        Map.merge(record, attrs)

      {:error, reason} ->
        Logger.warning("Failed to persist learning reflection result issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
        record
    end
  end

  defp learning_reflection_issue(record, opts) do
    case fetch_review_issue(record, opts) do
      {:ok, %Issue{} = issue} -> issue
      _other -> issue_from_review_record(record)
    end
  end

  defp issue_from_review_record(record) do
    %Issue{
      id: Map.get(record, :issue_id),
      identifier: Map.get(record, :issue_identifier),
      title: Map.get(record, :issue_title),
      url: Map.get(record, :issue_url),
      pr_urls: [Map.get(record, :pr_url)] |> Enum.filter(&present?/1)
    }
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
      consecutive_errors: 0,
      next_poll_at: nil,
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
    case Map.get(record, :repo_key) do
      repo_key when is_binary(repo_key) ->
        case delete_pr_review_record(run_store, repo_key, Map.get(record, :issue_id)) do
          :ok ->
            {:cleanup, Map.get(record, :issue_id), reason}

          {:error, delete_reason} ->
            Logger.warning("Failed to delete PR review record issue_id=#{Map.get(record, :issue_id)} after cleanup: #{inspect(delete_reason)}")

            {:cleanup_error, Map.get(record, :issue_id), delete_reason}
        end

      _repo_key ->
        {:cleanup_error, Map.get(record, :issue_id), :missing_repo_key}
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

  defp maybe_put_pending_comments(attrs, _record, comments) when is_list(comments) and comments != [] do
    attrs
    |> Map.put(:pending_reviewer_comments, comments)
    |> Map.put(:pending_last_addressed_comment_id, latest_comment_id(comments))
  end

  defp maybe_put_pending_comments(attrs, record, []) do
    if pending_comment_cursor_caught_up?(record) do
      attrs
      |> Map.put(:pending_reviewer_comments, [])
      |> Map.put(:pending_last_addressed_comment_id, nil)
    else
      attrs
    end
  end

  defp maybe_put_pending_comments(attrs, _record, _comments), do: attrs

  defp pending_comment_cursor_caught_up?(record) when is_map(record) do
    pending_comments = record |> Map.get(:pending_reviewer_comments, []) |> normalize_comments()
    pending_cursor = Map.get(record, :pending_last_addressed_comment_id) || latest_comment_id(pending_comments)
    addressed_cursor = Map.get(record, :last_addressed_comment_id)

    is_binary(pending_cursor) and pending_cursor != "" and pending_cursor == addressed_cursor
  end

  defp unaddressed_reviewer_comments(record, comments, ignored_users) when is_list(ignored_users) do
    comments =
      comments
      |> normalize_comments()
      |> Enum.reject(&(ignored_comment?(&1, ignored_users) or String.trim(Map.get(&1, :body, "")) == ""))
      |> sort_comments()

    comments
    |> comments_after_cursor(Map.get(record, :last_addressed_comment_id))
    |> comments_after_last_action(record)
  end

  defp normalize_comments(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_comment/1)
    |> Enum.reject(&(Map.get(&1, :id) in [nil, ""]))
  end

  defp normalize_comments(_comments), do: []

  defp normalize_comment(comment) when is_map(comment) do
    %{
      id: string_field(comment, :id) || fallback_comment_id(comment),
      kind: string_field(comment, :kind),
      author: string_field(comment, :author),
      body: string_field(comment, :body) || "",
      url: string_field(comment, :url),
      path: string_field(comment, :path),
      line: integer_field(comment, :line),
      created_at: datetime_field(comment, :created_at),
      updated_at: datetime_field(comment, :updated_at)
    }
  end

  defp normalize_comment(_comment), do: %{id: nil}

  defp ignored_comment?(comment, ignored_users) when is_list(ignored_users) do
    author = normalize_user(Map.get(comment, :author))

    author != nil and author in ignored_users
  end

  defp ignored_review_users(settings, activity, current_gh_user) do
    (configured_ignored_users(settings) ++
       [Map.get(activity || %{}, :pr_author), current_gh_user])
    |> Enum.map(&normalize_user/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp configured_ignored_users(%{pr_review: pr_review}) do
    Map.get(pr_review, :ignored_users) || []
  end

  defp configured_ignored_users(_settings), do: []

  defp normalize_user(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(fn
      "" -> nil
      user -> user
    end)
  end

  defp normalize_user(_value), do: nil

  defp sort_comments(comments) do
    Enum.sort_by(comments, fn comment ->
      {comment_sort_timestamp(comment), Map.get(comment, :id)}
    end)
  end

  defp comments_after_cursor(comments, cursor) when is_binary(cursor) and cursor != "" do
    case Enum.split_while(comments, &(Map.get(&1, :id) != cursor)) do
      {_before, [_cursor | after_cursor]} -> after_cursor
      {_all, []} -> comments
    end
  end

  defp comments_after_cursor(comments, _cursor), do: comments

  defp comments_after_last_action(comments, record) do
    case Map.get(record, :last_action_at) do
      %DateTime{} = last_action_at ->
        Enum.reject(comments, &comment_handled_by_action?(&1, last_action_at))

      _ ->
        comments
    end
  end

  defp latest_comment_id([]), do: nil

  defp latest_comment_id(comments) when is_list(comments) do
    comments
    |> sort_comments()
    |> List.last()
    |> case do
      nil -> nil
      comment -> Map.get(comment, :id)
    end
  end

  defp latest_comment_activity_at(comments) when is_list(comments) do
    comments
    |> Enum.map(&comment_activity_at/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp comment_activity_at(comment) when is_map(comment), do: Map.get(comment, :updated_at) || Map.get(comment, :created_at)
  defp comment_activity_at(_comment), do: nil

  defp comment_handled_by_action?(comment, last_action_at) do
    case comment_activity_at(comment) do
      %DateTime{} = activity_at -> DateTime.compare(activity_at, last_action_at) in [:lt, :eq]
      _ -> false
    end
  end

  defp comment_sort_timestamp(comment) do
    case comment_activity_at(comment) do
      %DateTime{} = datetime -> DateTime.to_unix(datetime, :microsecond)
      _ -> 0
    end
  end

  defp fallback_comment_id(comment) when is_map(comment) do
    [
      string_field(comment, :kind),
      string_field(comment, :author),
      string_field(comment, :url),
      string_field(comment, :body),
      datetime_field(comment, :created_at),
      datetime_field(comment, :updated_at)
    ]
    |> Enum.map_join("|", &fallback_id_part/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fallback_id_part(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp fallback_id_part(nil), do: ""
  defp fallback_id_part(value), do: to_string(value)

  defp string_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp integer_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp datetime_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      %DateTime{} = datetime -> datetime
      _value -> nil
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

  defp merged_pr_state?(state) do
    state
    |> normalize_decision()
    |> then(&(&1 == @merged_pr_state))
  end

  defp normalize_decision(value) when is_binary(value) do
    value |> String.trim() |> String.upcase()
  end

  defp normalize_decision(_value), do: nil

  defp list_runs(run_store, repo_key) do
    case list_run_records(run_store, repo_key) do
      runs when is_list(runs) -> {:ok, runs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_pr_reviews(run_store, repo_key) do
    case list_pr_review_records(run_store, repo_key) do
      reviews when is_list(reviews) -> {:ok, reviews}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_run_records(run_store, repo_key) do
    cond do
      function_exported?(run_store, :list_runs, 2) ->
        run_store.list_runs(repo_key, :all)

      function_exported?(run_store, :list_runs, 1) ->
        run_store.list_runs(:all)

      true ->
        {:error, :runs_unsupported}
    end
  end

  defp list_pr_review_records(run_store, repo_key) do
    cond do
      function_exported?(run_store, :list_pr_reviews, 1) ->
        run_store.list_pr_reviews(repo_key)

      function_exported?(run_store, :list_pr_reviews, 0) ->
        run_store.list_pr_reviews()

      true ->
        {:error, :pr_reviews_unsupported}
    end
  end

  defp repo_key_from_opts(opts), do: Keyword.get_lazy(opts, :repo_key, &Config.repo_key!/0)

  defp delete_pr_review_record(run_store, repo_key, issue_id) do
    cond do
      function_exported?(run_store, :delete_pr_review, 2) ->
        run_store.delete_pr_review(repo_key, issue_id)

      function_exported?(run_store, :delete_pr_review, 1) ->
        run_store.delete_pr_review(issue_id)

      true ->
        {:error, :pr_reviews_unsupported}
    end
  end

  defp clear_pending_comment_lookup_error(run_store, record, now) do
    if Map.get(record, :pending_reviewer_comments_lookup_error) in [nil, ""] do
      :ok
    else
      issue_id = Map.get(record, :issue_id)

      attrs = %{
        pending_reviewer_comments_lookup_error: nil,
        pending_reviewer_comments_lookup_error_at: nil,
        updated_at: now
      }

      case update_review_direct(run_store, Map.fetch!(record, :repo_key), issue_id, attrs) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to clear pending PR review comment lookup error issue_id=#{issue_id}: #{inspect(reason)}")
      end
    end
  end

  defp record_pending_comment_lookup_error(run_store, repo_key, issue_id, reason, now) do
    Logger.warning("Failed to load pending PR review comments issue_id=#{issue_id}: #{inspect(reason)}")

    attrs = %{
      pending_reviewer_comments_lookup_error: inspect(reason),
      pending_reviewer_comments_lookup_error_at: now,
      updated_at: now
    }

    case update_review_direct(run_store, repo_key, issue_id, attrs) do
      :ok ->
        :ok

      {:error, update_reason} ->
        Logger.warning("Failed to record pending PR review comment lookup error issue_id=#{issue_id} reason=#{inspect(reason)}: #{inspect(update_reason)}")
    end
  end

  defp update_review_direct(run_store, repo_key, issue_id, attrs) when is_binary(issue_id) do
    cond do
      function_exported?(run_store, :update_pr_review, 3) ->
        case run_store.update_pr_review(repo_key, issue_id, attrs) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      function_exported?(run_store, :update_pr_review, 2) ->
        case run_store.update_pr_review(issue_id, attrs) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :update_pr_review_unavailable}
    end
  end

  defp update_review_direct(_run_store, _repo_key, _issue_id, _attrs), do: {:error, :invalid_issue_id}

  defp persist_pr_review(run_store, record) do
    case run_store.put_pr_review(record) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp update_review(opts, record, attrs) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    issue_id = Map.get(record, :issue_id)

    case Map.get(record, :repo_key) || Keyword.get(opts, :repo_key) do
      repo_key when is_binary(repo_key) ->
        case update_review_direct(run_store, repo_key, issue_id, attrs) do
          :ok ->
            :ok

          {:error, :pr_review_not_found} ->
            upsert_review(run_store, repo_key, record, attrs)

          {:error, reason} ->
            log_review_store_error("update", issue_id, attrs, reason)
            {:error, {:update_pr_review_failed, reason}}
        end

      _repo_key ->
        {:error, :missing_repo_key}
    end
  end

  defp upsert_review(run_store, repo_key, record, attrs) do
    issue_id = Map.get(record, :issue_id)

    case run_store.put_pr_review(record |> Map.merge(attrs) |> Map.put(:repo_key, repo_key)) do
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

  defp dispatch_paused?(opts) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    if function_exported?(run_store, :get_paused, 0) do
      case run_store.get_paused() do
        %{paused: true} -> true
        _ -> false
      end
    else
      false
    end
  end

  defp maybe_backfill_review_issue_details(record, opts, now) do
    if present?(Map.get(record, :issue_title)) do
      {:ok, record}
    else
      record
      |> fetch_review_issue(opts)
      |> backfill_review_issue_details(record, opts, now)
    end
  end

  defp fetch_review_issue(record, opts) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)

    with issue_id when is_binary(issue_id) and issue_id != "" <- issue_id,
         {:ok, issues} <- tracker.fetch_issue_states_by_ids([issue_id]),
         %Issue{} = issue <- Enum.find(issues, &(&1.id == issue_id)) do
      {:ok, issue}
    else
      nil -> :missing
      "" -> :missing
      {:error, reason} -> {:error, reason}
      _other -> :missing
    end
  end

  defp backfill_review_issue_details({:ok, %Issue{} = issue}, record, opts, now) do
    attrs =
      record
      |> missing_issue_detail_attrs(issue)
      |> maybe_put_updated_at(now)

    if map_size(attrs) > 0 do
      case update_review(opts, record, attrs) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("Failed to backfill PR review issue details issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
      end

      {:ok, Map.merge(record, attrs)}
    else
      {:ok, record}
    end
  end

  defp backfill_review_issue_details(:missing, record, _opts, _now), do: {:ok, record}

  defp backfill_review_issue_details({:error, reason}, record, _opts, _now) do
    Logger.debug("Failed to fetch PR review issue details issue_id=#{Map.get(record, :issue_id)}: #{inspect(reason)}")
    {:ok, record}
  end

  defp missing_issue_detail_attrs(record, %Issue{} = issue) do
    %{}
    |> maybe_put_missing(:issue_identifier, record, issue.identifier)
    |> maybe_put_missing(:issue_title, record, issue.title)
    |> maybe_put_missing(:issue_url, record, issue.url)
  end

  defp missing_review_detail_attrs(record, %Issue{} = issue) do
    record
    |> missing_issue_detail_attrs(issue)
    |> maybe_put_missing(:pr_url, record, first_pr_url(issue))
  end

  defp missing_run_detail_attrs(attrs, _record, nil), do: attrs

  defp missing_run_detail_attrs(attrs, record, run) when is_map(run) do
    attrs
    |> maybe_put_missing(:run_id, record, Map.get(run, :run_id))
    |> maybe_put_missing(:transcript_path, record, Map.get(run, :transcript_path))
  end

  defp maybe_put_missing(attrs, key, record, value) do
    if present?(Map.get(record, key)) or not present?(value) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp maybe_put_updated_at(attrs, _now) when map_size(attrs) == 0, do: attrs
  defp maybe_put_updated_at(attrs, now), do: Map.put(attrs, :updated_at, now)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp maybe_reply_to_comments(record, [], _settings, _github, _opts, _now), do: {:ok, record}

  defp maybe_reply_to_comments(record, comments, settings, github, opts, now) do
    case Map.get(settings.pr_review, :auto_reply, false) do
      true -> reply_to_comments(record, comments, github, opts, now)
      _ -> {:ok, record}
    end
  end

  defp reply_to_comments(record, comments, github, opts, now) do
    {inline_comments, pr_level_comments} =
      comments
      |> reject_replied_comments(record)
      |> Enum.split_with(&inline_comment?/1)

    case reply_to_inline_comments(record, inline_comments, github, opts, now) do
      {:ok, record} -> reply_to_pr_level_comments(record, pr_level_comments, github, opts, now)
      {:error, reason} -> {:error, reason}
    end
  end

  defp reject_replied_comments(comments, record) do
    replied_ids = MapSet.new(replied_comment_ids(record))
    Enum.reject(comments, &(Map.get(&1, :id) in replied_ids))
  end

  defp inline_comment?(%{kind: "inline_comment"}), do: true
  defp inline_comment?(_comment), do: false

  defp reply_to_inline_comments(record, comments, github, opts, now) do
    Enum.reduce_while(comments, {:ok, record}, fn comment, {:ok, record} ->
      case reply_to_inline_comment(record, comment, github, opts, now) do
        {:ok, updated_record} -> {:cont, {:ok, updated_record}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reply_to_inline_comment(record, comment, github, opts, now) do
    case github.reply_to_comment(Map.get(record, :pr_url), comment, addressed_comment_reply(), cwd: Map.get(record, :workspace_path)) do
      :ok -> mark_inline_comment_replied(record, comment, opts, now)
      {:error, reason} -> {:error, {:auto_reply_failed, Map.get(comment, :id), reason}}
    end
  end

  defp mark_inline_comment_replied(record, comment, opts, now) do
    case mark_comments_replied(record, [Map.get(comment, :id)], opts, now) do
      {:ok, updated_record} -> {:ok, updated_record}
      {:error, reason} -> handle_auto_reply_state_update_failure(record, [comment], opts, now, reason)
    end
  end

  defp reply_to_pr_level_comments(record, [], _github, _opts, _now), do: {:ok, record}

  defp reply_to_pr_level_comments(record, comments, github, opts, now) do
    summary_comment = %{id: "pr-review-summary", kind: "comment"}

    case github.reply_to_comment(Map.get(record, :pr_url), summary_comment, addressed_comment_summary_reply(comments), cwd: Map.get(record, :workspace_path)) do
      :ok ->
        case mark_comments_replied(record, Enum.map(comments, &Map.get(&1, :id)), opts, now) do
          {:ok, updated_record} -> {:ok, updated_record}
          {:error, reason} -> handle_auto_reply_state_update_failure(record, comments, opts, now, reason)
        end

      {:error, reason} ->
        {:error, {:auto_reply_failed, "pr-review-summary", reason}}
    end
  end

  defp mark_comments_replied(record, comment_ids, opts, now) do
    ids =
      comment_ids
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))

    attrs = %{
      replied_comment_ids: Enum.uniq(replied_comment_ids(record) ++ ids),
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok -> {:ok, Map.merge(record, attrs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_auto_reply_state_update_failure(record, comments, opts, now, reason) do
    ids = comments |> Enum.map(&Map.get(&1, :id)) |> Enum.filter(&is_binary/1)
    issue_id = Map.get(record, :issue_id)

    Logger.error("Auto reply posted but failed to persist replied_comment_ids issue_id=#{issue_id} comment_ids=#{inspect(ids)}; retries may duplicate GitHub replies: #{inspect(reason)}")

    attrs = %{
      auto_reply_state_update_error: inspect({ids, reason}),
      auto_reply_state_update_error_at: now,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok ->
        :ok

      {:error, update_reason} ->
        Logger.error("Failed to record auto reply state update error issue_id=#{issue_id} comment_ids=#{inspect(ids)}: #{inspect(update_reason)}")
    end

    {:error, {:auto_reply_state_update_failed, List.first(ids), reason}}
  end

  defp replied_comment_ids(record) when is_map(record) do
    record
    |> Map.get(:replied_comment_ids, [])
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_request_review(_record, [], _settings, _github, _opts, _now), do: :ok

  defp maybe_request_review(record, comments, settings, github, opts, now) do
    if Map.get(settings.pr_review, :auto_request_review, false) do
      comments
      |> reviewers_for_request(settings)
      |> request_review(record, github)
      |> handle_request_review_result(record, opts, now)
    else
      :ok
    end
  end

  defp handle_request_review_result(:ok, _record, _opts, _now), do: :ok

  defp handle_request_review_result({:error, reason}, record, opts, now) do
    issue_id = Map.get(record, :issue_id)

    Logger.warning("Failed to request follow-up PR review issue_id=#{issue_id}: #{inspect(reason)}")

    attrs = %{
      auto_request_review_error: inspect(reason),
      auto_request_review_error_at: now,
      updated_at: now
    }

    case update_review(opts, record, attrs) do
      :ok ->
        :ok

      {:error, update_reason} ->
        Logger.warning("Failed to record follow-up PR review request error issue_id=#{issue_id}: #{inspect(update_reason)}")
        :ok
    end
  end

  defp reviewers_for_request(comments, settings) do
    ignored = settings |> configured_ignored_users() |> Enum.map(&normalize_user/1) |> Enum.reject(&is_nil/1)

    comments
    |> Enum.map(&Map.get(&1, :author))
    |> Enum.reject(&(normalize_user(&1) in ignored))
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp request_review([], _record, _github), do: :ok

  defp request_review(reviewers, record, github) do
    case github.request_review(Map.get(record, :pr_url), reviewers, cwd: Map.get(record, :workspace_path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:auto_request_review_failed, reason}}
    end
  end

  defp addressed_comment_reply do
    "Thanks for the review. I addressed this in the latest rework run."
  end

  defp addressed_comment_summary_reply(comments) do
    references =
      Enum.map_join(comments, "\n", &summary_comment_reference/1)

    "Thanks for the review. I addressed these PR-level comments in the latest rework run:\n#{references}"
  end

  defp summary_comment_reference(comment) do
    id = Map.get(comment, :id) || "unknown-comment"
    author = Map.get(comment, :author)

    if is_binary(author) and String.trim(author) != "" do
      "- #{id} from #{String.trim(author)}"
    else
      "- #{id}"
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

  defp cleanup_error_attrs(record, reason, opts, now) do
    consecutive_errors = consecutive_errors(record) + 1

    %{
      status: "cleanup_error",
      error: inspect(reason),
      consecutive_errors: consecutive_errors,
      next_poll_at: DateTime.add(now, cleanup_error_backoff_ms(consecutive_errors, opts), :millisecond),
      updated_at: now
    }
  end

  defp consecutive_errors(record) do
    case Map.get(record, :consecutive_errors) do
      value when is_integer(value) and value >= 0 -> value
      _value -> 0
    end
  end

  defp maybe_emit_poll_run_failed(record, %{consecutive_errors: consecutive_errors}, reason)
       when consecutive_errors >= @github_error_backoff_threshold do
    if consecutive_errors(record) < @github_error_backoff_threshold do
      Notifications.emit_event(:run_failed, %{
        issue_id: Map.get(record, :issue_id),
        issue_identifier: Map.get(record, :issue_identifier),
        issue_url: Map.get(record, :issue_url),
        pr_url: Map.get(record, :pr_url),
        state: @in_review_state,
        reason: "PR review polling failed #{consecutive_errors} consecutive times: #{inspect(reason)}",
        metadata: %{
          source: "pr_review_poller",
          consecutive_errors: consecutive_errors
        }
      })
    end
  end

  defp maybe_emit_poll_run_failed(_record, _attrs, _reason), do: :ok

  defp maybe_emit_reviewer_commented(record, attrs, "rework", now) do
    comments = attrs |> Map.get(:pending_reviewer_comments, []) |> normalize_comments()

    if comments != [] do
      Notifications.emit_event(
        :reviewer_commented,
        reviewer_feedback_event_attrs(record, %{
          state: @active_state,
          reason: actionable_comment_reason(comments, "discovered"),
          timestamp: now,
          metadata: reviewer_feedback_metadata(comments)
        })
      )
    end
  end

  defp maybe_emit_reviewer_commented(_record, _attrs, _action, _now), do: :ok

  defp emit_rework_pushed(_record, [], _cursor, _now), do: :ok

  defp emit_rework_pushed(record, comments, cursor, now) do
    Notifications.emit_event(
      :rework_pushed,
      reviewer_feedback_event_attrs(record, %{
        state: @active_state,
        reason: actionable_comment_reason(comments, "addressed"),
        timestamp: now,
        metadata: reviewer_feedback_metadata(comments, cursor)
      })
    )
  end

  defp reviewer_feedback_event_attrs(record, attrs) do
    %{
      issue_id: Map.get(record, :issue_id),
      issue_identifier: Map.get(record, :issue_identifier),
      issue_title: Map.get(record, :issue_title),
      issue_url: Map.get(record, :issue_url),
      pr_url: Map.get(record, :pr_url)
    }
    |> Map.merge(attrs)
  end

  defp actionable_comment_reason([_comment], verb), do: "1 actionable reviewer comment #{verb}"
  defp actionable_comment_reason(comments, verb), do: "#{length(comments)} actionable reviewer comments #{verb}"

  defp reviewer_feedback_metadata(comments, latest_comment_id \\ nil) do
    comments = normalize_comments(comments)
    latest_comment_id = latest_comment_id || latest_comment_id(comments)

    %{
      source: "pr_review_poller",
      comment_count: length(comments),
      latest_comment_id: latest_comment_id
    }
  end

  defp github_error_backoff_ms(consecutive_errors, opts) do
    exponent = max(consecutive_errors - @github_error_backoff_threshold, 0)

    poll_interval_ms(opts)
    |> Kernel.*(Integer.pow(2, exponent))
    |> min(@max_github_error_backoff_ms)
  end

  defp cleanup_error_backoff_ms(consecutive_errors, opts) do
    exponent = max(consecutive_errors - 1, 0)

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
