defmodule Mix.Tasks.Symphony.Init do
  @moduledoc """
  Scaffold a starter WORKFLOW.md and symphony.yml in the current directory.
  """

  use Mix.Task

  alias SymphonyElixir.Init

  @shortdoc "Scaffold a starter Symphony config"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    case Init.run(args) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end
  end
end
