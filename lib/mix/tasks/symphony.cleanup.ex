defmodule Mix.Tasks.Symphony.Cleanup do
  @moduledoc """
  Print a read-only Symphony storage inventory for cleanup planning.
  """

  use Mix.Task

  alias SymphonyElixir.{Paths, StorageInventory, Workflow}

  @shortdoc "Dry-run Symphony storage cleanup inventory"
  @switches [
    apply: :boolean,
    config: :string,
    dry_run: :boolean,
    logs_root: :string,
    state_root: :string,
    temp_root: :string,
    workspace_root: :string
  ]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        run_with_opts(opts)

      _ ->
        Mix.raise(usage())
    end
  end

  defp run_with_opts(opts) do
    cond do
      Keyword.get(opts, :apply, false) ->
        Mix.raise("--apply is not supported yet; this task is inventory-only. Re-run with --dry-run.")

      Keyword.get(opts, :dry_run, false) ->
        configure_roots(opts)

        opts
        |> inventory_opts()
        |> StorageInventory.inventory()
        |> StorageInventory.format()
        |> Mix.shell().info()

      true ->
        Mix.raise(usage())
    end
  end

  defp configure_roots(opts) do
    with_last_opt(opts, :config, fn path ->
      :ok = Workflow.set_symphony_file_path(Path.expand(path))
    end)

    with_last_opt(opts, :state_root, fn path ->
      :ok = Paths.set_state_root(Path.expand(path))
    end)

    with_last_opt(opts, :logs_root, fn path ->
      :ok = Paths.set_logs_root(Path.expand(path))
    end)
  end

  defp inventory_opts(opts) do
    root_opts =
      [:state_root, :logs_root, :workspace_root]
      |> Enum.flat_map(fn key ->
        case Keyword.get_values(opts, key) do
          [] -> []
          values -> [{key, values |> List.last() |> Path.expand()}]
        end
      end)

    case Keyword.get_values(opts, :temp_root) do
      [] -> root_opts
      temp_roots -> Keyword.put(root_opts, :temp_roots, Enum.map(temp_roots, &Path.expand/1))
    end
  end

  defp with_last_opt(opts, key, fun) do
    case Keyword.get_values(opts, key) do
      [] -> :ok
      values -> fun.(List.last(values))
    end
  end

  defp usage do
    "Usage: mix symphony.cleanup --dry-run [--config PATH] [--state-root PATH] [--logs-root PATH] [--workspace-root PATH] [--temp-root PATH]"
  end
end
