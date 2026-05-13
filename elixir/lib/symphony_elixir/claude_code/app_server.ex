defmodule SymphonyElixir.ClaudeCode.AppServer do
  @moduledoc false

  @behaviour SymphonyElixir.AgentBehaviour

  require Logger
  alias SymphonyElixir.{AgentEnv, Config, PathSafety, SSH}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Agent

  @agent_runtime_env AgentEnv.runtime_marker_name()
  @agent_runtime_env_value AgentEnv.runtime_marker_value()
  @port_line_bytes 1_048_576

  @type session :: %{
          workspace: Path.t(),
          metadata: map(),
          worker_host: String.t() | nil,
          settings_path: Path.t()
        }

  # --- AgentBehaviour callbacks ---

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    settings = settings_from_opts(opts)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host, settings),
         {:ok, settings_path} <- write_claude_settings(expanded_workspace, worker_host, settings) do
      {:ok, %{workspace: expanded_workspace, metadata: %{}, worker_host: worker_host, settings_path: settings_path}}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{workspace: workspace, worker_host: worker_host} = _session, prompt, _issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    settings = settings_from_opts(opts)
    command = settings.agent.command
    turn_timeout_ms = settings.agent.turn_timeout_ms
    command_timeout_ms = settings.agent.command_timeout_ms

    with {:ok, port} <- start_port(workspace, command, prompt, worker_host) do
      try do
        read_port_output(port, on_message, turn_timeout_ms, command_timeout_ms)
      after
        safe_close_port(port)
      end
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{settings_path: settings_path, worker_host: nil}) when is_binary(settings_path) do
    remove_local_settings(settings_path)
  end

  def stop_session(%{settings_path: settings_path, worker_host: worker_host})
      when is_binary(settings_path) and is_binary(worker_host) do
    remove_remote_settings(worker_host, settings_path)
  end

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
          | {:tool_use, String.t()}
          | {:notification, String.t()}
          | {:turn_completed, map()}
          | {:turn_failed, String.t()}
          | {:rate_limited, %{retry_after_seconds: nil | non_neg_integer(), message: String.t()}, String.t()}
          | {:malformed, String.t()}
  def parse_event(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "session_id" => session_id}} ->
        {:session_started, session_id}

      {:ok, %{"type" => "assistant", "message" => message}} ->
        {:notification, summarize_assistant_message(message)}

      {:ok, %{"type" => "tool_use", "name" => name}} ->
        {:tool_use, name}

      {:ok, %{"type" => "result", "subtype" => "success"} = event} ->
        {:turn_completed, extract_turn_result(event)}

      {:ok, %{"type" => "result", "subtype" => "error"} = event} ->
        reason = Map.get(event, "error", "unknown error")
        classify_error_event(reason)

      {:ok, _other} ->
        {:malformed, line}

      {:error, _reason} ->
        {:malformed, line}
    end
  end

  @rate_limit_pattern ~r/rate[\s_-]?limit|429|too many requests/i
  @retry_after_pattern ~r/retry[\s_-]?after[^\d]{0,8}(\d+)|(\d+)\s*seconds?/i

  defp classify_error_event(reason) when is_binary(reason) do
    if Regex.match?(@rate_limit_pattern, reason) do
      info = %{retry_after_seconds: extract_retry_after(reason), message: reason}
      {:rate_limited, info, reason}
    else
      {:turn_failed, reason}
    end
  end

  defp classify_error_event(reason), do: {:turn_failed, reason}

  @doc false
  @spec event_to_update(any()) :: map() | nil
  def event_to_update({:rate_limited, info}) when is_map(info) do
    %{
      event: :rate_limited,
      timestamp: DateTime.utc_now(),
      rate_limits: build_throttle_rate_limits(info),
      message: Map.get(info, :message)
    }
  end

  def event_to_update(_), do: nil

  defp build_throttle_rate_limits(info) do
    primary =
      case Map.get(info, :retry_after_seconds) do
        nil -> %{remaining: 0}
        seconds when is_integer(seconds) -> %{remaining: 0, reset_in_seconds: seconds}
      end

    %{limit_id: "claude-throttled", primary: primary}
  end

  defp extract_retry_after(reason) do
    case Regex.run(@retry_after_pattern, reason, capture: :all_but_first) do
      nil ->
        nil

      captures ->
        captures
        |> Enum.find(&(is_binary(&1) and &1 != ""))
        |> case do
          nil -> nil
          digits -> String.to_integer(digits)
        end
    end
  end

  # --- Private helpers ---

  defp settings_from_opts(opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings -> settings
      _settings -> Config.settings!()
    end
  end

  defp validate_workspace_cwd(workspace, nil, settings) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(settings.workspace.root)
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

  defp validate_workspace_cwd(workspace, worker_host, _settings)
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

  defp write_claude_settings(workspace, worker_host, settings) do
    network_access = settings.agent.network_access
    sandbox_json = build_sandbox_settings(network_access)
    claude_dir = Path.join(workspace, ".claude")
    settings_path = Path.join(claude_dir, "settings.json")

    with {:ok, json} <- encode_settings_json(sandbox_json),
         :ok <- write_settings_file(claude_dir, settings_path, json, worker_host) do
      {:ok, settings_path}
    end
  end

  defp encode_settings_json(sandbox_json) do
    encoder = Application.get_env(:symphony_elixir, :claude_settings_json_encoder, &Jason.encode/2)

    case encoder.(sandbox_json, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:claude_settings_encode_failed, reason}}
    end
  end

  defp write_settings_file(claude_dir, settings_path, json, nil) do
    with :ok <- mkdir_claude_dir(claude_dir) do
      write_local_settings_file(settings_path, json)
    end
  end

  defp write_settings_file(claude_dir, settings_path, json, worker_host) when is_binary(worker_host) do
    command = remote_write_settings_command(claude_dir, settings_path, json)

    case ssh_module().run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, {:claude_settings_write_failed, :remote, worker_host, status, output}}

      {:error, reason} ->
        {:error, {:claude_settings_write_failed, :remote, worker_host, reason}}
    end
  end

  defp mkdir_claude_dir(claude_dir) do
    case File.mkdir_p(claude_dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:claude_settings_write_failed, :mkdir_p, claude_dir, reason}}
    end
  end

  defp write_local_settings_file(settings_path, json) do
    case File.write(settings_path, json) do
      :ok -> :ok
      {:error, reason} -> {:error, {:claude_settings_write_failed, :write, settings_path, reason}}
    end
  end

  defp start_port(workspace, command, prompt, nil) do
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
            env: AgentEnv.build()
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, command, prompt, worker_host) do
    with {:ok, command_words} <- command_words(command) do
      ssh_module().start_port(
        worker_host,
        remote_launch_command(workspace, command_words, prompt),
        line: @port_line_bytes,
        env: AgentEnv.build()
      )
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

  defp remote_write_settings_command(claude_dir, settings_path, json) do
    [
      "mkdir -p #{shell_escape(claude_dir)}",
      "printf %s #{shell_escape(json)} > #{shell_escape(settings_path)}"
    ]
    |> Enum.join(" && ")
  end

  defp remote_remove_settings_command(settings_path) do
    claude_dir = Path.dirname(settings_path)

    [
      "rm -f #{shell_escape(settings_path)}",
      "rmdir #{shell_escape(claude_dir)} 2>/dev/null || true"
    ]
    |> Enum.join(" && ")
  end

  defp remote_launch_command(workspace, command_words, prompt) do
    command = command_words |> Enum.map_join(" ", &shell_escape/1)

    [
      "cd #{shell_escape(workspace)}",
      "#{@agent_runtime_env}=#{@agent_runtime_env_value} exec #{command} --output-format stream-json --print #{shell_escape(prompt)}"
    ]
    |> Enum.join(" && ")
  end

  defp remove_local_settings(settings_path) do
    case File.rm(settings_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> Logger.warning("Claude settings cleanup failed path=#{settings_path} reason=#{inspect(reason)}")
    end

    _ = File.rmdir(Path.dirname(settings_path))
    :ok
  end

  defp remove_remote_settings(worker_host, settings_path) do
    case ssh_module().run(worker_host, remote_remove_settings_command(settings_path), stderr_to_stdout: true) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning("Claude settings cleanup failed worker_host=#{worker_host} path=#{settings_path} status=#{status} output=#{inspect(output)}")

      {:error, reason} ->
        Logger.warning("Claude settings cleanup failed worker_host=#{worker_host} path=#{settings_path} reason=#{inspect(reason)}")
    end

    :ok
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp ssh_module do
    Application.get_env(:symphony_elixir, :claude_code_ssh_module, SSH)
  end

  defp read_port_output(port, on_message, turn_timeout_ms, command_timeout_ms) do
    now = System.monotonic_time(:millisecond)
    turn_deadline = now + turn_timeout_ms
    acc = %{session_id: nil, input_tokens: 0, output_tokens: 0, turn_failed: nil, turn_completed: false}
    read_loop(port, on_message, acc, turn_deadline, nil, command_timeout_ms, "")
  end

  defp read_loop(port, on_message, acc, turn_deadline, command_deadline, command_timeout_ms, pending_line) do
    now = System.monotonic_time(:millisecond)
    turn_remaining = max(1, turn_deadline - now)

    timeout =
      case command_deadline do
        nil -> turn_remaining
        cd -> min(turn_remaining, max(1, cd - now))
      end

    receive do
      {^port, {:data, {:eol, line}}} ->
        full_line = pending_line <> line
        event = parse_event(full_line)

        new_command_deadline =
          case event do
            {:tool_use, _} when command_timeout_ms > 0 ->
              System.monotonic_time(:millisecond) + command_timeout_ms

            _ ->
              command_deadline
          end

        acc = apply_event(event, on_message, acc)
        read_loop(port, on_message, acc, turn_deadline, new_command_deadline, command_timeout_ms, "")

      {^port, {:data, {:noeol, partial}}} ->
        read_loop(port, on_message, acc, turn_deadline, command_deadline, command_timeout_ms, pending_line <> partial)

      {^port, {:exit_status, 0}} ->
        finalize_read_result(acc)

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      timeout ->
        if System.monotonic_time(:millisecond) >= turn_deadline do
          {:error, :turn_timeout}
        else
          {:error, :command_timeout}
        end
    end
  end

  defp finalize_read_result(%{turn_failed: reason}) when is_binary(reason) do
    {:error, {:turn_failed, reason}}
  end

  defp finalize_read_result(%{turn_completed: false}) do
    {:error, :no_result_event}
  end

  defp finalize_read_result(acc) do
    {:ok, acc |> Map.delete(:turn_failed) |> Map.delete(:turn_completed)}
  end

  defp apply_event(event, on_message, acc) do
    case event do
      {:session_started, session_id} ->
        on_message.({:session_started, session_id})
        %{acc | session_id: session_id}

      {:turn_completed, result} ->
        on_message.({:turn_completed, result})
        acc |> Map.merge(result) |> Map.put(:turn_completed, true)

      {:turn_failed, reason} ->
        on_message.({:turn_failed, reason})
        %{acc | turn_failed: reason}

      {:rate_limited, info, reason} ->
        on_message.({:rate_limited, info})
        on_message.({:turn_failed, reason})
        %{acc | turn_failed: reason}

      {:tool_use, name} ->
        on_message.({:notification, "tool: #{name}"})
        acc

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

    (Schema.claude_built_in_network_allowed_domains() ++ extra)
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
