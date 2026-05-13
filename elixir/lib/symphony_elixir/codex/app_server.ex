defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  @behaviour SymphonyElixir.AgentBehaviour

  require Logger
  alias SymphonyElixir.AgentEnv
  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.AuditLog
  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.DependencyAudit
  alias SymphonyElixir.Notifications
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.SSH
  alias SymphonyElixir.Tracker

  @initialize_id 1
  @thread_start_id 2
  @turn_start_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000
  @agent_runtime_env AgentEnv.runtime_marker_name()
  @agent_runtime_env_value AgentEnv.runtime_marker_value()
  @non_interactive_tool_input_answer "This is a non-interactive session. Operator input is unavailable."

  @type session :: %{
          port: port(),
          metadata: map(),
          approval_policy: String.t() | map(),
          auto_approve_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          command_security: map(),
          settings: Schema.t()
        }

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    settings = settings_from_opts(opts)

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, worker_host, settings),
         {:ok, port} <- start_port(expanded_workspace, worker_host, settings) do
      metadata = port_metadata(port, worker_host)

      with {:ok, session_policies} <- session_policies(expanded_workspace, worker_host, settings),
           {:ok, thread_id} <- do_start_session(port, expanded_workspace, session_policies, settings) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           approval_policy: session_policies.approval_policy,
           auto_approve_requests: session_policies.auto_approve_requests,
           thread_sandbox: session_policies.thread_sandbox,
           turn_sandbox_policy: session_policies.turn_sandbox_policy,
           thread_id: thread_id,
           workspace: expanded_workspace,
           worker_host: worker_host,
           command_security: command_security_context(expanded_workspace, worker_host),
           settings: settings
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          approval_policy: approval_policy,
          auto_approve_requests: auto_approve_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace,
          command_security: command_security,
          settings: settings
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    tool_executor =
      Keyword.get_lazy(opts, :tool_executor, fn ->
        dynamic_tool_executor(issue, workspace, opts)
      end)

    approval_context = %{
      issue: issue,
      repo_key: Keyword.get(opts, :repo_key),
      audit_log_opts: Keyword.get(opts, :audit_log_opts, []),
      command_security: command_security,
      dependency_gate: dependency_gate_context(workspace, issue, settings, opts)
    }

    case start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy, settings) do
      {:ok, turn_id} ->
        session_id = "#{thread_id}-#{turn_id}"
        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id
          },
          metadata
        )

        case await_turn_completion(
               port,
               on_message,
               tool_executor,
               auto_approve_requests,
               settings,
               approval_context
             ) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id
             }}

          {:error, reason} ->
            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: reason
              },
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  defp settings_from_opts(opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings -> settings
      _settings -> Config.settings!()
    end
  end

  defp dynamic_tool_executor(issue, workspace, opts) do
    registry = Keyword.get(opts, :linear_comment_registry) || temporary_comment_registry()

    fn tool, arguments ->
      DynamicTool.execute(tool, arguments,
        issue: issue,
        workspace: workspace,
        comment_registry: registry
      )
    end
  end

  defp temporary_comment_registry do
    case CommentRegistry.start_link() do
      {:ok, pid} ->
        pid

      {:error, reason} ->
        Logger.error("Failed to start Linear CommentRegistry: #{inspect(reason)}. Comment edits will be unavailable.")
        nil
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

  defp start_port(workspace, nil, settings) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(settings.agent.command)],
            cd: String.to_charlist(workspace),
            env: AgentEnv.build(),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp start_port(workspace, worker_host, settings) when is_binary(worker_host) do
    remote_command = remote_launch_command(workspace, settings)
    SSH.start_port(worker_host, remote_command, line: @port_line_bytes, env: AgentEnv.build())
  end

  defp remote_launch_command(workspace, settings) when is_binary(workspace) do
    [
      "cd #{shell_escape(workspace)}",
      "#{@agent_runtime_env}=#{@agent_runtime_env_value} exec #{settings.agent.command}"
    ]
    |> Enum.join(" && ")
  end

  defp port_metadata(port, worker_host) when is_port(port) do
    base_metadata =
      case :erlang.port_info(port, :os_pid) do
        {:os_pid, os_pid} ->
          %{codex_app_server_pid: to_string(os_pid)}

        _ ->
          %{}
      end

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp command_security_context(workspace, worker_host) do
    origin_url = discover_origin_url(workspace, worker_host)

    %{
      origin_url: origin_url,
      origin_repo: github_repo_from_url(origin_url),
      workspace: workspace,
      worker_host: worker_host
    }
  end

  defp discover_origin_url(workspace, nil) when is_binary(workspace) do
    with git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <- System.cmd(git, ["-C", workspace, "remote", "get-url", "origin"], stderr_to_stdout: true) do
      output |> String.trim() |> blank_to_nil()
    else
      _result -> nil
    end
  end

  defp discover_origin_url(_workspace, worker_host) when is_binary(worker_host), do: nil

  defp send_initialize(port, settings) do
    payload = %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{
          "experimentalApi" => true
        },
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "title" => "Symphony Orchestrator",
          "version" => "0.1.0"
        }
      }
    }

    send_message(port, payload)

    with {:ok, _} <- await_response(port, @initialize_id, settings) do
      send_message(port, %{"method" => "initialized", "params" => %{}})
      :ok
    end
  end

  defp session_policies(workspace, nil, settings) do
    Config.codex_runtime_settings(settings, workspace, [])
  end

  defp session_policies(workspace, worker_host, settings) when is_binary(worker_host) do
    Config.codex_runtime_settings(settings, workspace, remote: true)
  end

  defp do_start_session(port, workspace, session_policies, settings) do
    case send_initialize(port, settings) do
      :ok -> start_thread(port, workspace, session_policies, settings)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(
         port,
         workspace,
         %{
           approval_policy: approval_policy,
           thread_sandbox: thread_sandbox,
           thread_config: thread_config
         },
         settings
       ) do
    params =
      %{
        "approvalPolicy" => approval_policy,
        "sandbox" => thread_sandbox,
        "cwd" => workspace,
        "dynamicTools" => DynamicTool.tool_specs()
      }
      |> maybe_put_thread_config(thread_config)

    send_message(port, %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => params
    })

    case await_response(port, @thread_start_id, settings) do
      {:ok, %{"thread" => thread_payload}} ->
        case thread_payload do
          %{"id" => thread_id} -> {:ok, thread_id}
          _ -> {:error, {:invalid_thread_payload, thread_payload}}
        end

      other ->
        other
    end
  end

  defp maybe_put_thread_config(params, config) when is_map(config) and map_size(config) > 0 do
    Map.put(params, "config", config)
  end

  defp maybe_put_thread_config(params, _config), do: params

  defp start_turn(port, thread_id, prompt, issue, workspace, approval_policy, turn_sandbox_policy, settings) do
    send_message(port, %{
      "method" => "turn/start",
      "id" => @turn_start_id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [
          %{
            "type" => "text",
            "text" => prompt
          }
        ],
        "cwd" => workspace,
        "title" => "#{issue.identifier}: #{issue.title}",
        "approvalPolicy" => approval_policy,
        "sandboxPolicy" => turn_sandbox_policy
      }
    })

    case await_response(port, @turn_start_id, settings) do
      {:ok, %{"turn" => %{"id" => turn_id}}} -> {:ok, turn_id}
      other -> other
    end
  end

  defp await_turn_completion(port, on_message, tool_executor, auto_approve_requests, settings, approval_context) do
    config = settings.agent

    receive_loop(
      port,
      on_message,
      config.turn_timeout_ms,
      "",
      tool_executor,
      auto_approve_requests,
      approval_context,
      initial_turn_stream_state(config.command_timeout_ms)
    )
  end

  defp receive_loop(
         port,
         on_message,
         timeout_ms,
         pending_line,
         tool_executor,
         auto_approve_requests,
         approval_context,
         turn_stream_state
       ) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)

        handle_incoming(
          port,
          on_message,
          complete_line,
          timeout_ms,
          tool_executor,
          auto_approve_requests,
          approval_context,
          turn_stream_state
        )

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          tool_executor,
          auto_approve_requests,
          approval_context,
          turn_stream_state
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      receive_timeout_ms(timeout_ms, turn_stream_state) ->
        case command_timeout_error(turn_stream_state) do
          {:error, reason} -> {:error, reason}
          :ok -> {:error, :turn_timeout}
        end
    end
  end

  defp handle_incoming(
         port,
         on_message,
         data,
         timeout_ms,
         tool_executor,
         auto_approve_requests,
         approval_context,
         turn_stream_state
       ) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      {:ok, %{"method" => "turn/completed"} = payload} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, port, payload)
        {:ok, :turn_completed}

      {:ok, %{"method" => "turn/failed", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_failed, Map.get(payload, "params")}}

      {:ok, %{"method" => "turn/cancelled", "params" => _} = payload} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          port,
          Map.get(payload, "params")
        )

        {:error, {:turn_cancelled, Map.get(payload, "params")}}

      {:ok, %{"method" => method} = payload}
      when is_binary(method) ->
        handle_turn_method(
          port,
          on_message,
          payload,
          payload_string,
          method,
          %{
            timeout_ms: timeout_ms,
            tool_executor: tool_executor,
            auto_approve_requests: auto_approve_requests,
            approval_context: approval_context,
            turn_stream_state: turn_stream_state
          }
        )

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{
            payload: payload,
            raw: payload_string
          },
          metadata_from_message(port, payload)
        )

        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          auto_approve_requests,
          approval_context,
          turn_stream_state
        )

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        if protocol_message_candidate?(payload_string) do
          emit_message(
            on_message,
            :malformed,
            %{
              payload: payload_string,
              raw: payload_string
            },
            metadata_from_message(port, %{raw: payload_string})
          )
        end

        receive_loop(
          port,
          on_message,
          timeout_ms,
          "",
          tool_executor,
          auto_approve_requests,
          approval_context,
          turn_stream_state
        )
    end
  end

  defp emit_turn_event(on_message, event, payload, payload_string, port, payload_details) do
    emit_message(
      on_message,
      event,
      %{
        payload: payload,
        raw: payload_string,
        details: payload_details
      },
      metadata_from_message(port, payload)
    )
  end

  defp handle_turn_method(
         port,
         on_message,
         payload,
         payload_string,
         method,
         stream_context
       ) do
    metadata = metadata_from_message(port, payload)

    request_context =
      stream_context
      |> Map.put(:on_message, on_message)
      |> Map.put(:metadata, metadata)

    case maybe_handle_approval_request(port, method, payload, payload_string, request_context) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:turn_input_required, payload}}

      :approved ->
        continue_or_timeout(port, on_message, stream_context, method, payload)

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          %{payload: payload, raw: payload_string},
          metadata
        )

        {:error, {:approval_required, payload}}

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            %{payload: payload, raw: payload_string},
            metadata
          )

          {:error, {:turn_input_required, payload}}
        else
          emit_message(
            on_message,
            :notification,
            %{
              payload: payload,
              raw: payload_string
            },
            metadata
          )

          Logger.debug("Codex notification: #{inspect(method)}")
          continue_or_timeout(port, on_message, stream_context, method, payload)
        end
    end
  end

  defp maybe_handle_approval_request(
         port,
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         context
       ) do
    approve_command_or_refuse(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      context
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         context
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    result =
      tool_name
      |> context.tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    send_message(port, %{
      "id" => id,
      "result" => result
    })

    event =
      case result do
        %{"success" => true} -> :tool_call_completed
        _ when is_nil(tool_name) -> :unsupported_tool_call
        _ -> :tool_call_failed
      end

    emit_message(context.on_message, event, %{payload: payload, raw: payload_string, result: result}, context.metadata)

    :approved
  end

  defp maybe_handle_approval_request(
         port,
         "execCommandApproval",
         %{"id" => id} = payload,
         payload_string,
         context
       ) do
    approve_command_or_refuse(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      context
    )
  end

  defp maybe_handle_approval_request(
         port,
         "applyPatchApproval",
         %{"id" => id} = payload,
         payload_string,
         context
       ) do
    approve_or_require(
      port,
      id,
      "approved_for_session",
      payload,
      payload_string,
      context.on_message,
      context.metadata,
      context.auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         payload_string,
         context
       ) do
    approve_or_require(
      port,
      id,
      "acceptForSession",
      payload,
      payload_string,
      context.on_message,
      context.metadata,
      context.auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/tool/requestUserInput",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         context
       ) do
    maybe_auto_answer_tool_request_user_input(
      port,
      id,
      params,
      payload,
      payload_string,
      context.on_message,
      context.metadata,
      context.auto_approve_requests
    )
  end

  defp maybe_handle_approval_request(
         port,
         "item/permissions/requestApproval",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         %{auto_approve_requests: true} = context
       ) do
    response = permissions_request_approval_response(params)
    send_message(port, %{"id" => id, "result" => response})

    emit_message(
      context.on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: "permissions:session"},
      context.metadata
    )

    :approved
  end

  defp maybe_handle_approval_request(
         _port,
         "item/permissions/requestApproval",
         _payload,
         _payload_string,
         %{auto_approve_requests: false}
       ) do
    :approval_required
  end

  defp maybe_handle_approval_request(
         port,
         "mcpServer/elicitation/request",
         %{"id" => id, "params" => params} = payload,
         payload_string,
         %{auto_approve_requests: true} = context
       ) do
    response = mcp_server_elicitation_response(params)
    send_message(port, %{"id" => id, "result" => response})

    emit_message(
      context.on_message,
      :mcp_elicitation_auto_answered,
      %{payload: payload, raw: payload_string, decision: response["action"]},
      context.metadata
    )

    :approved
  end

  defp maybe_handle_approval_request(
         _port,
         "mcpServer/elicitation/request",
         _payload,
         _payload_string,
         %{auto_approve_requests: false}
       ) do
    :approval_required
  end

  defp maybe_handle_approval_request(
         _port,
         _method,
         _payload,
         _payload_string,
         _context
       ) do
    :unhandled
  end

  defp normalize_dynamic_tool_result(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) -> existing_items
        _ -> dynamic_tool_content_items(output)
      end

    result
    |> Map.put("output", output)
    |> Map.put("contentItems", content_items)
  end

  defp normalize_dynamic_tool_result(result) do
    %{
      "success" => false,
      "output" => inspect(result),
      "contentItems" => dynamic_tool_content_items(inspect(result))
    }
  end

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp approve_command_or_refuse(
         port,
         id,
         decision,
         payload,
         payload_string,
         context
       ) do
    case command_refusal(payload, context.approval_context.command_security) do
      {:refuse, refusal} ->
        send_message(port, %{
          "id" => id,
          "result" => %{
            "decision" => "reject",
            "message" => refusal.message
          }
        })

        record_refused_agent_action(context.approval_context, payload, refusal)

        emit_message(
          context.on_message,
          :approval_refused,
          %{payload: payload, raw: payload_string, decision: "reject", refusal: refusal},
          context.metadata
        )

        :approved

      :allow ->
        command = command_from_payload(payload)

        case maybe_deny_pr_create_for_dependency_hold(
               port,
               id,
               dependency_hold_denial_decision(decision),
               command,
               payload,
               payload_string,
               context
             ) do
          :not_held ->
            approve_or_require(
              port,
              id,
              decision,
              payload,
              payload_string,
              context.on_message,
              context.metadata,
              context.auto_approve_requests
            )

          held ->
            held
        end
    end
  end

  defp dependency_hold_denial_decision("acceptForSession"), do: "deny"
  defp dependency_hold_denial_decision("approved_for_session"), do: "denied"
  defp dependency_hold_denial_decision(_decision), do: "reject"

  defp approve_or_require(
         port,
         id,
         decision,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    send_message(port, %{"id" => id, "result" => %{"decision" => decision}})

    emit_message(
      on_message,
      :approval_auto_approved,
      %{payload: payload, raw: payload_string, decision: decision},
      metadata
    )

    :approved
  end

  defp approve_or_require(
         _port,
         _id,
         _decision,
         _payload,
         _payload_string,
         _on_message,
         _metadata,
         false
       ) do
    :approval_required
  end

  defp command_refusal(payload, command_security) do
    command = command_from_payload(payload)
    tokens = command_tokens(command)

    secret_path_refusal(tokens, command) ||
      gh_pr_create_refusal(tokens, command, command_security) ||
      git_push_refusal(tokens, command, command_security) ||
      git_remote_refusal(tokens, command, command_security) ||
      :allow
  end

  defp secret_path_refusal(tokens, command) do
    if secret_path = denied_secret_path(tokens) do
      {:refuse,
       refusal(
         "secret_file_read",
         "deny_listed_secret_path",
         "Refused command because it references deny-listed secret path #{inspect(secret_path)}.",
         command,
         %{path: secret_path}
       )}
    end
  end

  defp gh_pr_create_refusal(tokens, command, command_security) do
    with pr_repo when is_binary(pr_repo) <- gh_pr_create_repo(tokens),
         allowed_repo <- Map.get(command_security || %{}, :origin_repo),
         false <- same_repo?(pr_repo, allowed_repo) do
      {:refuse,
       refusal(
         "gh_pr_create",
         "pr_target_repo_not_allowed",
         "Refused gh pr create because target repo #{inspect(pr_repo)} does not match configured origin #{inspect(allowed_repo)}.",
         command,
         %{target_repo: pr_repo, allowed_repo: allowed_repo}
       )}
    else
      _ -> nil
    end
  end

  defp git_push_refusal(tokens, command, command_security) do
    with push_target when is_binary(push_target) <- git_push_target(tokens),
         false <- allowed_git_push_target?(push_target, command_security) do
      {:refuse,
       refusal(
         "git_push",
         "git_remote_not_allowed",
         "Refused git push because target #{inspect(push_target)} is not the configured origin.",
         command,
         %{
           target: push_target,
           allowed_remote: "origin",
           allowed_origin_url: Map.get(command_security || %{}, :origin_url)
         }
       )}
    else
      _ -> nil
    end
  end

  defp git_remote_refusal(tokens, command, command_security) do
    with remote_set when is_map(remote_set) <- git_remote_mutation(tokens),
         false <- allowed_git_remote_mutation?(remote_set, command_security) do
      {:refuse,
       refusal(
         "git_remote_#{remote_set.action}",
         "git_remote_not_allowed",
         "Refused git remote #{remote_set.action} because it does not match the configured origin.",
         command,
         %{
           remote_name: remote_set.name,
           remote_url: remote_set.url,
           allowed_remote: "origin",
           allowed_origin_url: Map.get(command_security || %{}, :origin_url)
         }
       )}
    else
      _ -> nil
    end
  end

  defp refusal(action, reason, message, command, details) do
    %{
      action: action,
      reason: reason,
      message: message,
      command: command,
      details: details
    }
  end

  defp record_refused_agent_action(approval_context, payload, refusal) do
    issue = Map.get(approval_context, :issue) || %{}

    opts =
      approval_context
      |> Map.get(:audit_log_opts, [])
      |> Keyword.put_new(:repo_key, Map.get(approval_context, :repo_key))

    attrs =
      %{
        action: refusal.action,
        reason: refusal.reason,
        message: refusal.message,
        command: refusal.command,
        method: payload_method(payload),
        cwd: get_in(payload, ["params", "cwd"]),
        details: refusal.details
      }

    case AuditLog.record_refused_agent_action(issue, attrs, opts) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Audit log refused-action write failed: #{inspect(reason)}")
    end
  end

  defp payload_method(payload) when is_map(payload), do: Map.get(payload, "method") || Map.get(payload, :method)

  defp command_tokens(command) when is_binary(command) do
    command
    |> OptionParser.split()
    |> Enum.flat_map(&split_shell_control_tokens/1)
  rescue
    _exception ->
      command
      |> String.split(~r/\s+/, trim: true)
      |> Enum.flat_map(&split_shell_control_tokens/1)
  end

  defp command_tokens(_command), do: []

  defp split_shell_control_tokens(token) when is_binary(token) do
    token
    |> String.split(~r/(;|&&|\|\|)/, include_captures: true, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp denied_secret_path(tokens) do
    Enum.find_value(tokens, fn token ->
      token
      |> option_value()
      |> secret_path()
    end)
  end

  defp secret_path(token) when is_binary(token) do
    normalized = token |> String.trim() |> String.trim_trailing(":")
    basename = Path.basename(normalized)

    cond do
      String.starts_with?(normalized, ["~/.ssh/", "~/.aws/", "~/.config/gh/"]) ->
        normalized

      String.contains?(normalized, ["/.ssh/", "/.aws/", "/.config/gh/"]) ->
        normalized

      String.starts_with?(basename, ".env") ->
        normalized

      String.ends_with?(String.downcase(basename), [".pem", ".key"]) ->
        normalized

      true ->
        nil
    end
  end

  defp option_value(token) when is_binary(token) do
    case String.split(token, "=", parts: 2) do
      [_option, value] -> value
      [value] -> value
    end
  end

  defp gh_pr_create_repo(tokens) do
    tokens
    |> command_windows("gh")
    |> Enum.find_value(fn gh_tokens ->
      if gh_pr_create?(gh_tokens), do: option_argument(gh_tokens, ["--repo", "-R"]), else: nil
    end)
    |> normalize_repo_target()
  end

  defp gh_pr_create?(tokens) do
    case ordered_index(tokens, "pr") do
      nil ->
        false

      pr_index ->
        Enum.at(tokens, pr_index + 1) == "create"
    end
  end

  defp git_push_target(tokens) do
    tokens
    |> command_windows("git")
    |> Enum.find_value(fn
      ["git", "push" | push_args] -> first_git_push_target(push_args)
      ["git" | rest] -> rest |> skip_global_git_options() |> match_git_push_target()
      _tokens -> nil
    end)
  end

  defp match_git_push_target(["push" | push_args]), do: first_git_push_target(push_args)
  defp match_git_push_target(_tokens), do: nil

  defp first_git_push_target(push_args) do
    push_args
    |> skip_options()
    |> List.first()
    |> case do
      nil -> "origin"
      target -> target
    end
  end

  defp git_remote_mutation(tokens) do
    tokens
    |> command_windows("git")
    |> Enum.find_value(fn
      ["git", "remote" | remote_args] -> parse_git_remote_mutation(remote_args)
      ["git" | rest] -> rest |> skip_global_git_options() |> match_git_remote_mutation()
      _tokens -> nil
    end)
  end

  defp match_git_remote_mutation(["remote" | remote_args]), do: parse_git_remote_mutation(remote_args)
  defp match_git_remote_mutation(_tokens), do: nil

  defp parse_git_remote_mutation(["add" | args]) do
    args = skip_options(args)
    %{action: "add", name: Enum.at(args, 0), url: Enum.at(args, 1)}
  end

  defp parse_git_remote_mutation(["set-url" | args]) do
    args = skip_options(args)
    %{action: "set_url", name: Enum.at(args, 0), url: Enum.at(args, 1)}
  end

  defp parse_git_remote_mutation(_args), do: nil

  defp command_windows(tokens, command) do
    tokens
    |> Enum.with_index()
    |> Enum.filter(fn {token, _index} -> token == command end)
    |> Enum.map(fn {_token, index} ->
      tokens
      |> Enum.drop(index)
      |> Enum.take_while(&(&1 not in [";", "&&", "||"]))
    end)
  end

  defp ordered_index(tokens, wanted) do
    Enum.find_index(tokens, &(&1 == wanted))
  end

  defp option_argument(tokens, names) do
    Enum.find_value(Enum.with_index(tokens), fn {token, index} ->
      cond do
        token in names ->
          Enum.at(tokens, index + 1)

        String.starts_with?(token, "--repo=") and "--repo" in names ->
          token |> String.split("=", parts: 2) |> List.last()

        true ->
          nil
      end
    end)
  end

  defp skip_global_git_options(["-C", _path | rest]), do: skip_global_git_options(rest)
  defp skip_global_git_options(["-c", _config | rest]), do: skip_global_git_options(rest)

  defp skip_global_git_options([option | rest]) when is_binary(option) do
    if String.starts_with?(option, ["--git-dir=", "--work-tree=", "-"]) do
      skip_global_git_options(rest)
    else
      [option | rest]
    end
  end

  defp skip_global_git_options(tokens), do: tokens

  defp skip_options([option, _value | rest]) when option in ["--repo", "-R", "--push-option", "-o"], do: skip_options(rest)

  defp skip_options([option | rest]) when is_binary(option) do
    if String.starts_with?(option, "-"), do: skip_options(rest), else: [option | rest]
  end

  defp skip_options(tokens), do: tokens

  defp allowed_git_push_target?("origin", _command_security), do: true

  defp allowed_git_push_target?(target, command_security) when is_binary(target) do
    allowed_origin_url = Map.get(command_security || %{}, :origin_url)
    allowed_repo = Map.get(command_security || %{}, :origin_repo)

    cond do
      same_origin_url?(target, allowed_origin_url) -> true
      same_repo?(normalize_repo_target(target), allowed_repo) -> true
      true -> false
    end
  end

  defp allowed_git_remote_mutation?(%{name: "origin", url: url}, command_security) when is_binary(url) do
    same_origin_url?(url, Map.get(command_security || %{}, :origin_url)) or
      same_repo?(normalize_repo_target(url), Map.get(command_security || %{}, :origin_repo))
  end

  defp allowed_git_remote_mutation?(_remote_set, _command_security), do: false

  defp same_origin_url?(left, right) when is_binary(left) and is_binary(right) do
    normalize_git_url(left) == normalize_git_url(right)
  end

  defp same_origin_url?(_left, _right), do: false

  defp same_repo?(left, right) when is_binary(left) and is_binary(right), do: String.downcase(left) == String.downcase(right)
  defp same_repo?(_left, _right), do: false

  defp normalize_repo_target(target) when is_binary(target) do
    github_repo_from_url(target) ||
      case Regex.run(~r{^([^/\s:]+)/([^/\s:]+?)(?:\.git)?$}, target) do
        [_full, owner, repo] -> "#{owner}/#{repo}"
        _ -> target
      end
  end

  defp normalize_repo_target(_target), do: nil

  defp github_repo_from_url(url) when is_binary(url) do
    Enum.find_value(
      [
        ~r{github[^/:]*[/:]([^/\s:]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^https?://[^/]+/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$},
        ~r{^ssh://[^@]+@[^/]+/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$}
      ],
      fn regex ->
        case Regex.run(regex, url) do
          [_full, owner, repo] -> "#{owner}/#{repo}"
          _ -> nil
        end
      end
    )
  end

  defp github_repo_from_url(_url), do: nil

  defp normalize_git_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.downcase()
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         true
       ) do
    case tool_request_user_input_approval_answers(params) do
      {:ok, answers, decision} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :approval_auto_approved,
          %{payload: payload, raw: payload_string, decision: decision},
          metadata
        )

        :approved

      :error ->
        reply_with_non_interactive_tool_input_answer(
          port,
          id,
          params,
          payload,
          payload_string,
          on_message,
          metadata
        )
    end
  end

  defp maybe_auto_answer_tool_request_user_input(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata,
         false
       ) do
    reply_with_non_interactive_tool_input_answer(
      port,
      id,
      params,
      payload,
      payload_string,
      on_message,
      metadata
    )
  end

  defp tool_request_user_input_approval_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_approval_answer(question) do
          {:ok, question_id, answer_label} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [answer_label]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map, "Approve this Session"}
      _ -> :error
    end
  end

  defp tool_request_user_input_approval_answers(_params), do: :error

  defp reply_with_non_interactive_tool_input_answer(
         port,
         id,
         params,
         payload,
         payload_string,
         on_message,
         metadata
       ) do
    case tool_request_user_input_unavailable_answers(params) do
      {:ok, answers} ->
        send_message(port, %{"id" => id, "result" => %{"answers" => answers}})

        emit_message(
          on_message,
          :tool_input_auto_answered,
          %{payload: payload, raw: payload_string, answer: @non_interactive_tool_input_answer},
          metadata
        )

        :approved

      :error ->
        :input_required
    end
  end

  defp tool_request_user_input_unavailable_answers(%{"questions" => questions}) when is_list(questions) do
    answers =
      Enum.reduce_while(questions, %{}, fn question, acc ->
        case tool_request_user_input_question_id(question) do
          {:ok, question_id} ->
            {:cont, Map.put(acc, question_id, %{"answers" => [@non_interactive_tool_input_answer]})}

          :error ->
            {:halt, :error}
        end
      end)

    case answers do
      :error -> :error
      answer_map when map_size(answer_map) > 0 -> {:ok, answer_map}
      _ -> :error
    end
  end

  defp tool_request_user_input_unavailable_answers(_params), do: :error

  defp permissions_request_approval_response(%{"permissions" => requested_permissions})
       when is_map(requested_permissions) do
    %{
      "permissions" => grant_requested_permissions(requested_permissions),
      "scope" => "session"
    }
  end

  defp permissions_request_approval_response(_params) do
    %{"permissions" => %{}, "scope" => "session"}
  end

  defp grant_requested_permissions(requested_permissions) do
    requested_permissions
    |> Enum.reduce(%{}, fn
      {"network", network_permissions}, acc when is_map(network_permissions) ->
        Map.put(acc, "network", network_permissions)

      {"fileSystem", file_system_permissions}, acc when is_map(file_system_permissions) ->
        Map.put(acc, "fileSystem", file_system_permissions)

      _field, acc ->
        acc
    end)
  end

  defp mcp_server_elicitation_response(%{"mode" => "url"}) do
    %{"action" => "accept", "content" => nil, "_meta" => nil}
  end

  defp mcp_server_elicitation_response(%{"mode" => "form", "requestedSchema" => schema})
       when is_map(schema) do
    %{"action" => "accept", "content" => mcp_elicitation_form_content(schema), "_meta" => nil}
  end

  defp mcp_server_elicitation_response(_params) do
    %{"action" => "accept", "content" => %{}, "_meta" => nil}
  end

  defp mcp_elicitation_form_content(%{"properties" => properties} = schema)
       when is_map(properties) do
    required =
      schema
      |> Map.get("required", [])
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    Enum.reduce(properties, %{}, fn {field, field_schema}, acc ->
      cond do
        not is_binary(field) ->
          acc

        not is_map(field_schema) ->
          acc

        Map.has_key?(field_schema, "default") ->
          Map.put(acc, field, field_schema["default"])

        MapSet.member?(required, field) ->
          Map.put(acc, field, mcp_elicitation_field_fallback(field, field_schema))

        true ->
          acc
      end
    end)
  end

  defp mcp_elicitation_form_content(_schema), do: %{}

  defp mcp_elicitation_field_fallback(_field, %{"const" => value}), do: value

  defp mcp_elicitation_field_fallback(field, %{"oneOf" => [first | _]}) when is_map(first),
    do: mcp_elicitation_field_fallback(field, first)

  defp mcp_elicitation_field_fallback(field, %{"anyOf" => [first | _]}) when is_map(first),
    do: mcp_elicitation_field_fallback(field, first)

  defp mcp_elicitation_field_fallback(_field, %{"enum" => [first | _]}), do: first

  defp mcp_elicitation_field_fallback(field, %{"type" => "boolean"} = field_schema),
    do: approval_boolean_field?(field, field_schema)

  defp mcp_elicitation_field_fallback(_field, %{"type" => type})
       when type in ["number", "integer"],
       do: 0

  defp mcp_elicitation_field_fallback(_field, %{"type" => "array"}), do: []
  defp mcp_elicitation_field_fallback(_field, _field_schema), do: @non_interactive_tool_input_answer

  defp approval_boolean_field?(field, field_schema) do
    [field, field_schema["title"], field_schema["description"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(&String.contains?(&1, ["accept", "access", "allow", "approve", "authorize", "confirm", "consent"]))
  end

  defp tool_request_user_input_question_id(%{"id" => question_id}) when is_binary(question_id),
    do: {:ok, question_id}

  defp tool_request_user_input_question_id(_question), do: :error

  defp tool_request_user_input_approval_answer(%{"id" => question_id, "options" => options})
       when is_binary(question_id) and is_list(options) do
    case tool_request_user_input_approval_option_label(options) do
      nil -> :error
      answer_label -> {:ok, question_id, answer_label}
    end
  end

  defp tool_request_user_input_approval_answer(_question), do: :error

  defp tool_request_user_input_approval_option_label(options) do
    options
    |> Enum.map(&tool_request_user_input_option_label/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      labels ->
        Enum.find(labels, &(&1 == "Approve this Session")) ||
          Enum.find(labels, &(&1 == "Approve Once")) ||
          Enum.find(labels, &approval_option_label?/1)
    end
  end

  defp tool_request_user_input_option_label(%{"label" => label}) when is_binary(label), do: label
  defp tool_request_user_input_option_label(_option), do: nil

  defp approval_option_label?(label) when is_binary(label) do
    normalized_label =
      label
      |> String.trim()
      |> String.downcase()

    String.starts_with?(normalized_label, "approve") or String.starts_with?(normalized_label, "allow")
  end

  defp dependency_gate_context(workspace, issue, settings, opts) do
    %{
      workspace: workspace,
      issue: issue,
      settings: settings,
      repo_key: Keyword.get(opts, :repo_key),
      audit_module: Keyword.get(opts, :dependency_audit_module, DependencyAudit),
      base_ref: Keyword.get(opts, :dependency_audit_base_ref),
      command_runner: Keyword.get(opts, :dependency_audit_command_runner)
    }
  end

  defp maybe_deny_pr_create_for_dependency_hold(
         port,
         id,
         denial_decision,
         command,
         payload,
         payload_string,
         context
       ) do
    dependency_gate = get_in(context, [:approval_context, :dependency_gate])

    if dependency_gate && DependencyAudit.git_pr_create_command?(command) do
      case audit_pr_create_dependencies(dependency_gate) do
        {:ok, []} ->
          :not_held

        {:hold, items} ->
          send_message(port, %{"id" => id, "result" => %{"decision" => denial_decision}})
          maybe_move_dependency_hold_issue(dependency_gate)
          emit_dependency_hold_event(dependency_gate, items)

          emit_message(
            context.on_message,
            :dependency_pending_approval,
            %{payload: payload, raw: payload_string, command: command, items: items},
            context.metadata
          )

          :approved

        {:error, reason} ->
          Logger.error("Dependency audit failed during gh pr create approval: #{inspect(reason)}")

          send_message(port, %{"id" => id, "result" => %{"decision" => denial_decision}})
          maybe_move_dependency_hold_issue(dependency_gate)
          emit_dependency_audit_failure_event(dependency_gate, reason)

          emit_message(
            context.on_message,
            :dependency_pending_approval,
            %{payload: payload, raw: payload_string, command: command, error: reason},
            context.metadata
          )

          :approved
      end
    else
      :not_held
    end
  end

  defp audit_pr_create_dependencies(%{workspace: workspace, audit_module: audit_module} = gate)
       when is_binary(workspace) and is_atom(audit_module) do
    audit_opts =
      [
        repo_key: gate.repo_key,
        settings: gate.settings
      ]
      |> maybe_put_dependency_gate_option(:base_ref, gate.base_ref)
      |> maybe_put_dependency_gate_option(:command_runner, gate.command_runner)

    audit_module.audit(workspace, audit_opts)
  end

  defp audit_pr_create_dependencies(_gate), do: {:ok, []}

  defp maybe_put_dependency_gate_option(opts, _key, nil), do: opts
  defp maybe_put_dependency_gate_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_move_dependency_hold_issue(%{issue: %{id: issue_id}}) when is_binary(issue_id) do
    case Tracker.update_issue_state(issue_id, "In Review") do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Failed to move dependency hold issue to In Review: #{inspect(reason)}")
    end
  end

  defp maybe_move_dependency_hold_issue(_gate), do: :ok

  defp emit_dependency_hold_event(%{issue: issue} = gate, items) do
    Notifications.emit_issue_event(
      :dependency_pending_approval,
      issue,
      %{
        repo_key: gate.repo_key,
        state: "In Review",
        reason: "dependency_source_requires_approval",
        metadata: DependencyAudit.approval_metadata(items)
      }
    )
  end

  defp emit_dependency_audit_failure_event(%{issue: issue} = gate, error) do
    Notifications.emit_issue_event(
      :dependency_pending_approval,
      issue,
      %{
        repo_key: gate.repo_key,
        state: "In Review",
        reason: "dependency_audit_failed",
        metadata: %{audit_error: inspect(error)}
      }
    )
  end

  defp initial_turn_stream_state(command_timeout_ms) do
    %{
      command_timeout_ms: normalize_command_timeout_ms(command_timeout_ms),
      active_command: nil
    }
  end

  defp normalize_command_timeout_ms(timeout_ms) when is_integer(timeout_ms), do: timeout_ms
  defp normalize_command_timeout_ms(_timeout_ms), do: 0

  defp continue_or_timeout(port, on_message, stream_context, method, payload) do
    turn_stream_state =
      update_command_tracking(stream_context.turn_stream_state, method, payload)

    case command_timeout_error(turn_stream_state) do
      :ok ->
        receive_loop(
          port,
          on_message,
          stream_context.timeout_ms,
          "",
          stream_context.tool_executor,
          stream_context.auto_approve_requests,
          stream_context.approval_context,
          turn_stream_state
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_timeout_ms(turn_timeout_ms, %{active_command: nil}), do: turn_timeout_ms

  defp receive_timeout_ms(turn_timeout_ms, %{active_command: %{started_at_ms: started_at_ms}, command_timeout_ms: command_timeout_ms})
       when is_integer(started_at_ms) and is_integer(command_timeout_ms) and command_timeout_ms > 0 do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms
    min(turn_timeout_ms, max(0, command_timeout_ms - elapsed_ms))
  end

  defp receive_timeout_ms(turn_timeout_ms, _turn_stream_state), do: turn_timeout_ms

  defp command_timeout_error(%{active_command: nil}), do: :ok
  defp command_timeout_error(%{command_timeout_ms: timeout_ms}) when timeout_ms <= 0, do: :ok

  defp command_timeout_error(%{
         active_command: %{started_at_ms: started_at_ms} = active_command,
         command_timeout_ms: timeout_ms
       })
       when is_integer(started_at_ms) and is_integer(timeout_ms) do
    elapsed_ms = max(0, System.monotonic_time(:millisecond) - started_at_ms)

    if elapsed_ms >= timeout_ms do
      {:error,
       {:command_timeout,
        %{
          command: Map.get(active_command, :command),
          elapsed_ms: elapsed_ms,
          timeout_ms: timeout_ms
        }}}
    else
      :ok
    end
  end

  defp command_timeout_error(_turn_stream_state), do: :ok

  defp update_command_tracking(turn_stream_state, "item/commandExecution/requestApproval", payload) do
    start_command_tracking(turn_stream_state, command_from_payload(payload))
  end

  defp update_command_tracking(turn_stream_state, "item/started", payload) do
    if command_execution_item?(payload) do
      start_command_tracking(turn_stream_state, command_from_payload(payload))
    else
      turn_stream_state
    end
  end

  defp update_command_tracking(turn_stream_state, "item/completed", payload) do
    if command_execution_item?(payload) do
      complete_command_tracking(turn_stream_state)
    else
      turn_stream_state
    end
  end

  defp update_command_tracking(turn_stream_state, "codex/event/exec_command_begin", payload) do
    start_command_tracking(turn_stream_state, command_from_payload(payload))
  end

  defp update_command_tracking(turn_stream_state, "codex/event/exec_command_end", _payload) do
    complete_command_tracking(turn_stream_state)
  end

  defp update_command_tracking(turn_stream_state, _method, _payload), do: turn_stream_state

  defp start_command_tracking(turn_stream_state, command) do
    Map.put(turn_stream_state, :active_command, %{
      command: command,
      started_at_ms: System.monotonic_time(:millisecond)
    })
  end

  defp complete_command_tracking(turn_stream_state), do: Map.put(turn_stream_state, :active_command, nil)

  defp command_execution_item?(payload) do
    payload
    |> item_type()
    |> case do
      "commandExecution" -> true
      "command_execution" -> true
      _ -> false
    end
  end

  defp item_type(payload) do
    get_in(payload, ["params", "item", "type"]) ||
      get_in(payload, ["params", "msg", "payload", "type"])
  end

  defp command_from_payload(payload) do
    [
      ["params", "parsedCmd"],
      ["params", "command"],
      ["params", "cmd"],
      ["params", "argv"],
      ["params", "args"],
      ["params", "item", "command"],
      ["params", "item", "parsedCmd"],
      ["params", "msg", "command"],
      ["params", "msg", "parsed_cmd"],
      ["params", "msg", "payload", "command"],
      ["params", "msg", "payload", "parsed_cmd"]
    ]
    |> Enum.find_value(&get_in(payload, &1))
    |> normalize_command()
  end

  defp normalize_command(%{} = command) do
    binary_command = command["parsedCmd"] || command["command"] || command["cmd"]
    args = command["args"] || command["argv"]

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> normalize_command()
    else
      nil
    end
  end

  defp normalize_command(_command), do: nil

  defp await_response(port, request_id, settings) do
    with_timeout_response(port, request_id, settings.agent.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Codex #{stream_label} output: #{text}")
      else
        Logger.debug("Codex #{stream_label} output: #{text}")
      end
    end
  end

  defp protocol_message_candidate?(data) do
    data
    |> to_string()
    |> String.trim_leading()
    |> String.starts_with?("{")
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp metadata_from_message(port, payload) do
    port |> port_metadata(nil) |> maybe_set_usage(payload)
  end

  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp maybe_set_usage(metadata, _payload), do: metadata

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    case Map.get(params, "tool") || Map.get(params, :tool) || Map.get(params, "name") || Map.get(params, :name) do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp tool_call_arguments(params) when is_map(params) do
    Map.get(params, "arguments") || Map.get(params, :arguments) || %{}
  end

  defp tool_call_arguments(_params), do: %{}

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false
end
