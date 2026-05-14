defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an operator `symphony.yml`.
  """

  alias SymphonyElixir.Paths

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @burrito_args_module Burrito.Util.Args
  @switches [
    {@acknowledgement_switch, :boolean},
    config: :string,
    host: :string,
    logs_root: :string,
    port: :integer,
    state_root: :string
  ]
  @default_symphony_file "symphony.yml"

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_symphony_file_path: (String.t() -> :ok | {:error, term()}),
          set_state_root: (String.t() -> :ok | {:error, term()}),
          set_state_root_from_env: (-> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_logs_root_from_env: (-> :ok | {:error, term()}),
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
    with :ok <- configure(args, deps) do
      start_runtime(deps)
    end
  end

  @spec configure([String.t()], deps()) :: :ok | {:error, String.t()}
  def configure(args, deps \\ runtime_deps()) do
    with :ok <- deps.set_state_root_from_env.(),
         :ok <- deps.set_logs_root_from_env.() do
      parse_and_configure(args, deps)
    end
  end

  @spec maybe_configure_burrito_runtime() :: :ok
  def maybe_configure_burrito_runtime do
    case burrito_args() do
      :not_in_burrito ->
        :ok

      args ->
        case configure(args) do
          :ok ->
            :ok

          {:error, message} ->
            IO.puts(:stderr, message)
            System.halt(1)
        end
    end
  end

  defp parse_and_configure(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- set_symphony_config(opts, deps),
             :ok <- maybe_set_state_root(opts, deps),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_host(opts, deps) do
          maybe_set_server_port(opts, deps)
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
    "Usage: symphony [--config <path-to-symphony.yml>] [--state-root <path>] [--logs-root <path>] [--host <host>] [--port <port>]"
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_symphony_file_path: &SymphonyElixir.Workflow.set_symphony_file_path/1,
      set_state_root: &set_state_root/1,
      set_state_root_from_env: &Paths.set_state_root_from_env/0,
      set_logs_root: &set_logs_root/1,
      set_logs_root_from_env: &Paths.set_logs_root_from_env/0,
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

  defp maybe_set_state_root(opts, deps),
    do: maybe_set_root(opts, :state_root, deps.set_state_root)

  defp maybe_set_logs_root(opts, deps),
    do: maybe_set_root(opts, :logs_root, deps.set_logs_root)

  defp maybe_set_root(opts, key, setter) do
    with_last_opt(opts, key, fn raw ->
      case String.trim(raw) do
        "" -> {:error, usage_message()}
        root -> :ok = setter.(Path.expand(root))
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
      "Codex and Claude will run without the usual guardrails.",
      "Agents can access provider runtime config files:",
      "  ~/.codex/auth.json",
      "  ~/.claude/.credentials.json",
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
    Paths.set_logs_root(logs_root)
  end

  defp set_state_root(state_root) do
    Paths.set_state_root(state_root)
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

  defp burrito_args do
    if Code.ensure_loaded?(@burrito_args_module) and burrito_binary?() do
      call_burrito_args(:argv)
    else
      :not_in_burrito
    end
  end

  defp burrito_binary? do
    call_burrito_args(:get_bin_path) != :not_in_burrito
  end

  defp call_burrito_args(function) do
    # The Burrito module is only present in prod releases, so this call must stay dynamic.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(@burrito_args_module, function, [])
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
