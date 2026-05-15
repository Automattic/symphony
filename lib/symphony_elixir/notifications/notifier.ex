defmodule SymphonyElixir.Notifications.Notifier do
  @moduledoc false

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Notifications
  alias SymphonyElixir.Notifications.Channels.{Slack, Webhook}
  alias SymphonyElixir.Notifications.Event

  @max_attempts 3
  @base_retry_ms 1_000

  defstruct opts: []

  @type t :: %__MODULE__{opts: keyword()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    case Notifications.subscribe() do
      :ok ->
        {:ok, %__MODULE__{opts: opts}}

      {:error, reason} ->
        Logger.warning("Notification notifier failed to subscribe: #{inspect(reason)}")
        {:ok, %__MODULE__{opts: opts}}
    end
  end

  @impl true
  def handle_info({:notification_event, %Event{} = event}, %__MODULE__{} = state) do
    deliver_from_config(event, state.opts)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec deliver_for_test(Event.t(), map(), keyword()) :: :ok
  def deliver_for_test(%Event{} = event, notifications, opts \\ []) when is_map(notifications) do
    deliver_event(event, notifications, opts)
  end

  defp deliver_from_config(event, opts) do
    case Config.settings() do
      {:ok, settings} ->
        deliver_event(event, settings.notifications, opts)

      {:error, reason} ->
        Logger.warning("Skipping notification delivery; config unavailable: #{inspect(reason)}")
        :ok
    end
  end

  defp deliver_event(%Event{} = event, %{enabled: true, channels: channels} = notifications, opts)
       when is_list(channels) do
    redact_titles = Map.get(notifications, :redact_titles, false)

    channels
    |> Enum.filter(&deliver_to_channel?(&1, event))
    |> Enum.each(fn channel ->
      start_delivery_task(
        fn ->
          deliver_channel_with_retry(channel, event, 1, redact_titles, opts)
        end,
        opts
      )
    end)

    :ok
  end

  defp deliver_event(_event, _notifications, _opts), do: :ok

  defp deliver_to_channel?(%{events: nil}, _event), do: true

  defp deliver_to_channel?(%{events: events}, %Event{event: event_name}) when is_list(events) do
    event_name in Enum.map(events, &to_string/1)
  end

  defp deliver_to_channel?(_channel, _event), do: true

  defp start_delivery_task(fun, opts) when is_function(fun, 0) do
    task_starter =
      Keyword.get(opts, :task_starter, fn task_fun ->
        Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, task_fun)
      end)

    case task_starter.(fun) do
      {:ok, _pid} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Unable to start notification delivery task: #{inspect(reason)}")
        :ok

      other ->
        Logger.warning("Unexpected notification delivery task result: #{inspect(other)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning("Unable to start notification delivery task: #{Exception.message(exception)}")
      :ok
  end

  defp deliver_channel_with_retry(channel, event, attempt, redact_titles, opts) do
    opts = Keyword.put(opts, :redact_titles, redact_titles)

    case deliver_channel(channel, event, opts) do
      :ok ->
        :ok

      {:retry, retry_after_ms} ->
        retry_or_drop(channel, event, attempt, retry_after_ms, {:retry_after, retry_after_ms}, redact_titles, opts)

      {:error, reason} ->
        retry_or_drop(channel, event, attempt, retry_delay(attempt), reason, redact_titles, opts)
    end
  end

  defp retry_or_drop(channel, event, attempt, delay_ms, reason, redact_titles, opts) do
    if attempt < @max_attempts do
      sleep(delay_ms, opts)
      deliver_channel_with_retry(channel, event, attempt + 1, redact_titles, opts)
    else
      Logger.warning("Dropping notification after #{attempt} attempts event=#{event.event} channel=#{channel_kind(channel)} reason=#{inspect(reason)}")

      :ok
    end
  end

  defp deliver_channel(%{kind: "slack"} = channel, event, opts), do: Slack.deliver(channel, event, opts)
  defp deliver_channel(%{kind: "webhook"} = channel, event, opts), do: Webhook.deliver(channel, event, opts)
  defp deliver_channel(channel, _event, _opts), do: {:error, {:unsupported_channel, channel_kind(channel)}}

  defp retry_delay(attempt) when is_integer(attempt) and attempt > 0 do
    @base_retry_ms * Integer.pow(2, attempt - 1)
  end

  defp retry_delay(_attempt), do: @base_retry_ms

  defp sleep(delay_ms, opts) do
    sleep_fun = Keyword.get(opts, :sleep_fun, &Process.sleep/1)
    sleep_fun.(max(delay_ms, 0))
  end

  defp channel_kind(%{kind: kind}), do: kind
  defp channel_kind(_channel), do: "unknown"
end
