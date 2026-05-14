defmodule SymphonyElixir.McpServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.McpServer

  test "lists scoped Linear and GitHub tools over a token-authenticated Unix socket" do
    server = unique_server()
    start_supervised!({McpServer, name: server})

    {:ok, session} =
      McpServer.start_session(%{workspace: System.tmp_dir!()},
        server: server,
        socket_path: socket_path(),
        shim_path: "/tmp/shim"
      )

    assert {:ok, %File.Stat{mode: mode}} = File.stat(session.socket_path)
    assert Bitwise.band(mode, 0o777) == 0o600

    socket = connect!(session.socket_path, session.token)

    try do
      response = request!(socket, 1, "tools/list")
      tool_names = response["result"]["tools"] |> Enum.map(& &1["name"])

      assert "linear_add_comment" in tool_names
      assert "github_create_pull_request" in tool_names
      refute "linear.add_comment" in tool_names
    after
      close_socket(socket)
      McpServer.stop_session(session, server: server)
    end
  end

  test "executes linear_add_comment through AgentTools.Linear" do
    server = unique_server()
    start_supervised!({McpServer, name: server})

    {:ok, registry} = CommentRegistry.start_link([])

    test_pid = self()

    linear_client = fn query, variables, _opts ->
      send(test_pid, {:linear_client_called, query, variables})

      {:ok,
       %{
         "data" => %{
           "commentCreate" => %{
             "success" => true,
             "comment" => %{"id" => "comment-1", "body" => "hello from claude", "url" => "https://linear/comment-1"}
           }
         }
       }}
    end

    context = %{
      issue_id: "issue-1",
      workspace: System.tmp_dir!(),
      comment_registry: registry,
      tool_opts: [linear_client: linear_client]
    }

    {:ok, session} = McpServer.start_session(context, server: server, socket_path: socket_path(), shim_path: "/tmp/shim")
    socket = connect!(session.socket_path, session.token)

    try do
      response =
        request!(socket, 1, "tools/call", %{
          "name" => "linear_add_comment",
          "arguments" => %{"body" => "hello from claude"}
        })

      refute response["result"]["isError"]
      [content] = response["result"]["content"]
      assert content["text"] =~ "comment-1"
      assert CommentRegistry.owned?(registry, "comment-1")
      assert_receive {:linear_client_called, query, variables}
      assert query =~ "commentCreate"
      assert variables == %{issueId: "issue-1", body: "hello from claude"}
    after
      close_socket(socket)
      McpServer.stop_session(session, server: server)
    end
  end

  test "executes github_create_pull_request through AgentTools.GitHub" do
    server = unique_server()
    start_supervised!({McpServer, name: server})

    workspace = Path.join(System.tmp_dir!(), "symphony-mcp-github-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)

    test_pid = self()

    git_runner = fn ["branch", "--show-current"], opts ->
      send(test_pid, {:git_called, opts})
      {"feature/rsm-3052", 0}
    end

    gh_runner = fn args, opts ->
      send(test_pid, {:gh_called, args, opts})
      {"https://github.com/acme/symphony/pull/123\n", 0}
    end

    context = %{
      workspace: workspace,
      command_security: %{origin_repo: "acme/symphony", workspace: workspace},
      tool_opts: [git_runner: git_runner, gh_runner: gh_runner]
    }

    {:ok, session} = McpServer.start_session(context, server: server, socket_path: socket_path(), shim_path: "/tmp/shim")
    socket = connect!(session.socket_path, session.token)

    try do
      response =
        request!(socket, 1, "tools/call", %{
          "name" => "github_create_pull_request",
          "arguments" => %{"title" => "RSM-3052", "body" => "body"}
        })

      refute response["result"]["isError"]
      [content] = response["result"]["content"]
      assert content["text"] =~ "https://github.com/acme/symphony/pull/123"
      assert_receive {:git_called, git_opts}
      assert git_opts[:cd] == workspace

      assert_receive {:gh_called, args, gh_opts}
      assert gh_opts[:cd] == workspace

      assert args == [
               "pr",
               "create",
               "--repo",
               "acme/symphony",
               "--head",
               "feature/rsm-3052",
               "--title",
               "RSM-3052",
               "--body",
               "body"
             ]
    after
      close_socket(socket)
      File.rm_rf(workspace)
      McpServer.stop_session(session, server: server)
    end
  end

  test "rejects token replay after the token has been claimed" do
    server = unique_server()
    start_supervised!({McpServer, name: server})

    {:ok, session} =
      McpServer.start_session(%{workspace: System.tmp_dir!()},
        server: server,
        socket_path: socket_path(),
        shim_path: "/tmp/shim"
      )

    first = connect!(session.socket_path, session.token)

    try do
      assert request!(first, 1, "initialize")["result"]["serverInfo"]["name"] == "symphony"
      second = connect!(session.socket_path, session.token)
      assert {:error, _reason} = request(second, 2, "tools/list")
      close_socket(second)
    after
      close_socket(first)
      McpServer.stop_session(session, server: server)
    end
  end

  test "server remains available after stopping a session" do
    server = unique_server()
    start_supervised!({McpServer, name: server})

    {:ok, first_session} =
      McpServer.start_session(%{workspace: System.tmp_dir!()},
        server: server,
        socket_path: socket_path(),
        shim_path: "/tmp/shim"
      )

    assert :ok = McpServer.stop_session(first_session, server: server)

    {:ok, second_session} =
      McpServer.start_session(%{workspace: System.tmp_dir!()},
        server: server,
        socket_path: socket_path(),
        shim_path: "/tmp/shim"
      )

    assert Process.whereis(server)
    McpServer.stop_session(second_session, server: server)
  end

  defp unique_server do
    :"mcp_server_test_#{System.unique_integer([:positive])}"
  end

  defp socket_path do
    Path.join(System.tmp_dir!(), "symphony-mcp-test-#{System.unique_integer([:positive])}.sock")
  end

  defp connect!(path, token) do
    {:ok, socket} = :socket.open(:local, :stream)
    :ok = :socket.connect(socket, %{family: :local, path: path})
    :ok = :socket.send(socket, "symphony-session-token: #{token}\r\n\r\n")
    socket
  end

  defp request!(socket, id, method, params \\ %{}) do
    {:ok, response} = request(socket, id, method, params)
    response
  end

  defp request(socket, id, method, params \\ %{}) do
    payload = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
    body = Jason.encode!(payload)

    with :ok <- :socket.send(socket, "Content-Length: #{byte_size(body)}\r\n\r\n#{body}") do
      read_response(socket, "")
    end
  end

  defp read_response(socket, buffer) do
    case parse_response(buffer) do
      {:ok, response, _rest} ->
        {:ok, response}

      :more ->
        case :socket.recv(socket) do
          {:ok, data} -> read_response(socket, buffer <> data)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp parse_response(buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [headers, body_and_rest] ->
        headers
        |> response_content_length()
        |> parse_response_body(body_and_rest)

      [_incomplete] ->
        :more
    end
  end

  defp response_content_length(headers) do
    headers
    |> String.split("\r\n", trim: true)
    |> Enum.find_value(&response_header_length/1)
  end

  defp response_header_length(header) do
    case String.split(header, ":", parts: 2) do
      [key, value] ->
        parse_length_header(key, value)

      _ ->
        nil
    end
  end

  defp parse_length_header(key, value) do
    if String.downcase(String.trim(key)) == "content-length" do
      {length, ""} = value |> String.trim() |> Integer.parse()
      length
    end
  end

  defp parse_response_body(length, body_and_rest) when is_integer(length) do
    if byte_size(body_and_rest) >= length do
      <<body::binary-size(length), rest::binary>> = body_and_rest
      {:ok, Jason.decode!(body), rest}
    else
      :more
    end
  end

  defp parse_response_body(_length, _body_and_rest), do: :more

  defp close_socket(socket) do
    :socket.close(socket)
  catch
    :error, _reason -> :ok
  end
end
