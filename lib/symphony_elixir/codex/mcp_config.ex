defmodule SymphonyElixir.Codex.McpConfig do
  @moduledoc false

  require Logger

  alias SymphonyElixir.AgentMcp
  alias SymphonyElixir.Config.Schema

  @type runtime_home :: %{
          home_path: Path.t(),
          config_path: Path.t(),
          cleanup_paths: [Path.t()]
        }

  @spec write_home(Schema.t(), map(), keyword()) :: {:ok, runtime_home()} | {:error, term()}
  def write_home(settings, mcp_session, opts \\ []) do
    home_path =
      Keyword.get_lazy(opts, :home_path, fn ->
        Path.join(System.tmp_dir!(), "symphony-codex-home-#{mcp_session.id}")
      end)

    socket_path = Keyword.get(opts, :socket_path) || mcp_session.socket_path
    shim_path = Keyword.get(opts, :shim_path) || mcp_session.shim_path
    host_codex_home = Keyword.get_lazy(opts, :host_codex_home, &host_codex_home/0)
    config_path = Path.join(home_path, "config.toml")

    with {:ok, config_toml} <-
           build_config(settings, mcp_session, socket_path, shim_path, host_codex_home: host_codex_home),
         {:ok, _removed_paths} <- File.rm_rf(home_path),
         :ok <- File.mkdir_p(home_path),
         :ok <- File.chmod(home_path, 0o700),
         :ok <- File.write(config_path, config_toml),
         :ok <- File.chmod(config_path, 0o600),
         :ok <- link_auth_json(home_path, host_codex_home) do
      {:ok, %{home_path: home_path, config_path: config_path, cleanup_paths: [home_path]}}
    else
      {:error, reason} ->
        _ = File.rm_rf(home_path)
        {:error, reason}
    end
  end

  @spec build_config(Schema.t(), map(), Path.t(), Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build_config(settings, mcp_session, socket_path, shim_path, opts \\ []) do
    host_codex_home = Keyword.get_lazy(opts, :host_codex_home, &host_codex_home/0)
    mcp = agent_mcp(settings)
    declared_servers = AgentMcp.declared_servers(settings, "codex")
    declared_names = MapSet.new(Enum.map(declared_servers, fn {name, _server} -> name end))

    with {:ok, inherited_blocks} <- inherited_server_blocks(host_codex_home, mcp, declared_names) do
      declared_blocks =
        Enum.map(declared_servers, fn {name, server} ->
          AgentMcp.codex_server_toml_block(name, server)
        end)

      blocks =
        [
          AgentMcp.symphony_codex_toml_block(mcp_session, socket_path, shim_path)
          | inherited_blocks ++ declared_blocks
        ]

      {:ok, Enum.join(blocks, "\n")}
    end
  end

  @spec inherited_server_blocks(Path.t(), Schema.Agent.Mcp.t(), MapSet.t(String.t())) ::
          {:ok, [String.t()]} | {:error, term()}
  def inherited_server_blocks(_host_codex_home, %Schema.Agent.Mcp{inherit: "none"}, _declared_names), do: {:ok, []}

  def inherited_server_blocks(host_codex_home, %Schema.Agent.Mcp{} = mcp, declared_names) when is_binary(host_codex_home) do
    config_path = Path.join(host_codex_home, "config.toml")

    case File.read(config_path) do
      {:ok, contents} ->
        allowed_names = inherited_allowed_names(mcp)

        blocks =
          contents
          |> extract_mcp_server_blocks()
          |> Enum.reject(fn {name, _block} -> name == "symphony" or MapSet.member?(declared_names, name) end)
          |> Enum.filter(fn {name, _block} -> inherited_server_allowed?(allowed_names, name) end)
          |> Enum.sort_by(fn {name, _block} -> name end)
          |> Enum.map(fn {_name, block} -> block end)

        {:ok, blocks}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:codex_mcp_inheritance_read_failed, config_path, reason}}
    end
  end

  def inherited_server_blocks(_host_codex_home, _mcp, _declared_names), do: {:ok, []}

  @spec extract_mcp_server_blocks(String.t()) :: [{String.t(), String.t()}]
  def extract_mcp_server_blocks(contents) when is_binary(contents) do
    contents
    |> split_toml_blocks()
    |> Enum.reduce(%{}, fn block, acc ->
      case block_server_name(block) do
        nil -> acc
        name -> Map.update(acc, name, normalize_block(block), &(normalize_block(&1) <> "\n" <> normalize_block(block)))
      end
    end)
    |> Map.to_list()
  end

  defp agent_mcp(%Schema{agent: %{mcp: %Schema.Agent.Mcp{} = mcp}}), do: mcp
  defp agent_mcp(_settings), do: %Schema.Agent.Mcp{}

  defp host_codex_home do
    home = System.get_env("HOME") || System.user_home!()
    Path.join(home, ".codex")
  end

  defp link_auth_json(home_path, host_codex_home) do
    target = Path.join(host_codex_home, "auth.json")

    if File.exists?(target) do
      File.ln_s(target, Path.join(home_path, "auth.json"))
    else
      Logger.warning("Codex host auth.json not found at #{target}; skipping symlink in generated CODEX_HOME")
      :ok
    end
  end

  @spec inherited_allowed_names(Schema.Agent.Mcp.t()) :: MapSet.t(String.t()) | nil
  defp inherited_allowed_names(%Schema.Agent.Mcp{inherit: "allowlist", allowed_servers: allowed_servers}) do
    MapSet.new(allowed_servers || [])
  end

  defp inherited_allowed_names(%Schema.Agent.Mcp{inherit: "all"}), do: nil
  defp inherited_allowed_names(_mcp), do: MapSet.new()

  @spec inherited_server_allowed?(MapSet.t(String.t()) | nil, String.t()) :: boolean()
  defp inherited_server_allowed?(nil, _name), do: true
  defp inherited_server_allowed?(allowed_names, name), do: MapSet.member?(allowed_names, name)

  defp split_toml_blocks(contents) do
    contents
    |> String.split("\n")
    |> Enum.reduce({[], []}, fn line, {blocks, current} ->
      if table_header?(line) and current != [] do
        {[Enum.reverse(current) |> Enum.join("\n") | blocks], [line]}
      else
        {blocks, [line | current]}
      end
    end)
    |> then(fn {blocks, current} ->
      [Enum.reverse(current) |> Enum.join("\n") | blocks]
      |> Enum.reverse()
    end)
  end

  defp table_header?(line) do
    String.match?(String.trim(line), ~r/^\[[^\[\]]+\]$/)
  end

  defp block_server_name(block) do
    block
    |> String.split("\n", parts: 2)
    |> List.first()
    |> parse_table_path()
    |> case do
      ["mcp_servers", name | _rest] -> name
      _path -> nil
    end
  end

  defp parse_table_path(line) do
    line = String.trim(line)

    if table_header?(line) do
      line
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> split_toml_key_path()
    else
      []
    end
  end

  defp split_toml_key_path(value) do
    value
    |> do_split_toml_key_path("", [], false)
    |> Enum.map(&unquote_toml_key/1)
  end

  defp do_split_toml_key_path(<<>>, current, parts, _quoted), do: Enum.reverse([current | parts])

  defp do_split_toml_key_path(<<"\"", rest::binary>>, current, parts, false),
    do: do_split_toml_key_path(rest, current <> "\"", parts, true)

  defp do_split_toml_key_path(<<"\"", rest::binary>>, current, parts, true),
    do: do_split_toml_key_path(rest, current <> "\"", parts, false)

  defp do_split_toml_key_path(<<"\\\"", rest::binary>>, current, parts, true),
    do: do_split_toml_key_path(rest, current <> "\\\"", parts, true)

  defp do_split_toml_key_path(<<".", rest::binary>>, current, parts, false),
    do: do_split_toml_key_path(rest, "", [current | parts], false)

  defp do_split_toml_key_path(<<char::utf8, rest::binary>>, current, parts, quoted),
    do: do_split_toml_key_path(rest, current <> <<char::utf8>>, parts, quoted)

  defp unquote_toml_key("\"" <> rest) do
    rest
    |> String.trim_trailing("\"")
    |> then(fn quoted ->
      case Jason.decode("\"#{quoted}\"") do
        {:ok, decoded} -> decoded
        {:error, _reason} -> quoted
      end
    end)
  end

  defp unquote_toml_key(key), do: String.trim(key)

  defp normalize_block(block) do
    block
    |> String.trim()
    |> Kernel.<>("\n")
  end
end
