defmodule SymphonyElixir.AgentMcp do
  @moduledoc false

  alias SymphonyElixir.Config.Schema

  @runtimes ["claude", "codex"]

  @spec declared_servers(Schema.t(), String.t()) :: [{String.t(), Schema.Agent.Mcp.Server.t()}]
  def declared_servers(%Schema{agent: %{mcp: %{servers: servers}}}, runtime) when runtime in @runtimes and is_map(servers) do
    servers
    |> Enum.filter(fn {_name, server} -> targets_runtime?(server, runtime) end)
    |> Enum.sort_by(fn {name, _server} -> name end)
  end

  def declared_servers(_settings, _runtime), do: []

  @spec targets_runtime?(Schema.Agent.Mcp.Server.t(), String.t()) :: boolean()
  def targets_runtime?(%Schema.Agent.Mcp.Server{runtimes: runtimes}, runtime) when runtime in @runtimes and is_list(runtimes) do
    runtime in runtimes
  end

  def targets_runtime?(_server, _runtime), do: false

  @spec claude_server_config(Schema.Agent.Mcp.Server.t()) :: map()
  def claude_server_config(%Schema.Agent.Mcp.Server{transport: "stdio"} = server) do
    %{
      "command" => server.command,
      "args" => server.args || [],
      "env" => server.env || %{}
    }
    |> drop_empty_values()
  end

  def claude_server_config(%Schema.Agent.Mcp.Server{transport: transport} = server) when transport in ["http", "sse"] do
    %{
      "type" => transport,
      "url" => server.url,
      "headers" => server.headers || %{}
    }
    |> drop_empty_values()
  end

  @spec codex_server_toml_block(String.t(), Schema.Agent.Mcp.Server.t()) :: String.t()
  def codex_server_toml_block(name, %Schema.Agent.Mcp.Server{transport: "stdio"} = server) when is_binary(name) do
    entries =
      [
        {"command", server.command},
        {"args", server.args || []},
        {"env", server.env || %{}}
      ]
      |> Enum.reject(fn
        {_key, nil} -> true
        {_key, []} -> true
        {_key, map} when map == %{} -> true
        _entry -> false
      end)

    toml_table(["mcp_servers", name], entries)
  end

  @spec symphony_claude_config(map(), Path.t(), Path.t()) :: map()
  def symphony_claude_config(mcp_session, socket_path, shim_path) do
    %{
      "command" => shim_path,
      "args" => ["--socket", socket_path, "--session", mcp_session.token],
      "alwaysLoad" => true
    }
  end

  @spec symphony_codex_toml_block(map(), Path.t(), Path.t()) :: String.t()
  def symphony_codex_toml_block(mcp_session, socket_path, shim_path) do
    toml_table(
      ["mcp_servers", "symphony"],
      [
        {"command", shim_path},
        {"args", ["--socket", socket_path, "--session", mcp_session.token]}
      ]
    )
  end

  @spec toml_table([String.t()], [{String.t(), term()}]) :: String.t()
  def toml_table(path, entries) when is_list(path) and is_list(entries) do
    header = "[" <> Enum.map_join(path, ".", &toml_key/1) <> "]"
    body = Enum.map_join(entries, "\n", fn {key, value} -> "#{toml_key(key)} = #{toml_value(value)}" end)
    header <> "\n" <> body <> "\n"
  end

  defp drop_empty_values(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, []}, acc -> acc
      {_key, value}, acc when value == %{} -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp toml_value(value) when is_binary(value), do: Jason.encode!(value)
  defp toml_value(value) when is_boolean(value), do: to_string(value)
  defp toml_value(value) when is_integer(value), do: Integer.to_string(value)

  defp toml_value(value) when is_list(value) do
    "[" <> Enum.map_join(value, ", ", &toml_value/1) <> "]"
  end

  defp toml_value(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _nested} -> to_string(key) end)
      |> Enum.map_join(", ", fn {key, nested} -> "#{toml_key(to_string(key))} = #{toml_value(nested)}" end)

    "{ " <> entries <> " }"
  end

  defp toml_value(value), do: value |> to_string() |> toml_value()

  defp toml_key(key) when is_binary(key) do
    if String.match?(key, ~r/^[A-Za-z0-9_-]+$/) do
      key
    else
      Jason.encode!(key)
    end
  end
end
