defmodule SymphonyElixir.CiPoller do
  @moduledoc """
  Polling-mode GitHub Actions CI poller.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Notifications, RunStore, Tracker}
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Linear.Issue

  @in_review_state "In Review"
  @active_state "In Progress"
  @closed_pr_states ["CLOSED", "MERGED"]
  @github_error_backoff_threshold 3
  @max_github_error_backoff_ms 300_000

  defmodule State do
    @moduledoc false
    defstruct [:timer_ref, :poll_interval_ms, opts: []]
  end

  @type poll_summary :: %{
          mode: :polling | :tracker | :disabled,
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
          Logger.debug("CI poll completed: #{inspect(summary)}")
          log_poll_action_warnings(summary)

        {:error, reason} ->
          Logger.warning("CI poll failed: #{inspect(reason)}")
      end
    rescue
      exception ->
        Logger.error("CI poll raised: #{Exception.format(:error, exception, __STACKTRACE__)}")
    catch
      kind, reason ->
        Logger.error("CI poll failed with #{kind}: #{Exception.format(kind, reason, __STACKTRACE__)}")
    end

    {:noreply, schedule_poll(state, state.poll_interval_ms)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec poll_once(keyword()) :: {:ok, poll_summary()} | {:error, term()}
  def poll_once(opts \\ []) when is_list(opts) do
    with {:ok, settings} <- poll_settings(opts) do
      cond do
        not settings.ci.enabled ->
          {:ok, %{mode: :disabled, discovered: 0, processed: 0, actions: []}}

        settings.pr_review.mode != "polling" ->
          {:ok, %{mode: :tracker, discovered: 0, processed: 0, actions: []}}

        true ->
          do_poll_once(settings, opts)
      end
    end
  end

  @doc false
  @spec pending_ci_failure(String.t(), keyword()) :: map() | nil
  def pending_ci_failure(issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = repo_key_from_opts(opts)

    with {:ok, checks} <- list_ci_checks(run_store, repo_key),
         %{} = record <- Enum.find(checks, &(Map.get(&1, :issue_id) == issue_id)) do
      normalize_ci_failure(Map.get(record, :ci_failure))
    else
      _ -> nil
    end
  end

  @doc false
  @spec ci_owned_issue?(String.t(), keyword()) :: boolean()
  def ci_owned_issue?(issue_id, opts \\ []) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = repo_key_from_opts(opts)

    with {:ok, checks} <- list_ci_checks(run_store, repo_key),
         %{} = record <- Enum.find(checks, &(Map.get(&1, :issue_id) == issue_id)) do
      ci_owned_record?(record)
    else
      _ -> false
    end
  end

  @doc false
  @spec log_excerpt_for_test(String.t(), pos_integer()) :: String.t()
  def log_excerpt_for_test(log, line_limit), do: log_excerpt(log, line_limit)

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

    with {:ok, discovered} <- discover_ci_checks(run_store, tracker, repo_key, now),
         {:ok, checks} <- list_ci_checks(run_store, repo_key) do
      actions = Enum.map(checks, &process_ci_check(&1, settings, opts, now))

      {:ok, %{mode: :polling, discovered: discovered, processed: length(checks), actions: actions}}
    end
  end

  defp discover_ci_checks(run_store, tracker, repo_key, now) do
    with {:ok, issues} <- tracker.fetch_issues_by_states([@in_review_state]),
         {:ok, runs} <- list_runs(run_store, repo_key),
         {:ok, existing} <- list_ci_checks(run_store, repo_key) do
      existing_by_issue = Map.new(existing, &{Map.get(&1, :issue_id), &1})

      discovered =
        issues
        |> Enum.filter(&match?(%Issue{}, &1))
        |> Enum.count(&persist_discovered_ci_check?(&1, runs, existing_by_issue, run_store, repo_key, now))

      {:ok, discovered}
    end
  end

  defp persist_discovered_ci_check?(%Issue{} = issue, runs, existing_by_issue, run_store, repo_key, now) do
    existing = Map.get(existing_by_issue, issue.id)

    case discover_ci_check_record(issue, runs, existing, now) do
      nil ->
        false

      record ->
        case put_ci_check(run_store, Map.put(record, :repo_key, repo_key)) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning("Failed to persist discovered CI check record issue_id=#{issue.id}: #{inspect(reason)}")
            false
        end
    end
  end

  defp discover_ci_check_record(%Issue{} = issue, runs, existing, now) when is_list(runs) do
    with pr_url when is_binary(pr_url) <- first_pr_url(issue),
         %{workspace_path: workspace_path} = run when is_binary(workspace_path) <-
           latest_run_for_issue(runs, issue.id) do
      base = %{
        repo_key: Map.get(existing || %{}, :repo_key),
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        issue_url: issue.url,
        pr_url: pr_url,
        workspace_path: workspace_path,
        worker_host: Map.get(run, :worker_host),
        status: Map.get(existing || %{}, :status, "watching"),
        ci_retry_count: ci_retry_count(existing || %{}),
        rerun_attempted_shas: string_list(Map.get(existing || %{}, :rerun_attempted_shas, [])),
        dispatched_shas: string_list(Map.get(existing || %{}, :dispatched_shas, [])),
        inserted_at: Map.get(existing || %{}, :inserted_at, now),
        updated_at: now
      }

      Map.merge(existing || %{}, base)
    else
      nil ->
        nil

      other ->
        Logger.debug("discover_ci_check_record skipped issue_id=#{issue.id}: #{inspect(other)}")
        nil
    end
  end

  defp discover_ci_check_record(_issue, _runs, _existing, _now), do: nil

  defp process_ci_check(record, settings, opts, now) when is_map(record) do
    case backoff_active_until(record, now) do
      {:backing_off, next_poll_at} ->
        {:backing_off, Map.get(record, :issue_id), next_poll_at}

      :ready ->
        fetch_and_process_ci(record, settings, opts, now)
    end
  end

  defp fetch_and_process_ci(record, settings, opts, now) do
    github = Keyword.get(opts, :github, PullRequest)

    case github.fetch_ci_status(Map.get(record, :pr_url), cwd: Map.get(record, :workspace_path)) do
      {:ok, ci_status} ->
        handle_ci_status(record, ci_status, settings, opts, now)

      {:error, reason} ->
        record_poll_error(record, reason, opts, now)
    end
  end

  defp handle_ci_status(record, ci_status, settings, opts, now) do
    case ci_action(ci_status) do
      :closed ->
        cleanup_ci(record, opts, now, "closed")

      :success ->
        mark_ci_green(record, ci_status, opts, now)

      :pending ->
        complete_ci_update(opts, record, ci_status_attrs(record, ci_status, %{status: "watching"}, now), {:watching, Map.get(record, :issue_id)})

      {:failure, failed_checks} ->
        handle_ci_failure(record, ci_status, failed_checks, settings, opts, now)
    end
  end

  defp handle_ci_failure(record, ci_status, failed_checks, settings, opts, now) do
    commit_sha = Map.get(ci_status, :commit_sha)
    record = reset_for_new_sha(record, commit_sha, opts, now)

    cond do
      flaky_retry?(settings) and not rerun_attempted_for_sha?(record, commit_sha) ->
        rerun_failed_ci(record, ci_status, failed_checks, settings, opts, now)

      dispatched_for_sha?(record, commit_sha) ->
        attrs =
          ci_status_attrs(record, ci_status, %{status: "failure_already_handled", failed_checks: failed_checks}, now)

        complete_ci_update(opts, record, attrs, {:already_handled, Map.get(record, :issue_id), commit_sha})

      ci_retry_count(record) >= settings.ci.max_retries and Map.get(record, :status) != "escalated" ->
        escalate_ci_failure(record, ci_status, failed_checks, settings, opts, now)

      Map.get(record, :status) == "escalated" ->
        attrs =
          ci_status_attrs(record, ci_status, %{status: "escalated", failed_checks: failed_checks}, now)

        complete_ci_update(opts, record, attrs, {:already_handled, Map.get(record, :issue_id), commit_sha})

      true ->
        dispatch_ci_failure(record, ci_status, failed_checks, settings, opts, now)
    end
  end

  # On a new head SHA, the previous SHA's dispatch/rerun history no longer applies:
  # clear it so the new commit gets a fresh dispatch + rerun budget. Lifetime
  # `ci_retry_count` is intentionally preserved so escalation still triggers
  # after enough failed attempts across SHAs (it resets on green).
  defp reset_for_new_sha(record, commit_sha, opts, now) do
    if new_commit_sha?(record, commit_sha) do
      reset_attrs = %{
        dispatched_shas: [],
        rerun_attempted_shas: [],
        status: downgrade_status_for_new_sha(Map.get(record, :status)),
        updated_at: now
      }

      run_store = Keyword.get(opts, :run_store, RunStore)

      case update_ci_check(run_store, record, reset_attrs) do
        :ok -> Map.merge(record, reset_attrs)
        _other -> record
      end
    else
      record
    end
  end

  defp new_commit_sha?(record, commit_sha) do
    last_observed = Map.get(record, :last_observed_sha)

    is_binary(commit_sha) and commit_sha != "" and
      is_binary(last_observed) and last_observed != "" and
      last_observed != commit_sha
  end

  defp downgrade_status_for_new_sha("escalated"), do: "watching"
  defp downgrade_status_for_new_sha(status), do: status

  defp rerun_failed_ci(record, ci_status, failed_checks, settings, opts, now) do
    github = Keyword.get(opts, :github, PullRequest)
    run_ids = failed_run_ids(failed_checks)

    case run_ids do
      [_ | _] ->
        case rerun_failed_run_ids(github, run_ids, Map.get(record, :workspace_path)) do
          :ok ->
            attrs =
              ci_status_attrs(
                record,
                ci_status,
                %{
                  status: "rerun_requested",
                  failed_checks: failed_checks,
                  rerun_attempted_shas: append_string(Map.get(record, :rerun_attempted_shas, []), Map.get(ci_status, :commit_sha)),
                  rerun_requested_at: now,
                  rerun_run_id: List.first(run_ids),
                  rerun_run_ids: run_ids
                },
                now
              )

            complete_ci_update(opts, record, attrs, {:rerun_requested, Map.get(record, :issue_id), rerun_action_run_ids(run_ids)})

          {:error, {run_id, reason}} ->
            record_poll_error(record, {:rerun_failed, run_id, reason}, opts, now)
        end

      [] ->
        dispatch_ci_failure(record, ci_status, failed_checks, settings, Keyword.put(opts, :missing_run_id, true), now)
    end
  end

  defp rerun_failed_run_ids(github, run_ids, workspace_path) when is_list(run_ids) do
    Enum.reduce_while(run_ids, :ok, fn run_id, :ok ->
      case github.rerun_failed(run_id, cwd: workspace_path) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {run_id, reason}}}
      end
    end)
  end

  defp rerun_action_run_ids([run_id]), do: run_id
  defp rerun_action_run_ids(run_ids), do: run_ids

  defp dispatch_ci_failure(record, ci_status, failed_checks, settings, opts, now) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)

    case failed_log_excerpt(record, failed_checks, settings, opts) do
      {:ok, log_excerpt} ->
        persist_and_dispatch_ci_failure(record, ci_status, failed_checks, opts, now, tracker, issue_id, log_excerpt)

      {:error, reason} ->
        record_poll_error(record, reason, opts, now)
    end
  end

  defp persist_and_dispatch_ci_failure(record, ci_status, failed_checks, opts, now, tracker, issue_id, log_excerpt) do
    retry_count = ci_retry_count(record) + 1
    ci_failure = ci_failure_context(ci_status, failed_checks, log_excerpt)

    attrs =
      ci_status_attrs(
        record,
        ci_status,
        %{
          status: "dispatch_requested",
          target_issue_state: @active_state,
          ci_retry_count: retry_count,
          failed_checks: failed_checks,
          log_excerpt: log_excerpt,
          ci_failure: ci_failure,
          dispatched_shas: append_string(Map.get(record, :dispatched_shas, []), Map.get(ci_status, :commit_sha)),
          last_action: "dispatch",
          last_action_at: now
        },
        now
      )

    case complete_ci_update(opts, record, attrs, :ok) do
      :ok ->
        case tracker.update_issue_state(issue_id, @active_state) do
          :ok ->
            emit_ci_failed(record, ci_status, failed_checks, retry_count, @active_state)
            {:state_transitioned, issue_id, :ci_failure, @active_state}

          {:error, reason} ->
            record_transition_error(record, ci_status, failed_checks, opts, now, "dispatch", reason)
        end

      {:update_error, _issue_id, _reason} = error ->
        error
    end
  end

  defp escalate_ci_failure(record, ci_status, failed_checks, settings, opts, now) do
    tracker = Keyword.get(opts, :tracker, Tracker)
    issue_id = Map.get(record, :issue_id)
    escalation_state = settings.ci.escalation_state || @in_review_state

    context = %{
      escalation_state: escalation_state,
      issue_id: issue_id,
      now: now,
      opts: opts,
      settings: settings,
      tracker: tracker
    }

    case failed_log_excerpt(record, failed_checks, settings, opts) do
      {:ok, log_excerpt} ->
        do_escalate_ci_failure(record, ci_status, failed_checks, context, log_excerpt)

      {:error, reason} ->
        record_poll_error(record, reason, opts, now)
    end
  end

  defp do_escalate_ci_failure(record, ci_status, failed_checks, context, log_excerpt) do
    %{
      escalation_state: escalation_state,
      issue_id: issue_id,
      now: now,
      opts: opts,
      settings: settings,
      tracker: tracker
    } = context

    case tracker.update_issue_state(issue_id, escalation_state) do
      :ok ->
        ci_failure = ci_failure_context(ci_status, failed_checks, log_excerpt)

        attrs =
          ci_status_attrs(
            record,
            ci_status,
            %{
              status: "escalated",
              target_issue_state: escalation_state,
              failed_checks: failed_checks,
              log_excerpt: log_excerpt,
              ci_failure: ci_failure,
              last_action: "escalate",
              last_action_at: now
            },
            now
          )

        case complete_ci_update(opts, record, attrs, {:escalated, issue_id, escalation_state}) do
          {:escalated, ^issue_id, ^escalation_state} = action ->
            emit_ci_escalated(record, ci_status, failed_checks, settings, escalation_state)
            action

          {:update_error, _issue_id, _reason} = error ->
            error
        end

      {:error, reason} ->
        record_transition_error(record, ci_status, failed_checks, opts, now, "escalate", reason)
    end
  end

  defp mark_ci_green(record, ci_status, opts, now) do
    issue_id = Map.get(record, :issue_id)

    attrs =
      ci_status_attrs(
        record,
        ci_status,
        %{
          status: "green",
          ci_retry_count: 0,
          failed_checks: [],
          log_excerpt: nil,
          ci_failure: nil,
          rerun_attempted_shas: [],
          dispatched_shas: [],
          last_action: "green",
          last_action_at: now
        },
        now
      )

    complete_ci_update(opts, record, attrs, {:green, issue_id})
  end

  defp cleanup_ci(record, opts, now, reason) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = Map.get(record, :repo_key) || repo_key_from_opts(opts)
    issue_id = Map.get(record, :issue_id)

    case delete_ci_check(run_store, repo_key, issue_id) do
      :ok ->
        {:cleanup, issue_id, reason}

      {:error, delete_reason} ->
        attrs = %{status: "cleanup_error", error: inspect(delete_reason), updated_at: now}
        complete_ci_update(opts, record, attrs, {:cleanup_error, issue_id, delete_reason})
    end
  end

  defp failed_log_excerpt(record, failed_checks, settings, opts) do
    github = Keyword.get(opts, :github, PullRequest)
    run_ids = failed_run_ids(failed_checks)

    cond do
      run_ids != [] ->
        failed_log_excerpts(github, run_ids, Map.get(record, :workspace_path), settings.ci.log_excerpt_lines)

      Keyword.get(opts, :missing_run_id) ->
        {:ok, "No GitHub Actions run id was available for the failed check."}

      true ->
        {:ok, "No GitHub Actions run id was available for the failed check."}
    end
  end

  defp failed_log_excerpts(github, [run_id], workspace_path, line_limit) do
    case github.fetch_failed_log(run_id, cwd: workspace_path) do
      {:ok, log} -> {:ok, log_excerpt(log, line_limit)}
      {:error, reason} -> {:error, {:failed_log_unavailable, run_id, reason}}
    end
  end

  defp failed_log_excerpts(github, run_ids, workspace_path, line_limit) when is_list(run_ids) do
    Enum.reduce_while(run_ids, {:ok, []}, fn run_id, {:ok, excerpts} ->
      case github.fetch_failed_log(run_id, cwd: workspace_path) do
        {:ok, log} ->
          excerpt = "Run #{run_id} failed log:\n#{log_excerpt(log, line_limit)}"
          {:cont, {:ok, [excerpt | excerpts]}}

        {:error, reason} ->
          {:halt, {:error, {:failed_log_unavailable, run_id, reason}}}
      end
    end)
    |> case do
      {:ok, excerpts} -> {:ok, excerpts |> Enum.reverse() |> Enum.join("\n\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ci_status_attrs(record, ci_status, attrs, now) do
    Map.merge(
      %{
        status: Map.get(attrs, :status, Map.get(record, :status, "watching")),
        error: nil,
        consecutive_errors: 0,
        next_poll_at: nil,
        pr_url: Map.get(ci_status, :pr_url) || Map.get(record, :pr_url),
        pr_title: Map.get(ci_status, :pr_title),
        pr_state: Map.get(ci_status, :state),
        commit_sha: Map.get(ci_status, :commit_sha),
        last_observed_sha: Map.get(ci_status, :commit_sha),
        last_observed_conclusion: conclusion_for_status(ci_status),
        updated_at: now
      },
      attrs
    )
  end

  defp record_poll_error(record, reason, opts, now) do
    attrs = poll_error_attrs(record, reason, opts, now)

    case update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs) do
      :ok ->
        {:poll_error, Map.get(record, :issue_id), reason}

      {:error, update_reason} ->
        {:poll_error_update_failed, Map.get(record, :issue_id), reason, update_reason}
    end
  end

  defp record_transition_error(record, ci_status, failed_checks, opts, now, action, reason) do
    attrs =
      ci_status_attrs(
        record,
        ci_status,
        %{
          status: "state_transition_error",
          failed_checks: failed_checks,
          last_action: action,
          last_action_at: nil
        },
        now
      )
      |> Map.merge(error_backoff_attrs(record, reason, opts, now))

    case update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs) do
      :ok ->
        {:state_transition_error, Map.get(record, :issue_id), String.to_atom(action), reason}

      {:error, update_reason} ->
        {:state_transition_error_update_failed, Map.get(record, :issue_id), String.to_atom(action), reason, update_reason}
    end
  end

  defp complete_ci_update(opts, record, attrs, success_action) do
    case update_ci_check(Keyword.get(opts, :run_store, RunStore), record, attrs) do
      :ok -> success_action
      {:error, reason} -> {:update_error, Map.get(record, :issue_id), reason}
    end
  end

  defp update_ci_check(run_store, record, attrs) do
    issue_id = Map.get(record, :issue_id)

    case Map.get(record, :repo_key) do
      repo_key when is_binary(repo_key) ->
        case update_ci_check_record(run_store, repo_key, issue_id, attrs) do
          :ok ->
            :ok

          {:error, :ci_check_not_found} ->
            put_ci_check(run_store, record |> Map.merge(attrs) |> Map.put(:repo_key, repo_key))

          {:error, reason} ->
            Logger.warning("Failed to update CI check record issue_id=#{issue_id} target_status=#{inspect(Map.get(attrs, :status))}: #{inspect(reason)}")
            {:error, {:update_ci_check_failed, reason}}
        end

      _repo_key ->
        {:error, :missing_repo_key}
    end
  end

  defp put_ci_check(run_store, record) do
    case run_store.put_ci_check(record) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delete_ci_check(run_store, repo_key, issue_id) do
    case delete_ci_check_record(run_store, repo_key, issue_id) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp repo_key_from_opts(opts), do: Keyword.get_lazy(opts, :repo_key, &Config.repo_key!/0)

  defp update_ci_check_record(run_store, repo_key, issue_id, attrs) do
    cond do
      function_exported?(run_store, :update_ci_check, 3) ->
        run_store.update_ci_check(repo_key, issue_id, attrs)

      function_exported?(run_store, :update_ci_check, 2) ->
        run_store.update_ci_check(issue_id, attrs)

      true ->
        {:error, :ci_checks_unsupported}
    end
  end

  defp delete_ci_check_record(run_store, repo_key, issue_id) do
    cond do
      function_exported?(run_store, :delete_ci_check, 2) ->
        run_store.delete_ci_check(repo_key, issue_id)

      function_exported?(run_store, :delete_ci_check, 1) ->
        run_store.delete_ci_check(issue_id)

      true ->
        {:error, :ci_checks_unsupported}
    end
  end

  defp ci_action(ci_status) do
    cond do
      closed_pr_state?(Map.get(ci_status, :state)) ->
        :closed

      failed_checks(ci_status) != [] ->
        {:failure, failed_checks(ci_status)}

      pending_checks?(ci_status) ->
        :pending

      success_checks?(ci_status) ->
        :success

      true ->
        :pending
    end
  end

  defp failed_checks(ci_status) do
    ci_status
    |> Map.get(:checks, [])
    |> Enum.filter(&failure_check?/1)
  end

  defp failure_check?(check) do
    check
    |> Map.get(:conclusion)
    |> normalize_status()
    |> then(&(&1 in ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED"]))
  end

  defp pending_checks?(%{checks: []}), do: true

  defp pending_checks?(ci_status) do
    ci_status
    |> Map.get(:checks, [])
    |> Enum.any?(fn check ->
      status = normalize_status(Map.get(check, :status))
      conclusion = normalize_status(Map.get(check, :conclusion))

      status not in ["COMPLETED", "SUCCESS", "FAILURE", "ERROR"] or conclusion in [nil, ""]
    end)
  end

  defp success_checks?(ci_status) do
    checks = Map.get(ci_status, :checks, [])

    checks != [] and
      Enum.all?(checks, fn check ->
        normalize_status(Map.get(check, :conclusion)) in ["SUCCESS", "NEUTRAL", "SKIPPED"]
      end)
  end

  defp conclusion_for_status(ci_status) do
    case ci_action(ci_status) do
      :success -> "SUCCESS"
      :pending -> "IN_PROGRESS"
      :closed -> "CLOSED"
      {:failure, _checks} -> "FAILURE"
    end
  end

  defp log_excerpt(log, line_limit) when is_binary(log) and is_integer(line_limit) and line_limit > 0 do
    log
    |> sanitize_utf8()
    |> String.split("\n")
    |> Enum.take(-line_limit)
    |> prefer_error_start()
    |> Enum.join("\n")
  end

  defp log_excerpt(_log, _line_limit), do: ""

  defp sanitize_utf8(binary) when is_binary(binary) do
    if String.valid?(binary), do: binary, else: replace_invalid_bytes(binary, <<>>)
  end

  defp replace_invalid_bytes(<<>>, acc), do: acc

  defp replace_invalid_bytes(<<char::utf8, rest::binary>>, acc) do
    replace_invalid_bytes(rest, <<acc::binary, char::utf8>>)
  end

  defp replace_invalid_bytes(<<_byte, rest::binary>>, acc) do
    replace_invalid_bytes(rest, <<acc::binary, ??::utf8>>)
  end

  defp prefer_error_start(lines) do
    case Enum.find_index(lines, &error_line?/1) do
      nil -> lines
      index -> Enum.drop(lines, index)
    end
  end

  defp error_line?(line) when is_binary(line) do
    String.match?(line, ~r/(error|failed|failure|exception|stacktrace|traceback|panic)/i)
  end

  defp failed_run_ids(failed_checks) do
    failed_checks
    |> Enum.map(fn check ->
      case Map.get(check, :run_id) do
        run_id when is_binary(run_id) and run_id != "" -> run_id
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp ci_failure_context(ci_status, failed_checks, log_excerpt) do
    %{
      commit_sha: Map.get(ci_status, :commit_sha),
      failed_checks: failed_checks,
      log_excerpt: log_excerpt
    }
  end

  defp normalize_ci_failure(%{commit_sha: commit_sha, failed_checks: failed_checks, log_excerpt: log_excerpt}) do
    %{
      commit_sha: commit_sha,
      failed_checks: failed_checks,
      log_excerpt: log_excerpt
    }
  end

  defp normalize_ci_failure(_ci_failure), do: nil

  defp emit_ci_failed(record, ci_status, failed_checks, retry_count, target_state) do
    Notifications.emit_event(
      :ci_failed,
      notification_attrs(record, ci_status, failed_checks, target_state, "CI failed; dispatching agent", %{
        retry_count: retry_count
      })
    )
  end

  defp emit_ci_escalated(record, ci_status, failed_checks, settings, target_state) do
    Notifications.emit_event(
      :ci_escalated,
      notification_attrs(record, ci_status, failed_checks, target_state, "CI failed after #{settings.ci.max_retries} agent dispatches; escalation required", %{
        retry_count: ci_retry_count(record),
        max_retries: settings.ci.max_retries,
        escalation_state: target_state
      })
    )
  end

  defp notification_attrs(record, ci_status, failed_checks, target_state, reason, metadata) do
    %{
      issue_id: Map.get(record, :issue_id),
      issue_identifier: Map.get(record, :issue_identifier),
      issue_url: Map.get(record, :issue_url),
      pr_url: Map.get(ci_status, :pr_url) || Map.get(record, :pr_url),
      pr_title: Map.get(ci_status, :pr_title),
      state: target_state,
      reason: reason,
      metadata:
        Map.merge(metadata, %{
          source: "ci_poller",
          commit_sha: Map.get(ci_status, :commit_sha),
          failed_checks: Enum.map(failed_checks, &Map.take(&1, [:name, :run_id, :conclusion]))
        })
    }
  end

  defp flaky_retry?(settings), do: Map.get(settings.ci, :flaky_retry, true)

  defp rerun_attempted_for_sha?(record, sha), do: sha in string_list(Map.get(record, :rerun_attempted_shas, []))
  defp dispatched_for_sha?(record, sha), do: sha in string_list(Map.get(record, :dispatched_shas, []))

  defp ci_owned_record?(record) do
    ci_retry_count(record) > 0 or Map.get(record, :status) in ["dispatch_requested", "escalated", "state_transition_error"]
  end

  defp ci_retry_count(record) when is_map(record) do
    case Map.get(record, :ci_retry_count) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp first_pr_url(%Issue{pr_urls: [url | _rest]}) when is_binary(url), do: url
  defp first_pr_url(_issue), do: nil

  defp latest_run_for_issue(runs, issue_id) when is_list(runs) and is_binary(issue_id) do
    runs
    |> Enum.filter(&ci_run_for_issue?(&1, issue_id))
    |> Enum.max_by(&run_started_at_sort_key/1, fn -> nil end)
  end

  defp ci_run_for_issue?(run, issue_id) do
    Map.get(run, :issue_id) == issue_id and
      Map.get(run, :status) in ["success", "stopped"] and
      is_binary(Map.get(run, :workspace_path))
  end

  defp run_started_at_sort_key(run) do
    case Map.get(run, :started_at) do
      %DateTime{} = started_at -> DateTime.to_unix(started_at, :microsecond)
      _ -> 0
    end
  end

  defp list_runs(run_store, repo_key) do
    case list_run_records(run_store, repo_key) do
      runs when is_list(runs) -> {:ok, runs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_ci_checks(run_store, repo_key) do
    cond do
      function_exported?(run_store, :list_ci_checks, 1) ->
        case run_store.list_ci_checks(repo_key) do
          checks when is_list(checks) -> {:ok, checks}
          {:error, reason} -> {:error, reason}
        end

      function_exported?(run_store, :list_ci_checks, 0) ->
        case run_store.list_ci_checks() do
          checks when is_list(checks) -> {:ok, checks}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :ci_checks_unsupported}
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

  defp append_string(values, value) when is_binary(value) and value != "" do
    values
    |> string_list()
    |> Kernel.++([value])
    |> Enum.uniq()
  end

  defp append_string(values, _value), do: string_list(values)

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_values), do: []

  defp closed_pr_state?(state) do
    state
    |> normalize_status()
    |> then(&(&1 in @closed_pr_states))
  end

  defp normalize_status(value) when is_binary(value) do
    value |> String.trim() |> String.upcase()
  end

  defp normalize_status(_value), do: nil

  defp poll_error_attrs(record, reason, opts, now) do
    error_backoff_attrs(record, reason, opts, now)
  end

  defp error_backoff_attrs(record, reason, opts, now) do
    consecutive_errors = consecutive_errors(record) + 1

    attrs = %{
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
      _ -> 0
    end
  end

  defp backoff_active_until(record, now) do
    case Map.get(record, :next_poll_at) do
      %DateTime{} = next_poll_at ->
        if DateTime.compare(next_poll_at, now) == :gt do
          {:backing_off, next_poll_at}
        else
          :ready
        end

      _ ->
        :ready
    end
  end

  defp github_error_backoff_ms(consecutive_errors, opts) do
    exponent = max(consecutive_errors - @github_error_backoff_threshold, 0)

    poll_interval_ms(opts)
    |> Kernel.*(Integer.pow(2, exponent))
    |> min(@max_github_error_backoff_ms)
  end

  defp log_poll_action_warnings(%{actions: actions}) when is_list(actions) do
    Enum.each(actions, &log_poll_action_warning/1)
  end

  defp log_poll_action_warning({:poll_error, issue_id, reason}) do
    Logger.warning("CI poll error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:state_transition_error, issue_id, action, reason}) do
    Logger.warning("CI transition error issue_id=#{issue_id} action=#{action}: #{inspect(reason)}")
  end

  defp log_poll_action_warning({:cleanup_error, issue_id, reason}) do
    Logger.warning("CI cleanup error issue_id=#{issue_id}: #{inspect(reason)}")
  end

  defp log_poll_action_warning(_action), do: :ok

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
        settings = Keyword.get(opts, :settings) || Config.settings!()
        settings.ci.poll_interval_ms || settings.pr_review.poll_interval_ms || settings.polling.interval_ms
    end
  end
end
