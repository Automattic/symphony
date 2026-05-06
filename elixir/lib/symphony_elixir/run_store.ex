defmodule SymphonyElixir.RunStore do
  @moduledoc """
  Durable store for orchestrator run history, retry queue entries, and totals.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.LogFile

  @runs_table :symphony_run_store_runs
  @retry_table :symphony_run_store_retries
  @totals_table :symphony_run_store_totals
  @pr_review_table :symphony_run_store_pr_reviews
  @eval_logs_table :symphony_run_store_eval_logs
  @eval_log_attributes [:eval_id, :outcome, :agent_kind, :issue_label, :date, :record]
  @eval_log_indexes [:outcome, :agent_kind, :issue_label, :date]
  @tables [
    {@runs_table, [:run_id, :record], []},
    {@retry_table, [:issue_id, :record], []},
    {@totals_table, [:key, :record], []},
    {@pr_review_table, [:issue_id, :record], []},
    {@eval_logs_table, @eval_log_attributes, [type: :bag, index: @eval_log_indexes]}
  ]
  @data_tables Enum.map(@tables, fn {table, _attributes, _opts} -> table end)
  @codex_totals_key :codex_totals

  defmodule State do
    @moduledoc false

    defstruct [:dir]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ensure_started() :: :ok | {:error, term()}
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec put_run(map()) :: :ok | {:error, term()}
  def put_run(%{run_id: run_id} = record) when is_binary(run_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@runs_table, run_id, normalize_record(record)})
        :ok
      end)
    end
  end

  def put_run(_record), do: {:error, :invalid_run_record}

  @spec update_run(String.t(), map()) :: :ok | {:error, term()}
  def update_run(run_id, attrs) when is_binary(run_id) and is_map(attrs) do
    with :ok <- ensure_started() do
      update_run_record(run_id, attrs)
      |> unwrap_nested_error()
    end
  end

  def update_run(_run_id, _attrs), do: {:error, :invalid_run_record}

  @spec list_runs() :: [map()] | {:error, term()}
  def list_runs, do: list_runs(50)

  @spec list_runs(non_neg_integer() | :all) :: [map()] | {:error, term()}
  def list_runs(limit) when is_integer(limit) and limit >= 0 do
    case list_runs(:all) do
      runs when is_list(runs) -> Enum.take(runs, limit)
      {:error, reason} -> {:error, reason}
    end
  end

  def list_runs(:all) do
    with :ok <- ensure_started() do
      transaction(fn ->
        @runs_table
        |> all_records()
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :started_at)), :desc)
      end)
    end
  end

  @spec interrupt_running_runs(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def interrupt_running_runs(error) when is_binary(error) do
    now = DateTime.utc_now()

    with :ok <- ensure_started() do
      durable_transaction(fn ->
        {:ok, interrupt_running_records(error, now)}
      end)
      |> unwrap_nested_error()
    end
  end

  def interrupt_running_runs(_error), do: {:error, :invalid_error}

  @spec put_retry(map()) :: :ok | {:error, term()}
  def put_retry(%{issue_id: issue_id} = record) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@retry_table, issue_id, normalize_record(record)})
        :ok
      end)
    end
  end

  def put_retry(_record), do: {:error, :invalid_retry_record}

  @spec delete_retry(String.t()) :: :ok | {:error, term()}
  def delete_retry(issue_id) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.delete({@retry_table, issue_id})
        :ok
      end)
    end
  end

  def delete_retry(_issue_id), do: {:error, :invalid_issue_id}

  @spec list_retries() :: [map()] | {:error, term()}
  def list_retries do
    with :ok <- ensure_started() do
      transaction(fn ->
        @retry_table
        |> all_records()
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :due_at)), :asc)
      end)
    end
  end

  @spec put_codex_totals(map()) :: :ok | {:error, term()}
  def put_codex_totals(totals) when is_map(totals) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@totals_table, @codex_totals_key, normalize_record(totals)})
        :ok
      end)
    end
  end

  def put_codex_totals(_totals), do: {:error, :invalid_codex_totals}

  @spec get_codex_totals() :: map() | nil | {:error, term()}
  def get_codex_totals do
    with :ok <- ensure_started() do
      transaction(&read_codex_totals/0)
    end
  end

  @spec put_pr_review(map()) :: :ok | {:error, term()}
  def put_pr_review(%{issue_id: issue_id} = record) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.write({@pr_review_table, issue_id, normalize_record(record)})
        :ok
      end)
    end
  end

  def put_pr_review(_record), do: {:error, :invalid_pr_review_record}

  @spec update_pr_review(String.t(), map()) :: :ok | {:error, term()}
  def update_pr_review(issue_id, attrs) when is_binary(issue_id) and is_map(attrs) do
    with :ok <- ensure_started() do
      update_pr_review_record(issue_id, attrs)
      |> unwrap_nested_error()
    end
  end

  def update_pr_review(_issue_id, _attrs), do: {:error, :invalid_pr_review_record}

  @spec delete_pr_review(String.t()) :: :ok | {:error, term()}
  def delete_pr_review(issue_id) when is_binary(issue_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        :mnesia.delete({@pr_review_table, issue_id})
        :ok
      end)
    end
  end

  def delete_pr_review(_issue_id), do: {:error, :invalid_issue_id}

  @spec list_pr_reviews() :: [map()] | {:error, term()}
  def list_pr_reviews do
    with :ok <- ensure_started() do
      transaction(fn ->
        @pr_review_table
        |> all_records()
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :updated_at)), :desc)
      end)
    end
  end

  @spec put_eval_log(map()) :: :ok | {:error, term()}
  def put_eval_log(%{eval_id: eval_id} = record) when is_binary(eval_id) do
    with :ok <- ensure_started() do
      durable_transaction(fn ->
        write_eval_log_records(eval_id, normalize_eval_log_record(record))
      end)
    end
  end

  def put_eval_log(_record), do: {:error, :invalid_eval_log_record}

  @spec list_eval_logs(keyword()) :: [map()] | {:error, term()}
  def list_eval_logs(opts \\ []) when is_list(opts) do
    with :ok <- ensure_started() do
      transaction(fn ->
        @eval_logs_table
        |> all_eval_log_records()
        |> filter_eval_logs(opts)
        |> Enum.sort_by(&datetime_sort_key(Map.get(&1, :logged_at)), :desc)
        |> limit_eval_logs(Keyword.get(opts, :limit, 50))
      end)
    end
  end

  @spec clear() :: :ok | {:error, term()}
  def clear do
    with :ok <- ensure_started() do
      @data_tables
      |> Enum.reduce_while(:ok, &clear_table/2)
      |> sync_after_clear()
    end
  end

  @impl true
  def init(opts) do
    dir = Keyword.get(opts, :dir, store_dir())

    case setup_mnesia(dir) do
      :ok ->
        {:ok, %State{dir: dir}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @spec store_dir() :: Path.t()
  def store_dir do
    Application.get_env(:symphony_elixir, :run_store_dir) ||
      Path.join(
        Path.dirname(Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())),
        "run_store"
      )
  end

  defp setup_mnesia(dir) when is_binary(dir) do
    expanded_dir = Path.expand(dir)

    case File.mkdir_p(expanded_dir) do
      :ok -> start_and_ensure_mnesia(expanded_dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp setup_mnesia(_dir), do: {:error, :invalid_run_store_dir}

  defp start_and_ensure_mnesia(dir) do
    case start_mnesia(dir) do
      :ok -> ensure_tables()
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_mnesia(dir) do
    case load_mnesia() do
      :ok -> start_or_validate_mnesia(dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_or_validate_mnesia(dir) do
    if mnesia_running?() do
      ensure_running_mnesia_dir(dir)
    else
      start_stopped_mnesia(dir)
    end
  end

  defp start_stopped_mnesia(dir) do
    Application.put_env(:mnesia, :dir, String.to_charlist(dir))

    case create_schema() do
      :ok -> normalize_mnesia_start(:mnesia.start())
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_mnesia do
    case Application.load(:mnesia) do
      :ok -> :ok
      {:error, {:already_loaded, :mnesia}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mnesia_running? do
    :mnesia.system_info(:is_running) == :yes
  catch
    :exit, _reason -> false
  end

  defp create_schema do
    case :mnesia.create_schema([node()]) do
      :ok -> :ok
      {:error, {_, {:already_exists, _}}} -> :ok
      {:error, {:already_exists, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_mnesia_start(:ok), do: :ok
  defp normalize_mnesia_start({:error, reason}), do: {:error, reason}

  defp ensure_running_mnesia_dir(expected_dir) do
    running_dir =
      :mnesia.system_info(:directory)
      |> to_string()
      |> Path.expand()

    if running_dir == expected_dir do
      :ok
    else
      {:error, {:mnesia_dir_mismatch, %{expected: expected_dir, running: running_dir}}}
    end
  end

  defp ensure_tables do
    with :ok <- Enum.reduce_while(@tables, :ok, &ensure_table/2) do
      wait_for_tables()
    end
  end

  defp ensure_table({table, attributes, opts}, :ok) do
    if table in :mnesia.system_info(:tables) do
      case ensure_table_indexes(table, Keyword.get(opts, :index, [])) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    else
      create_opts =
        opts
        |> Keyword.put_new(:type, :set)
        |> Keyword.merge(attributes: attributes, disc_copies: [node()])

      case :mnesia.create_table(
             table,
             create_opts
           ) do
        {:atomic, :ok} -> {:cont, :ok}
        {:aborted, {:already_exists, ^table}} -> {:cont, :ok}
        {:aborted, reason} -> {:halt, {:error, reason}}
      end
    end
  end

  defp ensure_table_indexes(_table, []), do: :ok

  defp ensure_table_indexes(table, indexes) when is_list(indexes) do
    current_indexes = :mnesia.table_info(table, :index)
    attributes = :mnesia.table_info(table, :attributes)

    indexes
    |> Enum.reject(&index_present?(&1, current_indexes, attributes))
    |> Enum.reduce_while(:ok, fn index, :ok ->
      case :mnesia.add_table_index(table, index) do
        {:atomic, :ok} -> {:cont, :ok}
        {:aborted, {:already_exists, ^table, ^index}} -> {:cont, :ok}
        {:aborted, {:already_exists, ^index}} -> {:cont, :ok}
        {:aborted, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp index_present?(index, current_indexes, attributes) do
    index in current_indexes or attribute_position(index, attributes) in current_indexes
  end

  defp attribute_position(index, attributes) when is_atom(index) and is_list(attributes) do
    case Enum.find_index(attributes, &(&1 == index)) do
      nil -> nil
      zero_based -> zero_based + 2
    end
  end

  defp attribute_position(index, _attributes), do: index

  defp wait_for_tables do
    case :mnesia.wait_for_tables(@data_tables, 5_000) do
      :ok -> :ok
      {:timeout, tables} -> {:error, {:mnesia_table_timeout, tables}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transaction(fun) when is_function(fun, 0) do
    case :mnesia.transaction(fun) do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp update_run_record(run_id, attrs) do
    durable_transaction(fn ->
      case :mnesia.read(@runs_table, run_id) do
        [{@runs_table, ^run_id, record}] ->
          :mnesia.write({@runs_table, run_id, Map.merge(record, normalize_record(attrs))})
          :ok

        [] ->
          {:error, :run_not_found}
      end
    end)
  end

  defp update_pr_review_record(issue_id, attrs) do
    durable_transaction(fn ->
      case :mnesia.read(@pr_review_table, issue_id) do
        [{@pr_review_table, ^issue_id, record}] ->
          :mnesia.write({@pr_review_table, issue_id, Map.merge(record, normalize_record(attrs))})
          :ok

        [] ->
          {:error, :pr_review_not_found}
      end
    end)
  end

  defp durable_transaction(fun) when is_function(fun, 0) do
    case transaction(fun) do
      {:error, _reason} = error ->
        error

      result ->
        case sync_mnesia_log() do
          :ok ->
            result

          {:error, reason} ->
            Logger.warning("Run store transaction committed but failed to sync Mnesia log: #{inspect(reason)}")
            result
        end
    end
  end

  defp sync_mnesia_log do
    case :mnesia.sync_log() do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp clear_table(table, :ok) do
    case :mnesia.clear_table(table) do
      {:atomic, :ok} -> {:cont, :ok}
      {:aborted, reason} -> {:halt, {:error, reason}}
    end
  end

  defp sync_after_clear(:ok), do: sync_mnesia_log()
  defp sync_after_clear({:error, reason}), do: {:error, reason}

  defp read_codex_totals do
    case :mnesia.read(@totals_table, @codex_totals_key) do
      [{@totals_table, @codex_totals_key, totals}] -> totals
      [] -> nil
    end
  end

  defp all_records(table) do
    :mnesia.match_object({table, :_, :_})
    |> Enum.map(fn {^table, _key, record} -> record end)
  end

  defp all_eval_log_records(table) do
    :mnesia.match_object({table, :_, :_, :_, :_, :_, :_})
    |> Enum.map(fn {^table, _eval_id, _outcome, _agent_kind, _issue_label, _date, record} -> record end)
    |> Enum.uniq_by(&Map.get(&1, :eval_id))
  end

  defp normalize_record(record) when is_map(record) do
    Map.new(record)
  end

  defp normalize_eval_log_record(record) when is_map(record) do
    record
    |> normalize_record()
    |> Map.put_new(:issue_labels, [])
    |> Map.update!(:issue_labels, &normalize_issue_labels/1)
    |> Map.put_new(:logged_at, DateTime.utc_now())
    |> Map.put_new_lazy(:date, fn -> eval_log_date(Map.get(record, :logged_at)) end)
    |> Map.update!(:date, &eval_log_date/1)
    |> Map.put_new(:outcome, "unknown")
    |> Map.put_new(:agent_kind, "unknown")
  end

  defp normalize_issue_labels(labels) when is_list(labels) do
    labels
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_issue_labels(_labels), do: []

  defp eval_log_date(%Date{} = date), do: date
  defp eval_log_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp eval_log_date(_value), do: Date.utc_today()

  defp eval_log_issue_label_index_values(%{issue_labels: labels}) when is_list(labels) and labels != [],
    do: labels

  defp eval_log_issue_label_index_values(_record), do: [nil]

  defp write_eval_log_records(eval_id, normalized) do
    :mnesia.delete({@eval_logs_table, eval_id})

    normalized
    |> eval_log_issue_label_index_values()
    |> Enum.each(&write_eval_log_record(eval_id, normalized, &1))

    :ok
  end

  defp write_eval_log_record(eval_id, normalized, issue_label) do
    :mnesia.write({
      @eval_logs_table,
      eval_id,
      normalized.outcome,
      normalized.agent_kind,
      issue_label,
      normalized.date,
      normalized
    })
  end

  defp filter_eval_logs(records, opts) do
    Enum.filter(records, fn record ->
      eval_log_matches?(record, opts)
    end)
  end

  defp eval_log_matches?(record, opts) do
    matches_value?(Map.get(record, :outcome), Keyword.get(opts, :outcome)) and
      matches_value?(Map.get(record, :agent_kind), Keyword.get(opts, :agent_kind)) and
      matches_issue_label?(Map.get(record, :issue_labels, []), Keyword.get(opts, :issue_label)) and
      matches_date_range?(Map.get(record, :date), Keyword.get(opts, :date_from), Keyword.get(opts, :date_to)) and
      matches_value?(Map.get(record, :session_id), Keyword.get(opts, :session_id))
  end

  defp matches_value?(_value, nil), do: true
  defp matches_value?(value, value), do: true
  defp matches_value?(_value, _filter), do: false

  defp matches_issue_label?(_labels, nil), do: true
  defp matches_issue_label?(labels, issue_label) when is_list(labels), do: issue_label in labels
  defp matches_issue_label?(_labels, _issue_label), do: false

  defp matches_date_range?(%Date{} = date, date_from, date_to) do
    after_from? =
      case date_from do
        %Date{} = from -> Date.compare(date, from) in [:gt, :eq]
        _ -> true
      end

    before_to? =
      case date_to do
        %Date{} = to -> Date.compare(date, to) in [:lt, :eq]
        _ -> true
      end

    after_from? and before_to?
  end

  defp matches_date_range?(_date, _date_from, _date_to), do: true

  defp limit_eval_logs(records, :all), do: records

  defp limit_eval_logs(records, limit) when is_integer(limit) and limit >= 0 do
    Enum.take(records, limit)
  end

  defp limit_eval_logs(records, _limit), do: records

  defp interrupt_running_records(error, now) do
    @runs_table
    |> all_records()
    |> Enum.reduce(0, &interrupt_running_record(&1, error, now, &2))
  end

  defp interrupt_running_record(%{status: "running"} = record, error, now, count) do
    write_interrupted_run_record(record, error, now, count)
  end

  defp interrupt_running_record(_record, _error, _now, count), do: count

  defp write_interrupted_run_record(record, error, now, count) do
    case Map.get(record, :run_id) do
      run_id when is_binary(run_id) ->
        updated =
          Map.merge(record, %{
            status: "failure",
            ended_at: now,
            error: error,
            updated_at: now
          })

        :mnesia.write({@runs_table, run_id, updated})
        count + 1

      malformed_run_id ->
        Logger.warning("Skipping malformed running run store record during startup recovery run_id=#{inspect(malformed_run_id)}")
        count
    end
  end

  defp datetime_sort_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp datetime_sort_key(_datetime), do: 0

  defp unwrap_nested_error({:error, reason}), do: {:error, reason}
  defp unwrap_nested_error(other), do: other

  @impl true
  def terminate(reason, %State{dir: dir}) do
    if reason not in [:normal, :shutdown] do
      Logger.warning("RunStore stopped unexpectedly dir=#{dir} reason=#{inspect(reason)}")
    end

    :ok
  end
end
