defmodule SymphonyElixir.Init do
  @moduledoc """
  Scaffolds a minimal operator `symphony.yml`.
  """

  alias SymphonyElixir.Config.SystemSchema

  @symphony_file "symphony.yml"
  @switches [force: :boolean]
  @aliases [f: :force]
  @usage "Usage: symphony init [--force]"
  @scaffold """
  tracker:
    kind: linear
  workspace:
    root: .symphony/workspaces
  agent:
    kind: codex
    command: codex app-server
  repos:
    - name: default
      workflow: WORKFLOW.md
  """

  @type result :: {:ok, String.t()} | {:error, String.t()}

  @spec run([String.t()]) :: result()
  def run(args), do: run(args, cwd: File.cwd!())

  @spec run([String.t()], keyword()) :: result()
  def run(args, opts) do
    with {:ok, parsed_opts} <- parse_args(args),
         :ok <- validate_scaffold(@scaffold) do
      cwd = Keyword.fetch!(opts, :cwd)
      path = Path.join(cwd, @symphony_file)
      write_scaffold(path, @scaffold, Keyword.get(parsed_opts, :force, false))
    end
  end

  @spec scaffold() :: String.t()
  def scaffold, do: @scaffold

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, [], []} -> {:ok, opts}
      _ -> {:error, @usage}
    end
  end

  defp validate_scaffold(content) do
    with {:ok, config} <- YamlElixir.read_from_string(content),
         {:ok, _system_config} <- SystemSchema.parse(config) do
      :ok
    else
      {:error, {:invalid_symphony_config, message}} ->
        {:error, "Generated symphony.yml failed schema validation: #{message}"}

      {:error, reason} ->
        {:error, "Generated symphony.yml failed schema validation: #{inspect(reason)}"}
    end
  end

  defp write_scaffold(path, content, force?) do
    if File.regular?(path) and not force? do
      existing = File.read!(path)
      {:error, conflict_message(path, existing, content)}
    else
      case File.write(path, content) do
        :ok -> {:ok, "Wrote #{path}"}
        {:error, reason} -> {:error, "Failed to write #{path}: #{inspect(reason)}"}
      end
    end
  end

  defp conflict_message(path, existing, generated) do
    """
    #{path} already exists. Use `symphony init --force` to overwrite it.

    Diff:
    #{diff(existing, generated)}\
    """
  end

  defp diff(existing, generated) do
    existing_lines = String.split(existing, "\n", trim: false)
    generated_lines = String.split(generated, "\n", trim: false)

    body =
      existing_lines
      |> List.myers_difference(generated_lines)
      |> Enum.flat_map(&format_diff_chunk/1)
      |> Enum.join("\n")

    """
    --- symphony.yml
    +++ symphony.yml (generated)
    #{body}
    """
  end

  defp format_diff_chunk({:eq, lines}), do: Enum.map(lines, &" #{&1}")
  defp format_diff_chunk({:del, lines}), do: Enum.map(lines, &"-#{&1}")
  defp format_diff_chunk({:ins, lines}), do: Enum.map(lines, &"+#{&1}")
end
