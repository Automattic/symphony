defmodule SymphonyElixir.ClaudeCode.AppServer do
  @moduledoc false

  @behaviour SymphonyElixir.AgentBehaviour

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Agent

  @agent_runtime_env "SYMPHONY_AGENT_RUNTIME"
  @agent_runtime_env_value "1"
  @port_line_bytes 1_048_576

  @type session :: %{
          workspace: Path.t(),
          metadata: map(),
          worker_host: String.t() | nil
        }

  # --- AgentBehaviour callbacks ---

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host),
         :ok <- write_claude_settings(expanded_workspace) do
      {:ok, %{workspace: expanded_workspace, metadata: %{}, worker_host: worker_host}}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{workspace: workspace, worker_host: worker_host} = _session, prompt, _issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    settings = Config.settings!()
    command = settings.agent.command
    turn_timeout_ms = settings.agent.turn_timeout_ms

    with {:ok, prompt_file} <- write_prompt_file(prompt, workspace) do
      try do
        with {:ok, port} <- start_port(workspace, command, prompt_file, prompt, worker_host) do
          try do
            read_port_output(port, on_message, turn_timeout_ms)
          after
            safe_close_port(port)
          end
        end
      after
        File.rm(prompt_file)
      end
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  # --- Sandbox settings ---

  @doc false
  @spec build_sandbox_settings(Agent.NetworkAccess.t()) :: map()
  def build_sandbox_settings(%Agent.NetworkAccess{mode: mode} = network_access) do
    base = %{"sandbox" => %{"enabled" => true, "failIfUnavailable" => true}}

    case mode do
      "block" ->
        put_in(base, ["sandbox", "network"], %{
          "allowedDomains" => [],
          "allowManagedDomainsOnly" => true
        })

      "allowlist" ->
        effective_domains = effective_allowed_domains(network_access)

        put_in(base, ["sandbox", "network"], %{
          "allowedDomains" => effective_domains,
          "allowManagedDomainsOnly" => true
        })

      "open" ->
        base
    end
  end

  # --- Event parsing ---

  @doc false
  @spec parse_event(String.t()) ::
          {:session_started, String.t()}
          | {:notification, String.t()}
          | {:turn_completed, map()}
          | {:turn_failed, String.t()}
          | {:malformed, String.t()}
  def parse_event(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "session_id" => session_id}} ->
        {:session_started, session_id}

      {:ok, %{"type" => "assistant", "message" => message}} ->
        {:notification, summarize_assistant_message(message)}

      {:ok, %{"type" => "tool_use", "name" => name}} ->
        {:notification, "tool: #{name}"}

      {:ok, %{"type" => "result", "subtype" => "success"} = event} ->
        {:turn_completed, extract_turn_result(event)}

      {:ok, %{"type" => "result", "subtype" => "error"} = event} ->
        reason = Map.get(event, "error", "unknown error")
        {:turn_failed, reason}

      {:ok, _other} ->
        {:malformed, line}

      {:error, _reason} ->
        {:malformed, line}
    end
  end

  # --- Private helpers ---

  defp validate_workspace_cwd(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_cwd(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:invalid_workspace_cwd, :empty_remote_workspace, worker_host}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, worker_host, workspace}}

      true ->
        {:ok, workspace}
    end
  end

  defp write_claude_settings(workspace) do
    settings = Config.settings!()
    network_access = settings.agent.network_access
    sandbox_json = build_sandbox_settings(network_access)
    claude_dir = Path.join(workspace, ".claude")
    settings_path = Path.join(claude_dir, "settings.json")

    with :ok <- mkdir_claude_dir(claude_dir) do
      write_settings_file(settings_path, sandbox_json)
    end
  end

  defp mkdir_claude_dir(claude_dir) do
    case File.mkdir_p(claude_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:claude_settings_write_failed, :mkdir_p, claude_dir, reason}}
    end
  end

  defp write_settings_file(settings_path, sandbox_json) do
    case File.write(settings_path, Jason.encode!(sandbox_json, pretty: true)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:claude_settings_write_failed, :write, settings_path, reason}}
    end
  end

  defp write_prompt_file(prompt, workspace) do
    tmp_path = Path.join(workspace, ".claude_prompt_#{System.unique_integer([:positive])}.txt")

    case File.write(tmp_path, prompt) do
      :ok -> {:ok, tmp_path}
      {:error, reason} -> {:error, {:prompt_file_write_failed, reason}}
    end
  end

  defp start_port(workspace, command, _prompt_file, prompt, nil) do
    with {:ok, {executable, command_args}} <- local_command(workspace, command) do
      args = command_args ++ ["--output-format", "stream-json", "--print", prompt]

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            line: @port_line_bytes,
            args: Enum.map(args, &String.to_charlist/1),
            cd: String.to_charlist(workspace),
            env: agent_runtime_env()
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(_workspace, command, prompt_file, _prompt, worker_host) do
    with {:ok, command_words} <- command_words(command) do
      SSH.start_port(worker_host, remote_launch_command(command_words, prompt_file), line: @port_line_bytes)
    end
  end

  defp local_command(workspace, command) do
    with {:ok, [program | args]} <- command_words(command),
         {:ok, executable} <- executable_path(workspace, program) do
      {:ok, {executable, args}}
    end
  end

  defp command_words(command) when is_binary(command) do
    case String.trim(command) do
      "" ->
        {:error, :empty_agent_command}

      trimmed ->
        try do
          {:ok, OptionParser.split(trimmed)}
        rescue
          exception ->
            {:error, {:invalid_agent_command, Exception.message(exception)}}
        end
    end
  end

  defp executable_path(workspace, program) do
    cond do
      String.contains?(program, "/") ->
        path =
          case Path.type(program) do
            :absolute -> program
            _relative -> Path.expand(program, workspace)
          end

        if File.exists?(path), do: {:ok, path}, else: {:error, {:agent_command_not_found, program}}

      executable = System.find_executable(program) ->
        {:ok, executable}

      true ->
        {:error, {:agent_command_not_found, program}}
    end
  end

  defp remote_launch_command(command_words, prompt_file) do
    command =
      command_words
      |> Enum.map_join(" ", &shell_escape/1)

    "#{@agent_runtime_env}=#{@agent_runtime_env_value} exec #{command} --output-format stream-json --print \"$(cat #{shell_escape(prompt_file)})\""
  end

  defp agent_runtime_env do
    [{String.to_charlist(@agent_runtime_env), String.to_charlist(@agent_runtime_env_value)}]
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp read_port_output(port, on_message, turn_timeout_ms) do
    acc = %{session_id: nil, input_tokens: 0, output_tokens: 0, turn_failed: nil}
    read_loop(port, on_message, acc, turn_timeout_ms)
  end

  defp read_loop(port, on_message, acc, turn_timeout_ms) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        acc = handle_line(line, on_message, acc)
        read_loop(port, on_message, acc, turn_timeout_ms)

      {^port, {:data, {:noeol, _partial}}} ->
        read_loop(port, on_message, acc, turn_timeout_ms)

      {^port, {:exit_status, 0}} ->
        finalize_read_result(acc)

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      turn_timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp finalize_read_result(%{turn_failed: reason}) when is_binary(reason) do
    {:error, {:turn_failed, reason}}
  end

  defp finalize_read_result(acc), do: {:ok, Map.delete(acc, :turn_failed)}

  defp handle_line(line, on_message, acc) do
    case parse_event(line) do
      {:session_started, session_id} ->
        %{acc | session_id: session_id}

      {:turn_completed, result} ->
        on_message.({:turn_completed, result})
        Map.merge(acc, result)

      {:turn_failed, reason} ->
        on_message.({:turn_failed, reason})
        %{acc | turn_failed: reason}

      {:notification, text} ->
        on_message.({:notification, text})
        acc

      {:malformed, raw} ->
        Logger.debug("ClaudeCode unparseable line: #{inspect(raw)}")
        acc
    end
  end

  defp safe_close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
  end

  defp effective_allowed_domains(%Agent.NetworkAccess{
         allowed_domains: extra,
         denied_domains: denied
       }) do
    denied_set = MapSet.new(denied)

    (Schema.codex_built_in_network_allowed_domains() ++ extra)
    |> Enum.reject(&MapSet.member?(denied_set, &1))
    |> Enum.uniq()
  end

  defp summarize_assistant_message(%{"content" => content}) when is_list(content) do
    content
    |> Enum.find_value(fn
      %{"type" => "text", "text" => text} -> text
      _ -> nil
    end)
    |> case do
      nil -> "assistant message"
      text -> String.slice(text, 0, 120)
    end
  end

  defp summarize_assistant_message(_), do: "assistant message"

  defp extract_turn_result(event) do
    usage = Map.get(event, "usage", %{})

    %{
      input_tokens: Map.get(usage, "input_tokens", 0),
      output_tokens: Map.get(usage, "output_tokens", 0)
    }
  end
end
