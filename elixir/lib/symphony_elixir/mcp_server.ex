defmodule SymphonyElixir.McpServer do
  @moduledoc false

  use GenServer

  require Logger

  alias SymphonyElixir.Codex.DynamicTool
  alias SymphonyElixir.DependencyGate

  @server_name "symphony"
  @protocol_version "2025-06-18"
  @auth_header "symphony-session-token"
  @header_separator "\r\n\r\n"

  @type session :: %{
          id: String.t(),
          socket_path: Path.t(),
          socket_dir: Path.t(),
          remote_socket_path: Path.t() | nil,
          token: String.t(),
          shim_path: Path.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec start_session(map(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(context, opts \\ []) when is_map(context) do
    with {:ok, server} <- ensure_server(opts) do
      GenServer.call(server, {:start_session, context, opts})
    end
  end

  @doc false
  @spec remote_socket_path(String.t()) :: Path.t()
  def remote_socket_path(id) when is_binary(id) do
    Path.join("/tmp", "symphony-mcp-#{id}.sock")
  end

  @spec stop_session(session() | nil) :: :ok
  def stop_session(session), do: stop_session(session, [])

  @spec stop_session(session() | nil, keyword()) :: :ok
  def stop_session(nil, _opts), do: :ok

  def stop_session(%{id: id}, opts) when is_binary(id) do
    case server_pid(opts) do
      nil -> :ok
      server -> GenServer.call(server, {:stop_session, id})
    end
  catch
    :exit, _reason -> :ok
  end

  @doc false
  @spec tool_specs() :: [map()]
  def tool_specs, do: DynamicTool.tool_specs()

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}, tokens: %{}, acceptors: %{}}}
  end

  @impl true
  def handle_call({:start_session, context, opts}, _from, state) do
    id = token()

    case open_and_secure_socket(opts, id) do
      {:ok, socket_dir, socket_path, listen_socket} ->
        session_token = token()
        server = self()
        {acceptor_pid, acceptor_ref} = spawn_acceptor(server, listen_socket)
        remote_socket_path = compute_remote_socket_path(id, opts)

        session = %{
          context: context,
          socket_dir: socket_dir,
          socket_path: socket_path,
          listen_socket: listen_socket,
          acceptor: acceptor_pid,
          acceptor_ref: acceptor_ref,
          connections: MapSet.new()
        }

        reply = %{
          id: id,
          socket_dir: socket_dir,
          socket_path: socket_path,
          remote_socket_path: remote_socket_path,
          token: session_token,
          shim_path: shim_path(opts)
        }

        {:reply, {:ok, reply},
         %{
           state
           | sessions: Map.put(state.sessions, id, session),
             tokens: Map.put(state.tokens, session_token, id),
             acceptors: Map.put(state.acceptors, acceptor_ref, id)
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_session, id}, _from, state) do
    {:reply, :ok, cleanup_session(state, id)}
  end

  def handle_call({:claim, token}, _from, state) do
    case Map.fetch(state.tokens, token) do
      {:ok, id} ->
        session = Map.fetch!(state.sessions, id)
        {:reply, {:ok, id, session.context}, %{state | tokens: Map.delete(state.tokens, token)}}

      :error ->
        {:reply, {:error, :invalid_session_token}, state}
    end
  end

  @impl true
  def handle_cast({:connection_started, id, pid}, state) when is_binary(id) and is_pid(pid) do
    Process.monitor(pid)

    sessions =
      update_in(state.sessions, [id, :connections], fn
        nil -> MapSet.new([pid])
        connections -> MapSet.put(connections, pid)
      end)

    {:noreply, %{state | sessions: sessions}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.fetch(state.acceptors, ref) do
      {:ok, session_id} ->
        Logger.warning("MCP acceptor process exited session=#{session_id} reason=#{inspect(reason)}; cleaning up")

        state = %{state | acceptors: Map.delete(state.acceptors, ref)}
        {:noreply, cleanup_session(state, session_id)}

      :error ->
        sessions =
          Map.new(state.sessions, fn {id, session} ->
            {id, %{session | connections: MapSet.delete(session.connections, pid)}}
          end)

        {:noreply, %{state | sessions: sessions}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.keys(state.sessions), &cleanup_session(state, &1))
    :ok
  end

  defp ensure_server(opts) do
    case server_pid(opts) do
      nil -> start_link(name: Keyword.get(opts, :server, __MODULE__))
      pid -> {:ok, pid}
    end
  end

  defp server_pid(opts) do
    opts
    |> Keyword.get(:server, __MODULE__)
    |> Process.whereis()
  end

  defp session_socket_paths(opts, id) do
    case Keyword.get(opts, :socket_path) do
      path when is_binary(path) and path != "" ->
        {:ok, Path.dirname(path), path}

      _ ->
        segment = run_id_segment(opts) || id
        dir = Path.join("/tmp", "symphony-mcp-#{segment}")
        {:ok, dir, Path.join(dir, "sock")}
    end
  end

  defp run_id_segment(opts) do
    case Keyword.get(opts, :run_id) do
      value when is_binary(value) and value != "" -> to_socket_segment(value)
      _ -> nil
    end
  end

  defp to_socket_segment(value) when is_binary(value) and value != "" do
    value
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "-")
    |> String.slice(0, 80)
  end

  defp prepare_socket_dir(dir) when is_binary(dir) do
    if managed_socket_dir?(dir) do
      _ = File.rm_rf(dir)

      with :ok <- File.mkdir_p(dir),
           :ok <- File.chmod(dir, 0o700) do
        :ok
      else
        {:error, reason} -> {:error, {:mcp_socket_dir_failed, dir, reason}}
      end
    else
      case File.mkdir_p(dir) do
        :ok -> :ok
        {:error, reason} -> {:error, {:mcp_socket_dir_failed, dir, reason}}
      end
    end
  end

  defp open_and_secure_socket(opts, id) do
    with {:ok, socket_dir, socket_path} <- session_socket_paths(opts, id),
         :ok <- prepare_socket_dir(socket_dir),
         {:ok, listen_socket} <- open_listen_socket(socket_path) do
      case File.chmod(socket_path, 0o600) do
        :ok ->
          {:ok, socket_dir, socket_path, listen_socket}

        {:error, reason} ->
          tear_down_socket(socket_dir, socket_path, listen_socket)
          {:error, {:mcp_socket_chmod_failed, reason}}
      end
    end
  end

  defp open_listen_socket(path) do
    with {:ok, socket} <- :socket.open(:local, :stream),
         :ok <- :socket.bind(socket, %{family: :local, path: path}),
         :ok <- :socket.listen(socket) do
      {:ok, socket}
    else
      {:error, reason} -> {:error, {:mcp_socket_open_failed, reason}}
    end
  end

  defp tear_down_socket(socket_dir, socket_path, listen_socket) do
    close_socket(listen_socket)
    _ = remove_socket_file(socket_path)
    remove_socket_dir(socket_dir)
  end

  defp remove_socket_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:mcp_socket_remove_failed, path, reason}}
    end
  end

  defp remove_socket_dir(dir) when is_binary(dir) do
    if managed_socket_dir?(dir) do
      _ = File.rm_rf(dir)
    end

    :ok
  end

  defp remove_socket_dir(_dir), do: :ok

  defp managed_socket_dir?(dir) do
    String.starts_with?(dir, "/tmp/symphony-mcp-")
  end

  defp compute_remote_socket_path(id, opts) do
    case Keyword.get(opts, :worker_host) do
      worker when is_binary(worker) and worker != "" ->
        case Keyword.get(opts, :remote_socket_path) do
          path when is_binary(path) and path != "" -> path
          _ -> remote_socket_path(id)
        end

      _ ->
        nil
    end
  end

  defp spawn_acceptor(server, listen_socket) do
    {:ok, pid} = Task.start(fn -> accept_loop(server, listen_socket) end)
    ref = Process.monitor(pid)
    {pid, ref}
  end

  defp shim_path(opts) do
    case Keyword.get(opts, :shim_path) do
      path when is_binary(path) and path != "" -> path
      _ -> Application.app_dir(:symphony_elixir, "priv/bin/symphony-mcp-shim")
    end
  end

  defp cleanup_session(state, id) do
    case Map.fetch(state.sessions, id) do
      {:ok, session} ->
        Process.demonitor(session.acceptor_ref, [:flush])
        close_socket(session.listen_socket)
        Process.exit(session.acceptor, :shutdown)
        Enum.each(session.connections, &Process.exit(&1, :shutdown))
        _ = remove_socket_file(session.socket_path)
        remove_socket_dir(session.socket_dir)

        tokens =
          state.tokens
          |> Enum.reject(fn {_token, session_id} -> session_id == id end)
          |> Map.new()

        acceptors = Map.delete(state.acceptors, session.acceptor_ref)

        %{state | sessions: Map.delete(state.sessions, id), tokens: tokens, acceptors: acceptors}

      :error ->
        state
    end
  end

  defp close_socket(socket) do
    :socket.close(socket)
  catch
    :error, _reason -> :ok
  end

  defp accept_loop(server, listen_socket) do
    case :socket.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> authenticate_and_serve(server, socket) end)
        accept_loop(server, listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.debug("MCP accept loop stopped: #{inspect(reason)}")
        :ok
    end
  end

  defp authenticate_and_serve(server, socket) do
    authenticate_connection(server, socket)
  after
    close_socket(socket)
  end

  defp authenticate_connection(server, socket) do
    with {:ok, token, buffer} <- read_auth(socket, ""),
         {:ok, id, context} <- GenServer.call(server, {:claim, token}) do
      GenServer.cast(server, {:connection_started, id, self()})
      serve(socket, context, buffer)
    else
      {:error, reason} ->
        Logger.debug("MCP connection rejected: #{inspect(reason)}")
        :ok
    end
  end

  defp read_auth(socket, buffer) do
    case String.split(buffer, @header_separator, parts: 2) do
      [headers, rest] ->
        parse_auth_headers(headers, rest)

      [_incomplete] ->
        case :socket.recv(socket) do
          {:ok, data} -> read_auth(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_auth_headers(headers, rest) do
    case header_value(headers, @auth_header) do
      token when is_binary(token) and token != "" -> {:ok, token, rest}
      _ -> {:error, :missing_session_token}
    end
  end

  defp serve(socket, context, buffer) do
    case read_message(socket, buffer) do
      {:ok, payload, rest} ->
        maybe_send_response(socket, handle_payload(payload, context))
        serve(socket, context, rest)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.debug("MCP connection closed: #{inspect(reason)}")
        :ok
    end
  end

  defp read_message(socket, buffer) do
    case parse_message(buffer) do
      {:ok, payload, rest} ->
        {:ok, payload, rest}

      :more ->
        case :socket.recv(socket) do
          {:ok, data} -> read_message(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_message(buffer) do
    case String.split(buffer, @header_separator, parts: 2) do
      [headers, body_and_rest] ->
        with {:ok, length} <- content_length(headers) do
          parse_message_body(body_and_rest, length)
        end

      [_incomplete] ->
        :more
    end
  end

  defp content_length(headers) do
    headers
    |> header_value("content-length")
    |> parse_content_length()
  end

  defp parse_message_body(body_and_rest, length) do
    if byte_size(body_and_rest) >= length do
      <<body::binary-size(length), rest::binary>> = body_and_rest
      {:ok, Jason.decode!(body), rest}
    else
      :more
    end
  end

  defp header_value(headers, header_name) do
    headers
    |> String.split("\r\n", trim: true)
    |> Enum.find_value(&matching_header_value(&1, header_name))
  end

  defp matching_header_value(header, header_name) do
    case String.split(header, ":", parts: 2) do
      [key, value] ->
        if String.downcase(String.trim(key)) == header_name do
          String.trim(value)
        end

      _ ->
        nil
    end
  end

  defp parse_content_length(value) do
    value
    |> parse_integer()
    |> case do
      length when is_integer(length) and length >= 0 -> {:ok, length}
      _ -> {:error, :missing_content_length}
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp handle_payload(%{"id" => id, "method" => "initialize"} = payload, _context) do
    protocol_version = get_in(payload, ["params", "protocolVersion"]) || @protocol_version

    response(id, %{
      "protocolVersion" => protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => @server_name, "version" => "0.1.0"}
    })
  end

  defp handle_payload(%{"method" => "notifications/" <> _rest}, _context), do: nil

  defp handle_payload(%{"id" => id, "method" => "tools/list"}, _context) do
    response(id, %{"tools" => tool_specs()})
  end

  defp handle_payload(%{"id" => id, "method" => "tools/call", "params" => params}, context) do
    tool = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})
    result = execute_tool(tool, arguments, context)

    response(id, %{
      "content" => [%{"type" => "text", "text" => Map.get(result, "output", "")}],
      "isError" => Map.get(result, "success") != true
    })
  end

  defp handle_payload(%{"id" => id, "method" => method}, _context) do
    error_response(id, -32_601, "Unsupported MCP method: #{method}")
  end

  defp handle_payload(_payload, _context), do: nil

  defp response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error_response(id, code, message) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
  end

  defp maybe_send_response(_socket, nil), do: :ok

  defp maybe_send_response(socket, payload) do
    body = Jason.encode!(payload)
    :ok = :socket.send(socket, "Content-Length: #{byte_size(body)}\r\n\r\n#{body}")
  end

  defp tool_opts(context) do
    context
    |> Map.get(:tool_opts, [])
    |> Keyword.merge(
      issue: Map.get(context, :issue),
      issue_id: Map.get(context, :issue_id),
      workspace: Map.get(context, :workspace),
      command_security: Map.get(context, :command_security) || %{},
      comment_registry: Map.get(context, :comment_registry)
    )
  end

  defp execute_tool(tool, arguments, context) do
    case DependencyGate.evaluate_pr_create_tool(tool, Map.get(context, :dependency_gate)) do
      :allow ->
        DynamicTool.execute(tool, arguments, tool_opts(context))

      {:hold, items, failure} ->
        DependencyGate.react_to_hold(Map.fetch!(context, :dependency_gate), items)
        failure

      {:audit_error, reason, failure} ->
        Logger.error("Dependency audit failed during MCP github_create_pull_request: #{inspect(reason)}")

        DependencyGate.react_to_audit_error(Map.fetch!(context, :dependency_gate), reason)
        failure
    end
  end

  defp token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
