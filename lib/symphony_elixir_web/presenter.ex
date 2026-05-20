defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{AuditLog, Config, Orchestrator, StatusDashboard, URLUtils}

  @empty_codex_totals %{
    input_tokens: 0,
    cached_input_tokens: 0,
    uncached_input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        run_history = Map.get(snapshot, :run_history, [])
        self_review_by_run = self_review_lookup(snapshot.running, run_history)

        %{
          generated_at: generated_at,
          repos: repo_keys(snapshot),
          counts: %{
            running: length(snapshot.running),
            watching: length(Map.get(snapshot, :watching, [])),
            conflicts: length(Map.get(snapshot, :conflicts, [])),
            retrying: length(snapshot.retrying)
          },
          running: Enum.map(snapshot.running, &running_entry_payload(&1, self_review_by_run)),
          watching: snapshot |> Map.get(:watching, []) |> Enum.map(&watching_entry_payload/1),
          conflicts: snapshot |> Map.get(:conflicts, []) |> Enum.map(&conflict_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          awaiting_clarification:
            snapshot
            |> Map.get(:awaiting_clarification, [])
            |> Enum.map(&awaiting_clarification_entry_payload/1),
          skipped:
            snapshot
            |> Map.get(:skipped, [])
            |> Enum.map(&skipped_entry_payload/1),
          run_history: Enum.map(run_history, &run_history_payload(&1, self_review_by_run)),
          codex_totals: normalize_codex_totals(Map.get(snapshot, :codex_totals)),
          pause: normalize_pause(Map.get(snapshot, :pause)),
          budget: normalize_budget(Map.get(snapshot, :budget)),
          dispatch_state: normalize_dispatch_state(snapshot),
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        watching = snapshot |> Map.get(:watching, []) |> Enum.find(&(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(watching) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, watching)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec transcript_payload(String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found | :snapshot_unavailable}
  def transcript_payload(issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    transcript_payload(current_repo_key(), issue_identifier, orchestrator, snapshot_timeout_ms)
  end

  @spec transcript_payload(String.t() | nil, String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found | :snapshot_unavailable}
  def transcript_payload(repo_key, issue_identifier, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(repo_key_matches?(&1, repo_key) and &1.identifier == issue_identifier))
        watching = snapshot |> Map.get(:watching, []) |> Enum.find(&(repo_key_matches?(&1, repo_key) and &1.identifier == issue_identifier))

        case {running, watching} do
          {nil, nil} ->
            {:error, :issue_not_found}

          {%{} = running, _watching} ->
            {:ok, running_transcript_payload(running, repo_key)}

          {nil, %{} = watching} ->
            {:ok, watching_transcript_payload(watching, repo_key)}
        end

      _ ->
        {:error, :snapshot_unavailable}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, retry, watching) do
    payload = %{
      repo_key: repo_key_from_entries(running, retry, watching),
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, watching),
      status: issue_status(running, retry, watching),
      workspace: workspace_payload(issue_identifier, running, retry),
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: []
      },
      recent_events: (running && recent_events_payload(running)) || [],
      last_error: retry && retry.error,
      tracked: %{}
    }

    if watching do
      Map.put(payload, :watching, watching_issue_payload(watching))
    else
      payload
    end
  end

  defp issue_id_from_entries(running, retry, watching),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (watching && watching.issue_id)

  defp repo_key_from_entries(running, retry, watching),
    do: (running && Map.get(running, :repo_key)) || (retry && Map.get(retry, :repo_key)) || (watching && Map.get(watching, :repo_key))

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, retry, _watching) do
    cond do
      running -> "running"
      retry -> "retrying"
      true -> "watching"
    end
  end

  defp running_entry_payload(entry, self_review_by_run) do
    %{
      repo_key: Map.get(entry, :repo_key),
      run_kind: Map.get(entry, :run_kind),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      url: URLUtils.present_url(Map.get(entry, :url)),
      pull_request_url: URLUtils.pull_request_url(entry),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      transcript_path: Map.get(entry, :transcript_path),
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(Map.get(entry, :last_event_at) || entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        cached_input_tokens: Map.get(entry, :codex_cached_input_tokens, 0),
        uncached_input_tokens: uncached_input_tokens(entry.codex_input_tokens, Map.get(entry, :codex_cached_input_tokens, 0)),
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      },
      self_review: self_review_payload(Map.get(entry, :run_id), self_review_by_run)
    }
  end

  defp watching_entry_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      url: URLUtils.present_url(Map.get(entry, :url)),
      pull_request_url: URLUtils.pull_request_url(entry),
      last_ran_at: iso8601(entry.last_ran_at),
      seconds_since_last_run: entry.seconds_since_last_run
    }
  end

  defp conflict_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      state: entry.state,
      linear_state: Map.get(entry, :linear_state),
      url: URLUtils.present_url(Map.get(entry, :url)),
      repo_keys: Map.get(entry, :repo_keys, [])
    }
  end

  defp retry_entry_payload(entry) do
    %{
      repo_key: Map.get(entry, :repo_key),
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      title: Map.get(entry, :title),
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp awaiting_clarification_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      repo_key: Map.get(entry, :repo_key),
      issue_identifier: quality_gate_identifier(entry),
      title: Map.get(entry, :title),
      url: URLUtils.present_url(Map.get(entry, :url)),
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      rounds_asked: Map.get(entry, :rounds_asked, 0),
      updated_at: iso8601(Map.get(entry, :updated_at))
    }
  end

  defp skipped_entry_payload(entry) do
    %{
      kind: entry |> Map.get(:kind) |> quality_gate_kind(),
      issue_id: Map.get(entry, :issue_id),
      repo_key: Map.get(entry, :repo_key),
      issue_identifier: quality_gate_identifier(entry),
      title: Map.get(entry, :title),
      url: URLUtils.present_url(Map.get(entry, :url)),
      score: Map.get(entry, :score),
      reason: Map.get(entry, :reason),
      error: entry |> Map.get(:error) |> quality_gate_error(),
      updated_at: iso8601(Map.get(entry, :updated_at))
    }
  end

  defp running_issue_payload(running) do
    %{
      repo_key: Map.get(running, :repo_key),
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      transcript_path: Map.get(running, :transcript_path),
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(Map.get(running, :last_event_at) || running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        cached_input_tokens: Map.get(running, :codex_cached_input_tokens, 0),
        uncached_input_tokens: uncached_input_tokens(running.codex_input_tokens, Map.get(running, :codex_cached_input_tokens, 0)),
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp retry_issue_payload(retry) do
    %{
      repo_key: Map.get(retry, :repo_key),
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp watching_issue_payload(watching) do
    %{
      repo_key: Map.get(watching, :repo_key),
      state: watching.state,
      url: URLUtils.present_url(watching.url),
      pull_request_url: URLUtils.pull_request_url(watching),
      last_ran_at: iso8601(watching.last_ran_at),
      seconds_since_last_run: watching.seconds_since_last_run
    }
  end

  defp run_history_payload(entry, self_review_by_run) do
    %{
      repo_key: Map.get(entry, :repo_key),
      run_id: entry.run_id,
      issue_id: entry.issue_id,
      issue_identifier: entry.issue_identifier,
      title: Map.get(entry, :title),
      state: Map.get(entry, :state),
      status: entry.status,
      attempt: entry.attempt,
      started_at: iso8601(entry.started_at),
      ended_at: iso8601(Map.get(entry, :ended_at)),
      error: Map.get(entry, :error),
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: Map.get(entry, :session_id),
      transcript_path: Map.get(entry, :transcript_path),
      turn_count: Map.get(entry, :turn_count, 0),
      runtime_seconds: Map.get(entry, :runtime_seconds, 0),
      tokens: Map.get(entry, :tokens, %{}),
      self_review: self_review_payload(entry.run_id, self_review_by_run)
    }
  end

  defp self_review_lookup(running_entries, run_history) do
    run_ids =
      (Enum.map(running_entries, &Map.get(&1, :run_id)) ++
         Enum.map(run_history, &Map.get(&1, :run_id)))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    AuditLog.latest_self_review_by_run(run_ids)
  end

  defp self_review_payload(run_id, self_review_by_run) when is_binary(run_id) do
    case Map.get(self_review_by_run, run_id) do
      %{} = event ->
        %{
          verdict: Map.get(event, "verdict"),
          fail_open_category: Map.get(event, "fail_open_category"),
          findings_count: Map.get(event, "findings_count", 0),
          finding_categories: Map.get(event, "finding_categories", []),
          round: Map.get(event, "round"),
          recorded_at: Map.get(event, "timestamp")
        }

      _ ->
        nil
    end
  end

  defp self_review_payload(_run_id, _self_review_by_run), do: nil

  defp normalize_codex_totals(totals) when is_map(totals) do
    normalized = Map.merge(@empty_codex_totals, totals)

    Map.put(
      normalized,
      :uncached_input_tokens,
      uncached_input_tokens(Map.get(normalized, :input_tokens), Map.get(normalized, :cached_input_tokens))
    )
  end

  defp normalize_codex_totals(_totals), do: @empty_codex_totals

  defp repo_keys(snapshot) when is_map(snapshot) do
    [
      snapshot |> Map.get(:running, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:watching, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:retrying, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:awaiting_clarification, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:skipped, []) |> Enum.map(&Map.get(&1, :repo_key)),
      snapshot |> Map.get(:conflicts, []) |> Enum.flat_map(&(Map.get(&1, :repo_keys, []) || []))
    ]
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_pause(pause) when is_map(pause) do
    %{
      paused: Map.get(pause, :paused, false),
      reason: Map.get(pause, :reason),
      paused_at: iso8601(Map.get(pause, :paused_at))
    }
  end

  defp normalize_pause(_pause) do
    %{paused: false, reason: nil, paused_at: nil}
  end

  defp normalize_budget(budget) when is_map(budget) do
    %{
      per_issue_limit: Map.get(budget, :per_issue_limit),
      daily_limit: Map.get(budget, :daily_limit),
      daily_used: Map.get(budget, :daily_used, 0),
      daily_remaining: Map.get(budget, :daily_remaining),
      daily_paused: Map.get(budget, :daily_paused, false)
    }
  end

  defp normalize_budget(_budget) do
    %{
      per_issue_limit: nil,
      daily_limit: nil,
      daily_used: 0,
      daily_remaining: nil,
      daily_paused: false
    }
  end

  defp normalize_dispatch_state(snapshot) when is_map(snapshot) do
    case Map.get(snapshot, :dispatch_state) do
      %{active?: active?, blockers: blockers} when is_list(blockers) ->
        normalized =
          blockers
          |> Enum.map(&normalize_blocker/1)
          |> Enum.reject(&is_nil/1)

        %{active?: active? == true or normalized == [], blockers: normalized}

      _ ->
        synthesize_dispatch_state(snapshot)
    end
  end

  # Backwards-compat fallback for snapshots that don't carry an explicit
  # dispatch_state (older test fixtures or external callers). Derives manual
  # and budget blockers from the legacy pause/budget fields.
  defp synthesize_dispatch_state(snapshot) do
    pause = Map.get(snapshot, :pause)
    budget = Map.get(snapshot, :budget)

    blockers =
      []
      |> maybe_synth_manual(pause)
      |> maybe_synth_budget(budget)
      |> Enum.reverse()

    %{active?: blockers == [], blockers: blockers}
  end

  defp maybe_synth_manual(blockers, %{paused: true} = pause) do
    [
      %{
        kind: :manual,
        reason: Map.get(pause, :reason),
        since: iso8601(Map.get(pause, :paused_at))
      }
      | blockers
    ]
  end

  defp maybe_synth_manual(blockers, _pause), do: blockers

  defp maybe_synth_budget(blockers, %{daily_paused: true} = budget) do
    [
      %{
        kind: :budget,
        used: Map.get(budget, :daily_used, 0),
        limit: Map.get(budget, :daily_limit, 0),
        day_started_on: nil,
        resets_on: nil
      }
      | blockers
    ]
  end

  defp maybe_synth_budget(blockers, _budget), do: blockers

  defp normalize_blocker(%{kind: :manual} = b) do
    %{
      kind: :manual,
      reason: Map.get(b, :reason),
      since: iso8601(Map.get(b, :since))
    }
  end

  defp normalize_blocker(%{kind: :budget} = b) do
    %{
      kind: :budget,
      used: Map.get(b, :used, 0),
      limit: Map.get(b, :limit, 0),
      day_started_on: Map.get(b, :day_started_on),
      resets_on: Map.get(b, :resets_on)
    }
  end

  defp normalize_blocker(%{kind: :missing_api_key} = b) do
    %{kind: :missing_api_key, provider: Map.get(b, :provider)}
  end

  defp normalize_blocker(%{kind: :tracker_unavailable} = b) do
    %{
      kind: :tracker_unavailable,
      tracker: Map.get(b, :tracker),
      reason: Map.get(b, :reason),
      since: iso8601(Map.get(b, :since)),
      consecutive_failures: Map.get(b, :consecutive_failures, 0)
    }
  end

  defp normalize_blocker(_), do: nil

  defp quality_gate_identifier(entry) do
    Map.get(entry, :identifier) || Map.get(entry, :issue_id) || "unknown"
  end

  defp quality_gate_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp quality_gate_kind(kind) when is_binary(kind), do: kind
  defp quality_gate_kind(_kind), do: "unknown"

  defp quality_gate_error(nil), do: nil
  defp quality_gate_error(error) when is_binary(error), do: error
  defp quality_gate_error(error), do: inspect(error)

  defp workspace_payload(issue_identifier, running, retry) do
    if running || retry do
      %{
        path: workspace_path(issue_identifier, running, retry),
        host: workspace_host(running, retry)
      }
    end
  end

  defp workspace_path(issue_identifier, running, retry) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry) do
    (running && Map.get(running, :worker_host)) || (retry && Map.get(retry, :worker_host))
  end

  defp recent_events_payload(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp running_transcript_payload(running, repo_key) do
    %{
      repo_key: Map.get(running, :repo_key) || repo_key,
      issue_id: running.issue_id,
      issue_identifier: running.identifier,
      state: running.state,
      session_id: running.session_id,
      started_at: iso8601(running.started_at),
      last_event_at: iso8601(Map.get(running, :last_event_at) || running.last_codex_timestamp),
      turn_count: Map.get(running, :turn_count, 0),
      tokens: transcript_tokens(running),
      events: transcript_events(running)
    }
  end

  defp watching_transcript_payload(watching, repo_key) do
    %{
      repo_key: Map.get(watching, :repo_key) || repo_key,
      issue_id: watching.issue_id,
      issue_identifier: watching.identifier,
      state: watching.state,
      session_id: Map.get(watching, :session_id),
      started_at: iso8601(Map.get(watching, :started_at) || Map.get(watching, :last_ran_at)),
      last_event_at: iso8601(Map.get(watching, :last_event_at) || Map.get(watching, :last_ran_at)),
      turn_count: Map.get(watching, :turn_count, 0),
      tokens: transcript_tokens(watching),
      events: transcript_events(watching)
    }
  end

  defp transcript_tokens(%{tokens: tokens}) when is_map(tokens) do
    input_tokens = Map.get(tokens, :input_tokens, 0)
    cached_input_tokens = Map.get(tokens, :cached_input_tokens, 0)

    %{
      input_tokens: input_tokens,
      cached_input_tokens: cached_input_tokens,
      uncached_input_tokens: Map.get(tokens, :uncached_input_tokens, uncached_input_tokens(input_tokens, cached_input_tokens)),
      output_tokens: Map.get(tokens, :output_tokens, 0),
      total_tokens: Map.get(tokens, :total_tokens, 0)
    }
  end

  defp transcript_tokens(entry) when is_map(entry) do
    input_tokens = Map.get(entry, :codex_input_tokens, 0)
    cached_input_tokens = Map.get(entry, :codex_cached_input_tokens, 0)

    %{
      input_tokens: input_tokens,
      cached_input_tokens: cached_input_tokens,
      uncached_input_tokens: uncached_input_tokens(input_tokens, cached_input_tokens),
      output_tokens: Map.get(entry, :codex_output_tokens, 0),
      total_tokens: Map.get(entry, :codex_total_tokens, 0)
    }
  end

  defp transcript_events(%{transcript_buffer: events}) when is_list(events), do: events
  defp transcript_events(_running), do: []

  defp repo_key_matches?(_entry, nil), do: true
  defp repo_key_matches?(entry, repo_key), do: Map.get(entry, :repo_key) == repo_key

  defp current_repo_key, do: Config.repo_key_or_nil()

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp uncached_input_tokens(input_tokens, cached_input_tokens) when is_integer(input_tokens) and is_integer(cached_input_tokens) do
    max(input_tokens - cached_input_tokens, 0)
  end

  defp uncached_input_tokens(_input_tokens, _cached_input_tokens), do: 0

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
