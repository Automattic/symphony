defmodule Mix.Tasks.Symphony.Pause do
  @moduledoc """
  Pause orchestrator dispatch through the running Symphony node.
  """

  use Mix.Task

  @shortdoc "Pause Symphony dispatch"

  @impl Mix.Task
  def run([reason]) when is_binary(reason) do
    case control_client().pause_dispatch(reason) do
      {:ok, %{paused: true} = pause} ->
        Mix.shell().info(pause_message(reason, pause))

      {:ok, %{paused: false}} ->
        Mix.shell().info("Dispatch is not paused")

      :unavailable ->
        Mix.raise("Orchestrator unavailable")

      {:error, reason} ->
        Mix.raise("Pause failed: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise(~s(Usage: mix symphony.pause "<reason>"))
  end

  defp control_client do
    Application.get_env(:symphony_elixir, :control_client, SymphonyElixir.ControlClient)
  end

  defp pause_message(requested_reason, pause) do
    persisted_reason = Map.get(pause, :reason)

    if normalize_reason(requested_reason) == persisted_reason do
      "Dispatch paused: #{persisted_reason || "no reason provided"}"
    else
      "Dispatch already paused: #{persisted_reason || "no reason provided"}; requested reason ignored"
    end
  end

  defp normalize_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
