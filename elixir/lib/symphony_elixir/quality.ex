defmodule SymphonyElixir.Quality do
  @moduledoc """
  Builds and queries structured quality eval logs for completed agent runs.
  """

  require Logger

  alias SymphonyElixir.{Config, RunStore, Tracker, URLUtils}
  alias SymphonyElixir.Linear.Issue

  @default_window_limit 50
  @max_api_limit 500
  @read_command ~r/(^|\s)(cat|sed|rg|grep|head|tail|nl|less|bat|awk|find|ls|git\s+show)\b/
  @test_file_patterns ["**/*_test.*", "**/*.test.*", "**/*_spec.*", "**/*.spec.*"]

  @spec persist_run_eval(map(), String.t(), String.t() | nil, keyword()) :: :ok
  def persist_run_eval(running_entry, status, error, opts \\ [])
      when is_map(running_entry) and is_binary(status) do
    run_store = Keyword.get(opts, :run_store, RunStore)

    running_entry
    |> maybe_refresh_issue(opts)
    |> build_eval_log(status, error, opts)
    |> run_store.put_eval_log()
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to persist quality eval log: #{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning("Quality eval logging failed: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Quality eval logging failed: #{inspect({kind, reason})}")
      :ok
  end

  @doc false
  @spec build_eval_log_for_test(map(), String.t(), String.t() | nil, keyword()) :: map()
  def build_eval_log_for_test(running_entry, status, error, opts \\ []) do
    build_eval_log(running_entry, status, error, opts)
  end

  @spec runs_payload(map()) :: {:ok, map()} | {:error, term()}
  def runs_payload(params) when is_map(params) do
    with {:ok, filters} <- parse_filters(params) do
      runs = RunStore.list_eval_logs(filters)

      case runs do
        records when is_list(records) ->
          {:ok,
           %{
             generated_at: iso8601(DateTime.utc_now()),
             filters: filter_payload(filters),
             count: length(records),
             runs: Enum.map(records, &run_payload/1)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec dashboard_payload(map()) :: map()
  def dashboard_payload(params) when is_map(params) do
    filters =
      case parse_filters(params, default_limit: @default_window_limit) do
        {:ok, parsed} -> parsed
        {:error, _reason} -> [limit: @default_window_limit]
      end

    runs =
      case RunStore.list_eval_logs(filters) do
        records when is_list(records) -> records
        {:error, _reason} -> []
      end

    %{
      filters: filter_payload(filters),
      metrics: metrics(runs),
      runs: Enum.map(runs, &run_payload/1)
    }
  end

  @spec session_report(String.t(), map()) :: {:ok, map()} | {:error, :session_not_found | term()}
  def session_report(session_id, params \\ %{}) when is_binary(session_id) and is_map(params) do
    with {:ok, filters} <- parse_filters(params, default_limit: :all) do
      filters = filters |> Keyword.put(:session_id, session_id) |> Keyword.put(:limit, :all)

      case RunStore.list_eval_logs(filters) do
        [] ->
          {:error, :session_not_found}

        records when is_list(records) ->
          {:ok,
           %{
             generated_at: iso8601(DateTime.utc_now()),
             session_id: session_id,
             metrics: metrics(records),
             runs: Enum.map(records, &run_payload/1)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec parse_filters(map(), keyword()) :: {:ok, keyword()} | {:error, term()}
  def parse_filters(params, opts \\ []) when is_map(params) do
    with {:ok, date_from} <- parse_date_param(params["date_from"] || params["from"]),
         {:ok, date_to} <- parse_date_param(params["date_to"] || params["to"]),
         {:ok, limit} <- parse_limit(params["limit"], Keyword.get(opts, :default_limit, @default_window_limit)) do
      filters =
        []
        |> put_filter(:outcome, blank_to_nil(params["outcome"]))
        |> put_filter(:agent_kind, blank_to_nil(params["agent"] || params["agent_kind"]))
        |> put_filter(:issue_label, blank_to_nil(params["issue_label"] || params["label"]))
        |> put_filter(:date_from, date_from)
        |> put_filter(:date_to, date_to)
        |> put_filter(:limit, limit)

      {:ok, filters}
    end
  end

  defp build_eval_log(running_entry, status, error, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    issue =
      case Map.get(running_entry, :issue) do
        %Issue{} = issue -> issue
        _ -> %Issue{}
      end

    started_at = Map.get(running_entry, :started_at)
    ended_at = Keyword.get(opts, :ended_at, Map.get(running_entry, :ended_at, now))
    run_id = Map.get(running_entry, :run_id) || "run-#{System.system_time(:microsecond)}"
    pull_request_url = URLUtils.pull_request_url(running_entry) || URLUtils.pull_request_url(issue)

    %{
      eval_id: run_id,
      run_id: run_id,
      issue_id: Map.get(issue, :id),
      issue_identifier: Map.get(issue, :identifier) || Map.get(running_entry, :identifier),
      issue_labels: Issue.label_names(issue),
      outcome: outcome_for(status, error, pull_request_url),
      status: status,
      error: error,
      agent_kind: agent_kind(opts),
      tokens: tokens_from_entry(running_entry),
      duration_seconds: duration_seconds(started_at, ended_at),
      tests_read: tests_read_signal(running_entry, opts),
      workspace_path: Map.get(running_entry, :workspace_path),
      worker_host: Map.get(running_entry, :worker_host),
      session_id: Map.get(running_entry, :session_id),
      pull_request_url: pull_request_url,
      started_at: started_at,
      ended_at: ended_at,
      logged_at: now,
      date: DateTime.to_date(now)
    }
  end

  defp maybe_refresh_issue(running_entry, opts) do
    if Keyword.get(opts, :refresh_issue?, true) do
      tracker = Keyword.get(opts, :tracker, Tracker)
      issue = Map.get(running_entry, :issue)

      case refresh_issue(issue, tracker) do
        %Issue{} = refreshed_issue -> Map.put(running_entry, :issue, refreshed_issue)
        nil -> running_entry
      end
    else
      running_entry
    end
  end

  defp refresh_issue(%Issue{id: issue_id}, tracker) when is_binary(issue_id) do
    case tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} ->
        issue

      {:ok, []} ->
        nil

      {:error, reason} ->
        Logger.debug("Unable to refresh issue for quality eval log: #{inspect(reason)}")
        nil
    end
  rescue
    exception ->
      Logger.debug("Unable to refresh issue for quality eval log: #{Exception.message(exception)}")
      nil
  catch
    _kind, _reason ->
      nil
  end

  defp refresh_issue(_issue, _tracker), do: nil

  defp outcome_for(_status, error, _pull_request_url) when is_binary(error), do: "error"
  defp outcome_for(status, _error, _pull_request_url) when status in ["failure", "timeout", "budget_exhausted"], do: "error"
  defp outcome_for(_status, _error, pull_request_url) when is_binary(pull_request_url) and pull_request_url != "", do: "pr_opened"
  defp outcome_for(_status, _error, _pull_request_url), do: "no_changes"

  defp agent_kind(opts) do
    case Keyword.get(opts, :agent_kind) || Config.settings!().agent.kind do
      kind when is_binary(kind) and kind != "" -> kind
      _ -> "unknown"
    end
  end

  defp tokens_from_entry(%{tokens: tokens}) when is_map(tokens) do
    %{
      input_tokens: integer_or_zero(Map.get(tokens, :input_tokens) || Map.get(tokens, "input_tokens")),
      output_tokens: integer_or_zero(Map.get(tokens, :output_tokens) || Map.get(tokens, "output_tokens")),
      total_tokens: integer_or_zero(Map.get(tokens, :total_tokens) || Map.get(tokens, "total_tokens"))
    }
  end

  defp tokens_from_entry(running_entry) when is_map(running_entry) do
    %{
      input_tokens: integer_or_zero(Map.get(running_entry, :codex_input_tokens)),
      output_tokens: integer_or_zero(Map.get(running_entry, :codex_output_tokens)),
      total_tokens: integer_or_zero(Map.get(running_entry, :codex_total_tokens))
    }
  end

  defp duration_seconds(%DateTime{} = started_at, %DateTime{} = ended_at) do
    max(DateTime.diff(ended_at, started_at, :second), 0)
  end

  defp duration_seconds(_started_at, _ended_at), do: 0

  defp tests_read_signal(running_entry, opts) do
    with {:ok, evidence_events} <- transcript_evidence_events(running_entry, opts),
         test_paths when test_paths != [] <- candidate_test_paths(running_entry, opts) do
      read_evidence = read_evidence(evidence_events)

      if Enum.any?(test_paths, &test_path_read?(&1, read_evidence, Map.get(running_entry, :workspace_path))) do
        true
      else
        false
      end
    else
      _ -> nil
    end
  end

  defp transcript_evidence_events(running_entry, opts) do
    case Keyword.fetch(opts, :transcript_events) do
      {:ok, nil} -> {:error, :transcript_unavailable}
      {:ok, events} when is_list(events) and events != [] -> {:ok, events}
      {:ok, _events} -> {:error, :transcript_unavailable}
      :error -> transcript_evidence_events_from_entry(running_entry)
    end
  end

  defp transcript_evidence_events_from_entry(running_entry) do
    buffered = buffered_transcript_events(running_entry)
    from_file = transcript_file_events(Map.get(running_entry, :transcript_path))
    events = from_file ++ buffered

    if events == [] do
      {:error, :transcript_unavailable}
    else
      {:ok, events}
    end
  end

  defp buffered_transcript_events(%{transcript_buffer: queue}) do
    cond do
      :queue.is_queue(queue) -> :queue.to_list(queue)
      is_list(queue) -> queue
      true -> []
    end
  end

  defp buffered_transcript_events(_running_entry), do: []

  defp transcript_file_events(path) when is_binary(path) and path != "" do
    with true <- File.regular?(path),
         {:ok, contents} <- File.read(path) do
      contents
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&decode_transcript_line/1)
    else
      _ -> []
    end
  rescue
    _exception -> []
  end

  defp transcript_file_events(_path), do: []

  defp decode_transcript_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> line
    end
  end

  defp read_evidence(events) do
    Enum.flat_map(events, fn event ->
      command_evidence(event) ++ tool_read_evidence(event)
    end)
  end

  defp command_evidence(event) do
    event
    |> command_strings()
    |> Enum.filter(&String.match?(&1, @read_command))
  end

  defp command_strings(event) when is_binary(event), do: [event]

  defp command_strings(event) do
    event
    |> strings_at_paths([
      [:payload, "params", "msg", "command"],
      ["payload", "params", "msg", "command"],
      [:payload, "params", "command"],
      ["payload", "params", "command"],
      ["params", "msg", "command"],
      [:params, :msg, :command],
      ["params", "command"],
      [:params, :command],
      [:command],
      "command"
    ])
  end

  defp tool_read_evidence(event) do
    tool_name =
      first_string_at_paths(event, [
        [:payload, "params", "name"],
        ["payload", "params", "name"],
        [:payload, "params", "tool"],
        ["payload", "params", "tool"],
        [:name],
        "name",
        [:tool],
        "tool"
      ])

    if read_tool_name?(tool_name) do
      [inspect(event)]
    else
      []
    end
  end

  defp read_tool_name?(name) when is_binary(name) do
    name
    |> String.downcase()
    |> then(&(&1 in ["read", "read_file", "open", "grep", "search", "rg"]))
  end

  defp read_tool_name?(_name), do: false

  defp strings_at_paths(value, paths) do
    paths
    |> Enum.flat_map(fn path ->
      case value_at_path(value, List.wrap(path)) do
        text when is_binary(text) -> [text]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp first_string_at_paths(value, paths) do
    Enum.find_value(paths, fn path ->
      case value_at_path(value, List.wrap(path)) do
        text when is_binary(text) -> text
        _ -> nil
      end
    end)
  end

  defp value_at_path(value, []), do: value

  defp value_at_path(value, [key | rest]) when is_map(value) do
    value
    |> Map.get(key)
    |> case do
      nil when is_atom(key) -> Map.get(value, Atom.to_string(key))
      nil when is_binary(key) -> Map.get(value, String.to_existing_atom(key))
      found -> found
    end
    |> value_at_path(rest)
  rescue
    ArgumentError -> nil
  end

  defp value_at_path(_value, _path), do: nil

  defp candidate_test_paths(running_entry, opts) do
    workspace = Map.get(running_entry, :workspace_path)
    touched_paths = Keyword.get_lazy(opts, :touched_paths, fn -> touched_paths(workspace) end)
    existing_tests = Keyword.get_lazy(opts, :existing_test_paths, fn -> existing_test_paths(workspace) end)
    touched_related_dirs = related_test_dirs(touched_paths)

    existing_tests
    |> Enum.filter(fn test_path ->
      test_path in touched_paths or Path.dirname(test_path) in touched_related_dirs
    end)
    |> Enum.uniq()
  end

  defp touched_paths(workspace) when is_binary(workspace) and workspace != "" do
    (diff_paths(workspace, ["diff", "--name-only", "origin/main...HEAD"]) ++
       diff_paths(workspace, ["diff", "--name-only", "HEAD"]) ++
       diff_paths(workspace, ["diff", "--name-only", "--cached"]))
    |> Enum.uniq()
  end

  defp touched_paths(_workspace), do: []

  defp diff_paths(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  rescue
    _exception -> []
  end

  defp existing_test_paths(workspace) when is_binary(workspace) and workspace != "" do
    @test_file_patterns
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(workspace, pattern)) end)
    |> Enum.reject(&ignored_path?/1)
    |> Enum.map(&Path.relative_to(&1, workspace))
    |> Enum.uniq()
  end

  defp existing_test_paths(_workspace), do: []

  defp ignored_path?(path) do
    String.contains?(path, ["/.git/", "/deps/", "/_build/", "/node_modules/"])
  end

  defp related_test_dirs(touched_paths) when is_list(touched_paths) do
    touched_paths
    |> Enum.flat_map(&related_test_dirs_for_path/1)
    |> Enum.uniq()
  end

  defp related_test_dirs_for_path(path) when is_binary(path) do
    dir = Path.dirname(path)

    mirrored =
      cond do
        String.starts_with?(dir, "lib/") -> ["test/" <> String.replace_prefix(dir, "lib/", "")]
        String.starts_with?(dir, "src/") -> ["test/" <> String.replace_prefix(dir, "src/", "")]
        true -> []
      end

    [dir | mirrored]
  end

  defp related_test_dirs_for_path(_path), do: []

  defp test_path_read?(test_path, read_evidence, workspace) do
    absolute = if is_binary(workspace), do: Path.join(workspace, test_path), else: nil
    basename = Path.basename(test_path)

    Enum.any?(read_evidence, fn evidence ->
      String.contains?(evidence, test_path) or
        (is_binary(absolute) and String.contains?(evidence, absolute)) or
        String.contains?(evidence, basename)
    end)
  end

  defp metrics(records) when is_list(records) do
    total = length(records)

    %{
      total_runs: total,
      pr_opened_rate: rate(count_outcome(records, "pr_opened"), total),
      avg_tokens: average_tokens(records),
      tests_read_rate: tests_read_rate(records),
      error_rate: rate(count_outcome(records, "error"), total)
    }
  end

  defp count_outcome(records, outcome) do
    Enum.count(records, &(Map.get(&1, :outcome) == outcome))
  end

  defp average_tokens([]), do: nil

  defp average_tokens(records) do
    total =
      Enum.reduce(records, 0, fn record, acc ->
        acc + integer_or_zero(get_in(record, [:tokens, :total_tokens]))
      end)

    Float.round(total / length(records), 1)
  end

  defp tests_read_rate(records) do
    applicable = Enum.filter(records, &is_boolean(Map.get(&1, :tests_read)))
    rate(Enum.count(applicable, &(&1.tests_read == true)), length(applicable))
  end

  defp rate(_count, 0), do: nil
  defp rate(count, total), do: Float.round(count / total, 4)

  defp run_payload(record) when is_map(record) do
    %{
      eval_id: Map.get(record, :eval_id),
      run_id: Map.get(record, :run_id),
      issue_id: Map.get(record, :issue_id),
      issue_identifier: Map.get(record, :issue_identifier),
      issue_labels: Map.get(record, :issue_labels, []),
      outcome: Map.get(record, :outcome),
      status: Map.get(record, :status),
      error: Map.get(record, :error),
      agent_kind: Map.get(record, :agent_kind),
      tokens: Map.get(record, :tokens, %{}),
      duration_seconds: Map.get(record, :duration_seconds, 0),
      tests_read: Map.get(record, :tests_read),
      workspace_path: Map.get(record, :workspace_path),
      session_id: Map.get(record, :session_id),
      pull_request_url: URLUtils.present_url(Map.get(record, :pull_request_url)),
      started_at: iso8601(Map.get(record, :started_at)),
      ended_at: iso8601(Map.get(record, :ended_at)),
      logged_at: iso8601(Map.get(record, :logged_at)),
      date: date_iso8601(Map.get(record, :date))
    }
  end

  defp filter_payload(filters) do
    %{
      outcome: Keyword.get(filters, :outcome),
      agent_kind: Keyword.get(filters, :agent_kind),
      issue_label: Keyword.get(filters, :issue_label),
      date_from: date_iso8601(Keyword.get(filters, :date_from)),
      date_to: date_iso8601(Keyword.get(filters, :date_to)),
      limit: Keyword.get(filters, :limit)
    }
  end

  defp parse_date_param(nil), do: {:ok, nil}
  defp parse_date_param(""), do: {:ok, nil}

  defp parse_date_param(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:ok, nil}

      match?({:ok, _date}, Date.from_iso8601(trimmed)) ->
        Date.from_iso8601(trimmed)

      true ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, datetime, _offset} -> {:ok, DateTime.to_date(datetime)}
          {:error, reason} -> {:error, {:invalid_date, value, reason}}
        end
    end
  end

  defp parse_date_param(_value), do: {:error, :invalid_date}

  defp parse_limit(nil, default), do: {:ok, default}
  defp parse_limit("", default), do: {:ok, default}

  defp parse_limit(value, _default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {limit, ""} when limit >= 0 -> {:ok, min(limit, @max_api_limit)}
      _ -> {:error, {:invalid_limit, value}}
    end
  end

  defp parse_limit(_value, _default), do: {:error, :invalid_limit}

  defp put_filter(filters, _key, nil), do: filters
  defp put_filter(filters, key, value), do: Keyword.put(filters, key, value)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp integer_or_zero(value) when is_integer(value), do: max(value, 0)
  defp integer_or_zero(_value), do: 0

  defp iso8601(%DateTime{} = datetime), do: datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_value), do: nil

  defp date_iso8601(%Date{} = date), do: Date.to_iso8601(date)
  defp date_iso8601(_date), do: nil
end
