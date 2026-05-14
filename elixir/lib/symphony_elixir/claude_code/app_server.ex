defmodule SymphonyElixir.ClaudeCode.AppServer do
  @moduledoc false

  @behaviour SymphonyElixir.AgentBehaviour

  require Logger
  alias SymphonyElixir.{AgentEnv, AgentSandboxConfig, Config, DependencyGate, McpServer, PathSafety, SSH}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Agent
  alias SymphonyElixir.GitHub.Hosts

  @agent_runtime_env AgentEnv.runtime_marker_name()
  @agent_runtime_env_value AgentEnv.runtime_marker_value()
  @port_line_bytes 1_048_576

  @type session :: %{
          workspace: Path.t(),
          metadata: map(),
          worker_host: String.t() | nil,
          settings_path: Path.t(),
          mcp_config_path: Path.t(),
          mcp_session: McpServer.session() | nil,
          mcp_remote_socket_path: Path.t() | nil,
          mcp_remote_shim_path: Path.t() | nil
        }

  # --- AgentBehaviour callbacks ---

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    settings = settings_from_opts(opts)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host, settings),
         {:ok, mcp_session, remote_socket_path, remote_shim_path} <-
           start_mcp_session(expanded_workspace, worker_host, opts) do
      create_session(
        expanded_workspace,
        worker_host,
        settings,
        mcp_session,
        remote_socket_path,
        remote_shim_path
      )
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(%{workspace: workspace, worker_host: worker_host} = session, prompt, _issue, opts) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    settings = settings_from_opts(opts)
    command = settings.agent.command
    turn_timeout_ms = settings.agent.turn_timeout_ms
    command_timeout_ms = settings.agent.command_timeout_ms

    with {:ok, port} <- start_port(workspace, command, prompt, worker_host, session) do
      try do
        read_port_output(port, on_message, turn_timeout_ms, command_timeout_ms)
      after
        safe_close_port(port)
      end
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{worker_host: nil} = session) do
    remove_local_runtime_files(runtime_file_paths(session))
    McpServer.stop_session(Map.get(session, :mcp_session))
  end

  def stop_session(%{worker_host: worker_host} = session) when is_binary(worker_host) do
    remove_remote_runtime_files(
      worker_host,
      runtime_file_paths(session),
      Map.get(session, :mcp_remote_socket_path),
      Map.get(session, :mcp_remote_shim_path)
    )

    McpServer.stop_session(Map.get(session, :mcp_session))
  end

  def stop_session(_session), do: :ok

  # --- Sandbox settings ---

  @doc false
  @spec build_sandbox_settings(Agent.NetworkAccess.t(), [String.t()]) :: map()
  def build_sandbox_settings(%Agent.NetworkAccess{mode: mode} = network_access, allow_read_paths \\ []) do
    base =
      %{
        "sandbox" => %{
          "enabled" => true,
          "failIfUnavailable" => true,
          "allowUnsandboxedCommands" => false,
          "filesystem" => AgentSandboxConfig.claude_filesystem_settings(allow_read_paths)
        }
      }

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

  defp build_claude_settings(network_access, allow_read_paths) do
    network_access
    |> build_sandbox_settings(allow_read_paths)
    |> Map.put("permissions", %{
      "deny" => [
        "Bash(gh:*)",
        "Bash(git push:*)",
        "Bash(git remote add:*)",
        "Bash(git remote set-url:*)"
      ]
    })
  end

  defp build_mcp_config(mcp_session, socket_path, shim_path) do
    %{
      "mcpServers" => %{
        "symphony" => %{
          "command" => shim_path,
          "args" => ["--socket", socket_path, "--session", mcp_session.token],
          "alwaysLoad" => true
        }
      }
    }
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
      {:ok, event} -> parse_decoded_event(event, line)
      {:error, _reason} -> {:malformed, line}
    end
  end

  defp parse_decoded_event(%{"type" => "system", "session_id" => session_id}, _line),
    do: {:session_started, session_id}

  defp parse_decoded_event(%{"type" => "assistant", "message" => message}, _line),
    do: {:notification, summarize_assistant_message(message)}

  defp parse_decoded_event(%{"type" => "user", "message" => message}, _line),
    do: {:notification, summarize_user_message(message)}

  defp parse_decoded_event(%{"type" => "tool_use", "name" => name}, _line), do: {:tool_use, name}

  defp parse_decoded_event(%{"type" => "rate_limit_event", "rate_limit_info" => info}, _line),
    do: classify_rate_limit_event(info)

  defp parse_decoded_event(%{"type" => "result", "subtype" => "success"} = event, _line),
    do: {:turn_completed, extract_turn_result(event)}

  defp parse_decoded_event(%{"type" => "result", "subtype" => "error"} = event, _line) do
    event
    |> Map.get("error", "unknown error")
    |> classify_error_event()
  end

  defp parse_decoded_event(_event, line), do: {:malformed, line}

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
  def event_to_update({:session_started, session_id}) when is_binary(session_id) do
    %{
      event: :session_started,
      timestamp: DateTime.utc_now(),
      session_id: session_id,
      payload: %{session_id: session_id}
    }
  end

  def event_to_update({:notification, message}) when is_binary(message) do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: message
    }
  end

  def event_to_update({:tool_use, name}) when is_binary(name) do
    %{
      event: :tool_use,
      timestamp: DateTime.utc_now(),
      payload: %{
        method: "item/tool/call",
        params: %{tool: name}
      }
    }
  end

  def event_to_update({:turn_completed, result}) when is_map(result) do
    %{
      event: :turn_completed,
      timestamp: DateTime.utc_now(),
      usage: result,
      payload: %{
        method: "turn/completed",
        usage: result
      }
    }
  end

  def event_to_update({:turn_failed, reason}) when is_binary(reason) do
    %{
      event: :turn_failed,
      timestamp: DateTime.utc_now(),
      reason: reason,
      payload: %{
        method: "turn/failed",
        params: %{error: %{message: reason}}
      }
    }
  end

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

  defp create_session(workspace, worker_host, settings, mcp_session, remote_socket_path, remote_shim_path) do
    case write_claude_runtime_files(
           workspace,
           worker_host,
           settings,
           mcp_session,
           remote_socket_path,
           remote_shim_path
         ) do
      {:ok, runtime_files} ->
        {:ok,
         %{
           workspace: workspace,
           metadata: %{},
           worker_host: worker_host,
           settings_path: runtime_files.settings_path,
           mcp_config_path: runtime_files.mcp_config_path,
           mcp_session: mcp_session,
           mcp_remote_socket_path: remote_socket_path,
           mcp_remote_shim_path: remote_shim_path
         }}

      {:error, reason} ->
        cleanup_remote_shim(worker_host, remote_shim_path)
        McpServer.stop_session(mcp_session)
        {:error, reason}
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

  defp start_mcp_session(workspace, worker_host, opts) do
    issue = Keyword.get(opts, :issue)

    context = %{
      issue: issue,
      issue_id: Keyword.get(opts, :issue_id),
      workspace: workspace,
      command_security: command_security_context(workspace, worker_host),
      comment_registry: Keyword.get(opts, :linear_comment_registry),
      tool_opts: tool_opts(opts),
      dependency_gate: DependencyGate.build(workspace, issue, Keyword.get(opts, :settings), opts)
    }

    mcp_opts =
      [
        run_id: Keyword.get(opts, :run_id),
        server: Keyword.get(opts, :mcp_server, McpServer),
        shim_path: Keyword.get(opts, :mcp_shim_path),
        worker_host: worker_host
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case McpServer.start_session(context, mcp_opts) do
      {:ok, mcp_session} ->
        case install_remote_shim(mcp_session, worker_host) do
          {:ok, remote_shim_path} ->
            {:ok, mcp_session, Map.get(mcp_session, :remote_socket_path), remote_shim_path}

          {:error, reason} ->
            McpServer.stop_session(mcp_session)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tool_opts(opts) do
    opts
    |> Keyword.take([:linear_client, :upload_client, :gh_runner, :git_runner])
  end

  defp install_remote_shim(_mcp_session, nil), do: {:ok, nil}

  defp install_remote_shim(%{id: id, shim_path: local_shim_path}, worker_host)
       when is_binary(worker_host) do
    remote_path = remote_shim_path(id)

    case File.read(local_shim_path) do
      {:ok, contents} ->
        command = remote_install_shim_command(remote_path, contents)

        case ssh_module().run(worker_host, command, stderr_to_stdout: true) do
          {:ok, {_output, 0}} ->
            {:ok, remote_path}

          {:ok, {output, status}} ->
            {:error, {:claude_mcp_shim_install_failed, worker_host, status, output}}

          {:error, reason} ->
            {:error, {:claude_mcp_shim_install_failed, worker_host, reason}}
        end

      {:error, reason} ->
        {:error, {:claude_mcp_shim_install_failed, :local_read, local_shim_path, reason}}
    end
  end

  defp remote_shim_path(id) when is_binary(id) do
    Path.join("/tmp", "symphony-mcp-shim-#{id}")
  end

  defp remote_install_shim_command(remote_path, contents) do
    [
      "mkdir -p #{shell_escape(Path.dirname(remote_path))}",
      "printf %s #{shell_escape(contents)} > #{shell_escape(remote_path)}",
      "chmod 0700 #{shell_escape(remote_path)}"
    ]
    |> Enum.join(" && ")
  end

  defp cleanup_remote_shim(nil, _path), do: :ok
  defp cleanup_remote_shim(_worker_host, nil), do: :ok

  defp cleanup_remote_shim(worker_host, path) when is_binary(worker_host) and is_binary(path) do
    case ssh_module().run(worker_host, "rm -f #{shell_escape(path)}", stderr_to_stdout: true) do
      {:ok, {_output, 0}} -> :ok
      _ -> :ok
    end
  end

  defp write_claude_runtime_files(_workspace, worker_host, settings, mcp_session, socket_path, remote_shim_path) do
    network_access = settings.agent.network_access
    allow_read_paths = workspace_sandbox_allow_read_paths(settings)
    effective_shim_path = effective_shim_path(mcp_session, remote_shim_path)
    effective_socket_path = socket_path || mcp_session.socket_path

    settings_json = build_claude_settings(network_access, allow_read_paths)
    mcp_config_json = build_mcp_config(mcp_session, effective_socket_path, effective_shim_path)

    settings_dir = claude_settings_dir(worker_host, mcp_session)
    settings_path = Path.join(settings_dir, "settings.json")
    mcp_config_path = Path.join(settings_dir, "mcp_config.json")

    runtime_files = [
      {settings_path, settings_json},
      {mcp_config_path, mcp_config_json}
    ]

    with {:ok, encoded_runtime_files} <- encode_runtime_files(runtime_files),
         :ok <- write_runtime_files(settings_dir, encoded_runtime_files, worker_host) do
      {:ok, %{settings_path: settings_path, mcp_config_path: mcp_config_path}}
    end
  end

  defp workspace_sandbox_allow_read_paths(%Schema{workspace: %{sandbox: %{allow_read_paths: paths}}}) when is_list(paths),
    do: paths

  defp workspace_sandbox_allow_read_paths(_settings), do: []

  defp claude_settings_dir(nil, %{id: id}) when is_binary(id) do
    Path.join(System.tmp_dir!(), "symphony-claude-settings-#{id}")
  end

  defp claude_settings_dir(worker_host, %{id: id}) when is_binary(worker_host) and is_binary(id) do
    Path.join("/tmp", "symphony-claude-settings-#{id}")
  end

  defp effective_shim_path(_mcp_session, remote_shim_path) when is_binary(remote_shim_path),
    do: remote_shim_path

  defp effective_shim_path(%{shim_path: shim_path}, _remote), do: shim_path

  defp encode_settings_json(sandbox_json) do
    encoder = Application.get_env(:symphony_elixir, :claude_settings_json_encoder, &Jason.encode/2)

    case encoder.(sandbox_json, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:claude_settings_encode_failed, reason}}
    end
  end

  defp encode_runtime_files(runtime_files) do
    runtime_files
    |> Enum.reduce_while({:ok, []}, fn {path, contents}, {:ok, encoded} ->
      case encode_settings_json(contents) do
        {:ok, json} -> {:cont, {:ok, [{path, json} | encoded]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_runtime_files(settings_dir, encoded_runtime_files, nil) do
    with :ok <- mkdir_claude_dir(settings_dir) do
      write_local_runtime_files(encoded_runtime_files)
    end
  end

  defp write_runtime_files(settings_dir, encoded_runtime_files, worker_host) when is_binary(worker_host) do
    command = remote_write_runtime_files_command(settings_dir, encoded_runtime_files)

    case ssh_module().run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        {:error, {:claude_settings_write_failed, :remote, worker_host, status, output}}

      {:error, reason} ->
        {:error, {:claude_settings_write_failed, :remote, worker_host, reason}}
    end
  end

  defp mkdir_claude_dir(settings_dir) do
    case File.mkdir(settings_dir) do
      :ok ->
        case File.chmod(settings_dir, 0o700) do
          :ok -> :ok
          {:error, reason} -> {:error, {:claude_settings_write_failed, :chmod, settings_dir, reason}}
        end

      {:error, reason} ->
        {:error, {:claude_settings_write_failed, :mkdir, settings_dir, reason}}
    end
  end

  defp write_local_runtime_files(encoded_runtime_files) do
    Enum.reduce_while(encoded_runtime_files, :ok, fn {path, json}, :ok ->
      case write_local_runtime_file(path, json) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_local_runtime_file(settings_path, json) do
    case File.open(settings_path, [:write, :exclusive], fn file -> IO.write(file, json) end) do
      {:ok, :ok} ->
        case File.chmod(settings_path, 0o600) do
          :ok -> :ok
          {:error, reason} -> {:error, {:claude_settings_write_failed, :chmod, settings_path, reason}}
        end

      {:error, reason} ->
        {:error, {:claude_settings_write_failed, :write, settings_path, reason}}
    end
  end

  defp start_port(workspace, command, prompt, nil, session) do
    with {:ok, {executable, command_args}} <- local_command(workspace, command) do
      args =
        command_args ++
          claude_settings_args(session) ++ ["--output-format", "stream-json", "--print", prompt]

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

  defp start_port(workspace, command, prompt, worker_host, session) do
    with {:ok, command_words} <- command_words(command) do
      reverse_forwards = mcp_reverse_forwards(session)

      ssh_module().start_port(
        worker_host,
        remote_launch_command(workspace, command_words, prompt, session),
        line: @port_line_bytes,
        env: AgentEnv.build(),
        reverse_forwards: reverse_forwards
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

  defp remote_write_runtime_files_command(settings_dir, encoded_runtime_files) do
    write_commands =
      Enum.flat_map(encoded_runtime_files, fn {path, json} ->
        [
          "printf %s #{shell_escape(json)} > #{shell_escape(path)}",
          "chmod 0600 #{shell_escape(path)}"
        ]
      end)

    [
      "umask 077",
      "mkdir #{shell_escape(settings_dir)}",
      "chmod 0700 #{shell_escape(settings_dir)}"
      | write_commands
    ]
    |> Enum.join(" && ")
  end

  defp remote_remove_runtime_files_command(file_paths, socket_path, shim_path) do
    runtime_dirs =
      file_paths
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()

    file_paths
    |> Enum.map(fn path -> "rm -f #{shell_escape(path)}" end)
    |> Kernel.++([
      remote_path_cleanup_command(socket_path),
      remote_path_cleanup_command(shim_path)
    ])
    |> Kernel.++(Enum.map(runtime_dirs, fn dir -> "rmdir #{shell_escape(dir)} 2>/dev/null || true" end))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp remote_path_cleanup_command(path) when is_binary(path) and path != "" do
    "rm -f #{shell_escape(path)}"
  end

  defp remote_path_cleanup_command(_path), do: nil

  defp claude_settings_args(%{settings_path: settings_path, mcp_config_path: mcp_config_path})
       when is_binary(settings_path) and is_binary(mcp_config_path) do
    [
      "--setting-sources",
      "",
      "--settings",
      settings_path,
      "--mcp-config",
      mcp_config_path,
      "--strict-mcp-config"
    ]
  end

  defp claude_settings_args(_session), do: []

  defp remote_launch_command(workspace, command_words, prompt, session) do
    command =
      (command_words ++ claude_settings_args(session))
      |> Enum.map_join(" ", &shell_escape/1)

    [
      "cd #{shell_escape(workspace)}",
      "#{@agent_runtime_env}=#{@agent_runtime_env_value} exec #{command} --output-format stream-json --print #{shell_escape(prompt)}"
    ]
    |> Enum.join(" && ")
  end

  defp runtime_file_paths(session) do
    session
    |> Map.take([:settings_path, :mcp_config_path])
    |> Map.values()
    |> Enum.filter(&is_binary/1)
  end

  defp remove_local_runtime_files(file_paths) when is_list(file_paths) do
    Enum.each(file_paths, fn path ->
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> Logger.warning("Claude settings cleanup failed path=#{path} reason=#{inspect(reason)}")
      end
    end)

    file_paths
    |> Enum.map(&Path.dirname/1)
    |> Enum.uniq()
    |> Enum.each(fn dir -> _ = File.rmdir(dir) end)

    :ok
  end

  defp remove_remote_runtime_files(worker_host, file_paths, socket_path, shim_path) do
    command = remote_remove_runtime_files_command(file_paths, socket_path, shim_path)

    case ssh_module().run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {output, status}} ->
        Logger.warning("Claude settings cleanup failed worker_host=#{worker_host} paths=#{inspect(file_paths)} status=#{status} output=#{inspect(output)}")

      {:error, reason} ->
        Logger.warning("Claude settings cleanup failed worker_host=#{worker_host} paths=#{inspect(file_paths)} reason=#{inspect(reason)}")
    end

    :ok
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp mcp_reverse_forwards(%{mcp_session: %{socket_path: local_socket}, mcp_remote_socket_path: remote_socket})
       when is_binary(local_socket) and is_binary(remote_socket) do
    [{remote_socket, local_socket}]
  end

  defp mcp_reverse_forwards(_session), do: []

  defp command_security_context(workspace, worker_host) do
    origin_url = discover_origin_url(workspace, worker_host)

    %{
      origin_url: origin_url,
      origin_repo: github_repo_from_url(origin_url),
      origin_gh_repo: github_gh_repo_from_url(origin_url),
      workspace: workspace,
      worker_host: worker_host
    }
  end

  defp discover_origin_url(workspace, nil) when is_binary(workspace) do
    with git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <-
           System.cmd(git, ["-C", workspace, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      output |> String.trim() |> blank_to_nil()
    else
      _result -> nil
    end
  end

  defp discover_origin_url(_workspace, worker_host) when is_binary(worker_host), do: nil

  defp github_repo_from_url(url) when is_binary(url) do
    case github_repo_parts_from_url(url) do
      {_host, owner, repo} -> "#{owner}/#{repo}"
      nil -> nil
    end
  end

  defp github_repo_from_url(_url), do: nil

  defp github_gh_repo_from_url(url) when is_binary(url) do
    case github_repo_parts_from_url(url) do
      {"github.com", owner, repo} -> "#{owner}/#{repo}"
      {host, owner, repo} when is_binary(host) -> "#{host}/#{owner}/#{repo}"
      nil -> nil
    end
  end

  defp github_gh_repo_from_url(_url), do: nil

  defp github_repo_parts_from_url(url) when is_binary(url) do
    Enum.find_value(
      [
        ~r{^https?://([^/]+)/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^ssh://[^@]+@([^/]+)/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^(?:[^@]+@)?([^/:]+):([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^([^/\s:]*github[^/\s:]*)/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$}
      ],
      fn regex ->
        case Regex.run(regex, url) do
          [_full, host, owner, repo] -> canonical_github_repo_parts(host, owner, repo)
          _ -> nil
        end
      end
    )
  end

  defp canonical_github_repo_parts(host, owner, repo) do
    case Hosts.canonical_github_host(host) do
      {:ok, canonical_host} -> {canonical_host, owner, repo}
      :error -> nil
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
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
        on_message.({:tool_use, name})
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

  defp summarize_user_message(%{"content" => content}) when is_list(content) do
    content
    |> Enum.find_value(&tool_result_summary/1)
    |> case do
      nil -> "tool_result"
      text -> "tool_result: " <> String.slice(text, 0, 120)
    end
  end

  defp summarize_user_message(_), do: "tool_result"

  defp tool_result_summary(%{"type" => "tool_result", "content" => content}) when is_binary(content),
    do: content

  defp tool_result_summary(%{"type" => "tool_result", "content" => content}) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => "tool_reference", "tool_name" => name} when is_binary(name) -> name
      _ -> nil
    end)
  end

  defp tool_result_summary(_), do: nil

  defp classify_rate_limit_event(info) when is_map(info) do
    rate_limit_type = Map.get(info, "rateLimitType", "rate_limit")
    status = Map.get(info, "status", "unknown")
    utilization = Map.get(info, "utilization")

    message =
      case utilization do
        u when is_number(u) ->
          percent = round(u * 100)
          "rate_limit #{rate_limit_type} #{status} (#{percent}% utilization)"

        _ ->
          "rate_limit #{rate_limit_type} #{status}"
      end

    case status do
      "allowed_warning" -> {:notification, message}
      "allowed" -> {:notification, message}
      _ -> {:rate_limited, %{retry_after_seconds: nil, message: message}, message}
    end
  end

  defp classify_rate_limit_event(_), do: {:notification, "rate_limit event"}

  defp extract_turn_result(event) do
    usage = Map.get(event, "usage", %{})
    input_tokens = token_count(usage, "input_tokens", 0)
    output_tokens = token_count(usage, "output_tokens", 0)
    cached_input_tokens = token_count(usage, "cache_read_input_tokens", 0)

    %{
      input_tokens: input_tokens,
      cached_input_tokens: cached_input_tokens,
      output_tokens: output_tokens,
      total_tokens: token_count(usage, "total_tokens", nil) || input_tokens + output_tokens
    }
  end

  defp token_count(usage, key, default) when is_map(usage) and is_binary(key) do
    case Map.get(usage, key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp token_count(_usage, _key, default), do: default
end
