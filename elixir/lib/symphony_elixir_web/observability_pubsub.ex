defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  require Logger

  alias SymphonyElixir.Config

  @pubsub SymphonyElixir.PubSub
  @dashboard_topic "observability:dashboard"
  @transcript_topic "observability:transcript"
  @update_message :observability_updated

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @dashboard_topic)
  end

  @spec broadcast_update(String.t() | nil) :: :ok
  def broadcast_update(repo_key \\ nil) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, @dashboard_topic, {@update_message, %{repo_key: repo_key(repo_key)}})

      _ ->
        :ok
    end
  end

  @spec subscribe_transcript(String.t()) :: :ok | {:error, term()}
  def subscribe_transcript(issue_id) when is_binary(issue_id) do
    subscribe_transcript(repo_key(nil), issue_id)
  end

  @spec subscribe_transcript(String.t() | nil, String.t()) :: :ok | {:error, term()}
  def subscribe_transcript(_repo_key, issue_id) when is_binary(issue_id) do
    Phoenix.PubSub.subscribe(@pubsub, transcript_topic())
  end

  @spec broadcast_transcript_event(String.t(), map()) :: :ok
  def broadcast_transcript_event(issue_id, event) when is_binary(issue_id) and is_map(event) do
    broadcast_transcript_event(repo_key(nil), issue_id, event)
  end

  def broadcast_transcript_event(_issue_id, _event), do: :ok

  @spec broadcast_transcript_event(String.t() | nil, String.t(), map()) :: :ok
  def broadcast_transcript_event(repo_key, issue_id, event)
      when is_binary(issue_id) and is_map(event) do
    event = event |> Map.put(:repo_key, repo_key(repo_key)) |> Map.put(:issue_id, issue_id)

    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        case Phoenix.PubSub.broadcast(@pubsub, transcript_topic(), {:transcript_event, event}) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("failed to broadcast transcript event: #{inspect(reason)}")
            :ok
        end

      _ ->
        :ok
    end
  end

  def broadcast_transcript_event(_repo_key, _issue_id, _event), do: :ok

  @spec transcript_topic() :: String.t()
  def transcript_topic, do: @transcript_topic

  @spec transcript_topic(String.t()) :: String.t()
  def transcript_topic(_issue_id), do: transcript_topic()

  defp repo_key(repo_key) when is_binary(repo_key) do
    case String.trim(repo_key) do
      "" -> default_repo_key()
      trimmed -> trimmed
    end
  end

  defp repo_key(_repo_key), do: default_repo_key()

  defp default_repo_key do
    case Config.repo_key() do
      {:ok, repo_key} -> repo_key
      {:error, _reason} -> nil
    end
  end
end
