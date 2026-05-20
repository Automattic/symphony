defmodule Mix.Tasks.Symphony.Init do
  @moduledoc """
  Scaffolds a minimal operator `symphony.yml`.
  """

  use Mix.Task

  @shortdoc "Scaffold symphony.yml"

  @impl Mix.Task
  def run(args) do
    case SymphonyElixir.Init.run(args) do
      {:ok, message} -> Mix.shell().info(message)
      {:error, message} -> Mix.raise(message)
    end
  end
end
