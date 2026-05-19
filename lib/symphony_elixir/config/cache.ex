defmodule SymphonyElixir.Config.Cache do
  @moduledoc """
  Caches parsed `symphony.yml` and repo `WORKFLOW.md` files.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Workflow

  @index_key {__MODULE__, :index}
  @stale_option [stale: true]

  defmodule Entry do
    @moduledoc false

    defstruct [:kind, :path, :stamp, :value, :last_error, stale?: false]
  end

  @type cache_kind :: :symphony | :workflow
  @type cache_result(value) :: {:ok, value} | {:ok, value, stale: true} | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get() :: cache_result(map())
  def get do
    get_symphony(Workflow.symphony_file_path())
  end

  @spec get_symphony(Path.t()) :: cache_result(map())
  def get_symphony(path) when is_binary(path) do
    cached(:symphony, path, &load_symphony/1)
  end

  @spec get_workflow(Path.t()) :: cache_result(Workflow.loaded_workflow())
  def get_workflow(path) when is_binary(path) do
    cached(:workflow, path, &load_workflow/1)
  end

  @spec clear() :: :ok
  def clear do
    keys = :persistent_term.get(@index_key, MapSet.new())
    Enum.each(keys, &:persistent_term.erase/1)
    :persistent_term.erase(@index_key)
    :ok
  end

  @impl true
  def init(_opts) do
    {:ok, %{watchers: %{}}}
  end

  @impl true
  def handle_cast({:watch, path}, state) do
    {:noreply, watch_path(state, path)}
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, events}}, state) when is_binary(path) and is_list(events) do
    if reload_event?(events) do
      path
      |> Path.expand()
      |> reload_path()
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, :stop}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp cached(kind, path, loader) do
    path = Path.expand(path)
    key = cache_key(kind, path)
    watch(path)

    case :persistent_term.get(key, nil) do
      %Entry{} = entry -> refresh_entry(entry, loader)
      nil -> load_entry(kind, path, loader)
    end
  end

  defp refresh_entry(%Entry{} = entry, loader) do
    case current_stamp(entry.path) do
      {:ok, stamp} when stamp == entry.stamp ->
        entry_result(entry)

      {:ok, stamp} ->
        load_entry(entry.kind, entry.path, loader, entry, stamp)

      {:error, reason} ->
        stale_entry(entry, {:missing_file, reason})
    end
  end

  defp load_entry(kind, path, loader, previous \\ nil, known_stamp \\ nil) do
    with {:ok, stamp} <- stamp_for(path, known_stamp),
         {:ok, value} <- loader.(path) do
      entry = %Entry{kind: kind, path: path, stamp: stamp, value: value}
      put_entry(entry)
      {:ok, value}
    else
      {:error, reason} ->
        case previous do
          %Entry{} = entry -> stale_entry(entry, reason)
          nil -> {:error, normalize_missing_reason(kind, path, reason)}
        end
    end
  end

  defp stamp_for(_path, stamp) when is_tuple(stamp), do: {:ok, stamp}
  defp stamp_for(path, _stamp), do: current_stamp(path)

  defp stale_entry(%Entry{} = entry, reason) do
    stale = %{entry | stale?: true, last_error: reason}
    put_entry(stale)
    Logger.warning("Failed to reload config path=#{entry.path} reason=#{inspect(reason)}; keeping last known good value")
    {:ok, stale.value, @stale_option}
  end

  defp entry_result(%Entry{stale?: true, value: value}), do: {:ok, value, @stale_option}
  defp entry_result(%Entry{value: value}), do: {:ok, value}

  defp put_entry(%Entry{} = entry) do
    key = cache_key(entry.kind, entry.path)
    :persistent_term.put(key, entry)
    index_key(key)
    :ok
  end

  defp index_key(key) do
    keys = :persistent_term.get(@index_key, MapSet.new())
    :persistent_term.put(@index_key, MapSet.put(keys, key))
  end

  defp reload_path(path) do
    keys = :persistent_term.get(@index_key, MapSet.new())

    Enum.each(keys, fn key ->
      case :persistent_term.get(key, nil) do
        %Entry{path: ^path, kind: :symphony} = entry -> refresh_entry(entry, &load_symphony/1)
        %Entry{path: ^path, kind: :workflow} = entry -> refresh_entry(entry, &load_workflow/1)
        _entry -> :ok
      end
    end)
  end

  defp cache_key(kind, path), do: {__MODULE__, kind, path}

  defp current_stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> {:ok, {stat.mtime, stat.size, stat.type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_symphony(path) do
    with {:ok, content} <- read_file(path),
         do: Workflow.parse_symphony(content)
  end

  defp load_workflow(path) do
    with {:ok, content} <- read_file(path),
         do: Workflow.parse_repo_workflow(content)
  end

  defp read_file(path) do
    case Application.get_env(:symphony_elixir, :config_cache_file_reader) do
      reader when is_function(reader, 1) -> reader.(path)
      _reader -> File.read(path)
    end
  end

  defp normalize_missing_reason(:symphony, path, reason), do: normalize_missing_reason(reason, {:missing_symphony_file, path, reason})
  defp normalize_missing_reason(:workflow, path, reason), do: normalize_missing_reason(reason, {:missing_workflow_file, path, reason})

  defp normalize_missing_reason(reason, missing_reason) when reason in [:enoent, :enotdir, :eacces], do: missing_reason
  defp normalize_missing_reason(reason, _missing_reason), do: reason

  defp watch(path) do
    if Application.get_env(:symphony_elixir, :config_cache_watch, true) do
      case Process.whereis(__MODULE__) do
        pid when is_pid(pid) -> GenServer.cast(pid, {:watch, path})
        _pid -> :ok
      end
    else
      :ok
    end
  end

  defp watch_path(state, path) do
    dir = Path.dirname(path)

    cond do
      Map.has_key?(state.watchers, dir) ->
        state

      Code.ensure_loaded?(FileSystem) and File.dir?(dir) ->
        case FileSystem.start_link(dirs: [dir]) do
          {:ok, watcher} ->
            :ok = FileSystem.subscribe(watcher)
            %{state | watchers: Map.put(state.watchers, dir, watcher)}

          {:error, reason} ->
            Logger.warning("Failed to watch config directory=#{dir} reason=#{inspect(reason)}")
            state
        end

      true ->
        state
    end
  end

  defp reload_event?(events) do
    Enum.any?(events, &(&1 in [:modified, :renamed, :created, :removed, :deleted]))
  end
end
