defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an operator `symphony.yml`.
  """

  alias SymphonyElixir.{AuditLog, LogFile}

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, config: :string, host: :string, logs_root: :string, port: :integer]
  @default_symphony_file "symphony.yml"

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_symphony_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_host_override: (String.t() | nil -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          ensure_all_started: (-> ensure_started_result())
        }

  @spec main([String.t()]) :: no_return()
  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- set_symphony_config(opts, deps),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_host(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          start_runtime(deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp start_runtime(deps) do
    case deps.ensure_all_started.() do
      {:ok, _started_apps} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to start Symphony: #{inspect(reason)}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    "Usage: symphony [--config <path-to-symphony.yml>] [--logs-root <path>] [--host <host>] [--port <port>]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_symphony_file_path: &SymphonyElixir.Workflow.set_symphony_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_host_override: &set_server_host_override/1,
      set_server_port_override: &set_server_port_override/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end
    }
  end

  defp set_symphony_config(opts, deps) do
    raw = opts |> Keyword.get_values(:config) |> List.last() || @default_symphony_file
    path = Path.expand(raw)

    if deps.file_regular?.(path) do
      :ok = deps.set_symphony_file_path.(path)
    else
      {:error, "Symphony config file not found: #{path}"}
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    with_last_opt(opts, :logs_root, fn raw ->
      logs_root = String.trim(raw)

      if logs_root == "" do
        {:error, usage_message()}
      else
        :ok = deps.set_logs_root.(Path.expand(logs_root))
      end
    end)
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    AuditLog.set_dir(AuditLog.default_dir(logs_root))
    :ok
  end

  defp maybe_set_server_host(opts, deps) do
    with_last_opt(opts, :host, fn raw ->
      host = String.trim(raw)

      if host == "" do
        {:error, usage_message()}
      else
        :ok = deps.set_server_host_override.(host)
      end
    end)
  end

  defp maybe_set_server_port(opts, deps) do
    with_last_opt(opts, :port, fn port ->
      if is_integer(port) and port >= 0 do
        :ok = deps.set_server_port_override.(port)
      else
        {:error, usage_message()}
      end
    end)
  end

  defp with_last_opt(opts, key, fun) do
    case Keyword.get_values(opts, key) do
      [] -> :ok
      values -> fun.(List.last(values))
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  defp set_server_host_override(host) when is_binary(host) do
    Application.put_env(:symphony_elixir, :server_host_override, host)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
