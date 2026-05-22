defmodule SymphonyElixir.StorageInventory do
  @moduledoc """
  Read-only storage usage inventory for Symphony operator cleanup planning.
  """

  alias SymphonyElixir.{Config, Paths}

  @app :symphony_elixir
  @temp_roots_override_key :storage_inventory_temp_roots_override
  @temp_globs [
    {"mcp_socket_dirs", "symphony-mcp-*"},
    {"codex_homes", "symphony-codex-home-*"},
    {"claude_settings", "symphony-claude-settings-*"},
    {"claude_prompts", "symphony-claude-prompt*"},
    {"srt_settings", "symphony-srt-*"}
  ]

  @type usage_status :: :ok | :missing | :partial | :unreadable
  @type usage :: %{
          bytes: non_neg_integer(),
          dirs: non_neg_integer(),
          errors: [map()],
          files: non_neg_integer(),
          path: Path.t(),
          status: usage_status()
        }
  @type audit_day :: %{
          date: String.t(),
          path: Path.t(),
          usage: usage()
        }
  @type report :: %{
          audit_days: [audit_day()],
          audit_root: usage(),
          core_dirs: [map()],
          roots: map(),
          temp_groups: [map()],
          usage: map()
        }

  @spec inventory(keyword()) :: report()
  def inventory(opts \\ []) when is_list(opts) do
    state_root = expanded_opt(opts, :state_root, Paths.state_root())
    logs_root = expanded_opt(opts, :logs_root, Paths.logs_root())
    workspace_root = workspace_root(opts)
    run_store = Path.join(state_root, "run_store")
    audit_root = Path.join(state_root, "audit")
    audit_usage = path_usage(audit_root)

    %{
      roots: %{
        state_root: state_root,
        logs_root: logs_root,
        workspace_root: workspace_root
      },
      usage: %{
        app_logs: path_usage(logs_root),
        audit: audit_usage,
        run_store: path_usage(run_store),
        workspace_root: path_usage(workspace_root)
      },
      audit_root: audit_usage,
      audit_days: audit_days(audit_root),
      core_dirs: [
        %{
          label: "run_store_core_dumps",
          usage: path_usage(Path.join(run_store, "core_dumps"))
        }
      ],
      temp_groups: temp_groups(Keyword.get(opts, :temp_roots, default_temp_roots()))
    }
  end

  @spec format(report()) :: String.t()
  def format(report) when is_map(report) do
    [
      "Symphony cleanup dry-run",
      "",
      "No files were deleted. This command is inventory-only; audit logs are not deleted automatically.",
      "",
      "Roots:",
      "  state_root: #{report.roots.state_root}",
      "  logs_root: #{report.roots.logs_root}",
      "  workspace_root: #{report.roots.workspace_root}",
      "",
      "Usage:",
      format_usage("app_logs", report.usage.app_logs),
      format_usage("audit", report.usage.audit),
      format_usage("run_store", report.usage.run_store),
      format_usage("workspace_root", report.usage.workspace_root),
      "",
      "Audit usage by date:",
      format_audit_days(report.audit_days),
      "",
      "Known temp/core directories:",
      format_core_dirs(report.core_dirs),
      format_temp_groups(report.temp_groups)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec path_usage(Path.t()) :: usage()
  def path_usage(path) when is_binary(path) do
    expanded_path = Path.expand(path)

    expanded_path
    |> scan_existing(empty_usage(expanded_path, :ok))
    |> normalize_usage(expanded_path)
  end

  defp expanded_opt(opts, key, default) do
    opts
    |> Keyword.get(key, default)
    |> Path.expand()
  end

  defp workspace_root(opts) do
    case Keyword.get(opts, :workspace_root) do
      nil -> Path.expand(Config.settings!().workspace.root)
      root -> Path.expand(root)
    end
  end

  defp scan_existing(path, acc) when is_binary(path), do: scan_existing([path], acc)

  defp scan_existing([], acc) do
    status = if acc.errors == [], do: :ok, else: :partial
    %{acc | status: status, errors: Enum.reverse(acc.errors)}
  end

  defp scan_existing([path | rest], acc) do
    case File.lstat(path) do
      {:ok, %{type: :directory, size: size}} ->
        acc = %{acc | bytes: acc.bytes + size, dirs: acc.dirs + 1}

        case File.ls(path) do
          {:ok, names} ->
            children = Enum.map(names, &Path.join(path, &1))
            scan_existing(children ++ rest, acc)

          {:error, reason} ->
            scan_existing(rest, add_error(acc, path, reason))
        end

      {:ok, %{size: size}} ->
        scan_existing(rest, %{acc | bytes: acc.bytes + size, files: acc.files + 1})

      {:error, reason} ->
        scan_existing(rest, add_error(acc, path, reason))
    end
  end

  defp audit_days(audit_root) do
    audit_root
    |> Path.join("*.ndjson")
    |> Path.wildcard()
    |> Enum.flat_map(&audit_day/1)
    |> Enum.sort_by(& &1.date)
  end

  defp audit_day(path) do
    basename = Path.basename(path, ".ndjson")

    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, basename) do
      [%{date: basename, path: path, usage: path_usage(path)}]
    else
      []
    end
  end

  defp temp_groups(temp_roots) do
    temp_roots =
      temp_roots
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()

    for {label, glob} <- @temp_globs do
      matches =
        temp_roots
        |> Enum.flat_map(fn root -> Path.wildcard(Path.join(root, glob)) end)
        |> Enum.uniq()
        |> Enum.sort()

      entries = Enum.map(matches, fn path -> %{path: path, usage: path_usage(path)} end)

      %{
        label: label,
        glob: glob,
        entries: entries,
        matches: matches,
        usage: sum_usages(Enum.map(entries, & &1.usage))
      }
    end
  end

  defp sum_usages(usages) do
    errors = Enum.flat_map(usages, & &1.errors)

    Enum.reduce(usages, empty_usage("", :ok), fn usage, acc ->
      %{
        acc
        | bytes: acc.bytes + usage.bytes,
          dirs: acc.dirs + usage.dirs,
          files: acc.files + usage.files
      }
    end)
    |> Map.merge(%{errors: errors, status: sum_status(usages)})
  end

  defp normalize_usage(%{errors: [%{path: path, reason: :enoent}], bytes: 0, dirs: 0, files: 0}, path),
    do: empty_usage(path, :missing)

  defp normalize_usage(%{errors: [%{path: path, reason: reason}], bytes: 0, dirs: 0, files: 0}, path),
    do: %{empty_usage(path, :unreadable) | errors: [%{path: path, reason: reason}]}

  defp normalize_usage(usage, path), do: %{usage | path: path}

  defp sum_status(usages) do
    if Enum.any?(usages, &(&1.status != :ok)), do: :partial, else: :ok
  end

  defp default_temp_roots do
    Application.get_env(@app, @temp_roots_override_key, [System.tmp_dir!(), "/tmp"])
  end

  defp empty_usage(path, status) do
    %{path: path, status: status, bytes: 0, files: 0, dirs: 0, errors: []}
  end

  defp add_error(acc, path, reason) do
    %{acc | errors: [%{path: path, reason: reason} | acc.errors]}
  end

  defp format_usage(label, usage) do
    "  #{label}: #{usage.bytes} bytes (#{human_bytes(usage.bytes)}) files=#{usage.files} dirs=#{usage.dirs} status=#{usage.status} path=#{usage.path}"
  end

  defp format_audit_days([]), do: "  none found"

  defp format_audit_days(days) do
    Enum.map(days, fn %{date: date, path: path, usage: usage} ->
      "  #{date}: #{usage.bytes} bytes (#{human_bytes(usage.bytes)}) files=#{usage.files} status=#{usage.status} path=#{path}"
    end)
  end

  defp format_core_dirs(core_dirs) do
    Enum.map(core_dirs, fn %{label: label, usage: usage} ->
      format_usage(label, usage)
    end)
  end

  defp format_temp_groups(temp_groups) do
    Enum.flat_map(temp_groups, fn %{label: label, glob: glob, entries: entries, matches: matches, usage: usage} ->
      [
        "  #{label}: #{usage.bytes} bytes (#{human_bytes(usage.bytes)}) files=#{usage.files} dirs=#{usage.dirs} status=#{usage.status} matches=#{length(matches)} glob=#{glob}",
        format_temp_matches(entries)
      ]
    end)
  end

  defp format_temp_matches([]), do: []

  defp format_temp_matches(entries) do
    Enum.map(entries, fn %{usage: usage} ->
      "    #{usage.path}: #{usage.bytes} bytes (#{human_bytes(usage.bytes)}) files=#{usage.files} dirs=#{usage.dirs} status=#{usage.status}"
    end)
  end

  defp human_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp human_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KiB"
  defp human_bytes(bytes) when bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 1)} MiB"
  defp human_bytes(bytes), do: "#{Float.round(bytes / 1_073_741_824, 1)} GiB"
end
