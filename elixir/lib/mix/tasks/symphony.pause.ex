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
        Mix.shell().info("Dispatch paused: #{pause.reason || "no reason provided"}")

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
end
