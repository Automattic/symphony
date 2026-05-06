defmodule Mix.Tasks.Symphony.Resume do
  @moduledoc """
  Resume orchestrator dispatch through the running Symphony node.
  """

  use Mix.Task

  @shortdoc "Resume Symphony dispatch"

  @impl Mix.Task
  def run([]) do
    case control_client().resume_dispatch() do
      {:ok, %{paused: false}} ->
        Mix.shell().info("Dispatch resumed")

      {:ok, %{paused: true} = pause} ->
        Mix.shell().info("Dispatch remains paused: #{pause.reason || "no reason provided"}")

      :unavailable ->
        Mix.raise("Orchestrator unavailable")

      {:error, reason} ->
        Mix.raise("Resume failed: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix symphony.resume")
  end

  defp control_client do
    Application.get_env(:symphony_elixir, :control_client, SymphonyElixir.ControlClient)
  end
end
