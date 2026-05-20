defmodule Mix.Tasks.Symphony.Pr do
  @moduledoc """
  Dispatch an explicit PR-shaped Symphony run through the running node.
  """

  use Mix.Task

  @shortdoc "Run Symphony on an existing pull request"
  @switches [intent: :string]

  @impl Mix.Task
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [target], []} ->
        dispatch(target, opts)

      _ ->
        Mix.raise(~s(Usage: mix symphony.pr <url-or-number> [--intent "address review comments"]))
    end
  end

  defp dispatch(target, opts) do
    pr_opts =
      opts
      |> Keyword.take([:intent])
      |> Enum.reject(fn {_key, value} -> is_nil(value) or String.trim(value) == "" end)

    case control_client().dispatch_pr(target, pr_opts) do
      {:ok, result} ->
        Mix.shell().info("Dispatched PR run: #{Map.get(result, :pull_request_url) || target}")

      :unavailable ->
        Mix.raise("Orchestrator unavailable")

      {:error, reason} ->
        Mix.raise("PR dispatch failed: #{inspect(reason)}")
    end
  end

  defp control_client do
    Application.get_env(:symphony_elixir, :control_client, SymphonyElixir.ControlClient)
  end
end
