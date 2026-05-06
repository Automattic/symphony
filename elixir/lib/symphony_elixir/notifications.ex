defmodule SymphonyElixir.Notifications do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Notifications.Event

  @pubsub SymphonyElixir.PubSub
  @topic "notifications:events"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec emit_event(atom() | String.t(), map() | keyword()) :: :ok
  def emit_event(event, attrs \\ %{}) do
    case Event.new(event, attrs) do
      {:ok, event} ->
        broadcast_event(event)

      {:error, reason} ->
        Logger.debug("Skipping notification event: #{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning("Failed to emit notification event: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Failed to emit notification event: #{inspect({kind, reason})}")
      :ok
  end

  @spec emit_issue_event(atom() | String.t(), term()) :: :ok
  def emit_issue_event(event, issue), do: emit_issue_event(event, issue, %{})

  @spec emit_issue_event(atom() | String.t(), term(), map() | keyword()) :: :ok
  def emit_issue_event(event, %Issue{} = issue, attrs) do
    case Event.from_issue(event, issue, attrs) do
      {:ok, event} ->
        broadcast_event(event)

      {:error, reason} ->
        Logger.debug("Skipping notification event: #{inspect(reason)}")
        :ok
    end
  rescue
    exception ->
      Logger.warning("Failed to emit notification event: #{Exception.message(exception)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("Failed to emit notification event: #{inspect({kind, reason})}")
      :ok
  end

  def emit_issue_event(event, _issue, attrs), do: emit_event(event, attrs)

  @doc false
  @spec topic_for_test() :: String.t()
  def topic_for_test, do: @topic

  defp broadcast_event(%Event{} = event) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        case Phoenix.PubSub.broadcast(@pubsub, @topic, {:notification_event, event}) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("failed to broadcast notification event: #{inspect(reason)}")
            :ok
        end

      _ ->
        :ok
    end
  end
end
