defmodule Mix.Tasks.Symphony.Stop do
  @moduledoc """
  Stop a running issue through the running Symphony node.
  """

  use Mix.Task

  @shortdoc "Stop a running Symphony issue"

  @impl Mix.Task
  def run([issue_id_or_identifier]) when is_binary(issue_id_or_identifier) do
    case control_client().stop_running(issue_id_or_identifier) do
      {:ok, %{stopped: true} = result} ->
        Mix.shell().info("Stopped running issue: #{result.issue_identifier || result.issue_id}")

      {:ok, %{stopped: false}} ->
        Mix.shell().info("No running issue matched #{issue_id_or_identifier}")

      :unavailable ->
        Mix.raise("Orchestrator unavailable")

      {:error, reason} ->
        Mix.raise("Stop failed: #{inspect(reason)}")
    end
  end

  def run(_args) do
    Mix.raise("Usage: mix symphony.stop <issue_identifier>")
  end

  defp control_client do
    Application.get_env(:symphony_elixir, :control_client, SymphonyElixir.ControlClient)
  end
end
