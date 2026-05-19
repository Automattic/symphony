defmodule SymphonyElixir.Codex.McpConfigTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.McpConfig
  alias SymphonyElixir.Config.Schema

  @mcp_session %{
    id: "mcp-test",
    socket_path: "/tmp/symphony-mcp.sock",
    shim_path: "/tmp/symphony-mcp-shim",
    token: "session-token"
  }

  test "inherit none writes only the implicit symphony MCP server" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-none-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    File.mkdir_p!(host_codex_home)

    File.write!(Path.join(host_codex_home, "config.toml"), """
    [mcp_servers.host-secret]
    command = "secret-server"
    """)

    settings = settings!(%{inherit: "none"})

    assert {:ok, config} = build_config(settings, host_codex_home)

    assert config =~ "[mcp_servers.symphony]"
    assert config =~ ~s(command = "/tmp/symphony-mcp-shim")
    assert config =~ ~s("--session", "session-token")
    refute config =~ "host-secret"
  end

  test "allowlist inheritance copies only matching host MCP blocks" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-allowlist-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    File.mkdir_p!(host_codex_home)

    File.write!(Path.join(host_codex_home, "config.toml"), """
    [mcp_servers.context-a8c]
    command = "node"
    args = ["/srv/context.js"]
    env = { LOG_LEVEL = "info" }

    [mcp_servers.slack]
    command = "slack-mcp"
    """)

    settings = settings!(%{inherit: "allowlist", allowed_servers: ["context-a8c"]})

    assert {:ok, config} = build_config(settings, host_codex_home)

    assert config =~ "[mcp_servers.context-a8c]"
    assert config =~ ~s(command = "node")
    refute config =~ "[mcp_servers.slack]"
    refute config =~ "slack-mcp"
  end

  test "inherit all copies all host MCP blocks except reserved symphony" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-all-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    File.mkdir_p!(host_codex_home)

    File.write!(Path.join(host_codex_home, "config.toml"), """
    [mcp_servers.context-a8c]
    command = "context"

    [mcp_servers.browser]
    command = "browser"

    [mcp_servers.symphony]
    command = "shadow"
    """)

    settings = settings!(%{inherit: "all"})

    assert {:ok, config} = build_config(settings, host_codex_home)

    assert config =~ "[mcp_servers.context-a8c]"
    assert config =~ "[mcp_servers.browser]"
    refute config =~ ~s(command = "shadow")
  end

  test "declared Codex server overrides an inherited server with the same name" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-override-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    File.mkdir_p!(host_codex_home)

    File.write!(Path.join(host_codex_home, "config.toml"), """
    [mcp_servers.context-a8c]
    command = "host-node"
    args = ["/host/context.js"]
    """)

    settings =
      settings!(%{
        inherit: "allowlist",
        allowed_servers: ["context-a8c"],
        servers: %{
          "context-a8c" => %{
            transport: "stdio",
            command: "declared-node",
            args: ["/declared/context.js"],
            runtimes: ["codex"]
          }
        }
      })

    assert {:ok, config} = build_config(settings, host_codex_home)

    assert config =~ "[mcp_servers.context-a8c]"
    assert config =~ ~s(command = "declared-node")
    assert config =~ ~s("/declared/context.js")
    refute config =~ "host-node"
    refute config =~ "/host/context.js"
  end

  test "write_home symlinks auth.json without copying credential contents" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-home-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)
    host_codex_home = Path.join(test_root, "host-codex")
    generated_home = Path.join(test_root, "generated-codex-home")
    File.mkdir_p!(host_codex_home)
    File.write!(Path.join(host_codex_home, "auth.json"), "credential contents are not read")

    assert {:ok, runtime_home} =
             McpConfig.write_home(settings!(%{inherit: "none"}), @mcp_session,
               home_path: generated_home,
               host_codex_home: host_codex_home
             )

    assert runtime_home.home_path == generated_home
    assert File.read!(runtime_home.config_path) =~ "[mcp_servers.symphony]"
    assert File.read_link!(Path.join(generated_home, "auth.json")) == Path.join(host_codex_home, "auth.json")
  end

  test "write_home cleans up generated home when setup fails" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-home-error-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    file_parent = Path.join(test_root, "file-parent")
    generated_home = Path.join(file_parent, "generated-codex-home")
    File.mkdir_p!(test_root)
    File.write!(file_parent, "not a directory")

    assert {:error, :enotdir} =
             McpConfig.write_home(settings!(%{inherit: "none"}), @mcp_session,
               home_path: generated_home,
               host_codex_home: Path.join(test_root, "host-codex")
             )

    refute File.exists?(generated_home)
  end

  test "write_home skips auth.json symlink when host file is missing" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-auth-missing-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    missing_host_home = Path.join(test_root, "host-codex-without-auth")
    generated_home = Path.join(test_root, "generated-codex-home")
    File.mkdir_p!(missing_host_home)

    assert {:ok, runtime_home} =
             McpConfig.write_home(settings!(%{inherit: "none"}), @mcp_session,
               home_path: generated_home,
               host_codex_home: missing_host_home
             )

    refute File.exists?(Path.join(runtime_home.home_path, "auth.json"))
    assert File.read!(runtime_home.config_path) =~ "[mcp_servers.symphony]"
  end

  test "build_config supports default host home lookup and fallback settings shape" do
    assert {:ok, config} =
             McpConfig.build_config(%{}, @mcp_session, @mcp_session.socket_path, @mcp_session.shim_path)

    assert config =~ "[mcp_servers.symphony]"
  end

  test "inherited_server_blocks handles missing, unreadable, and invalid inheritance inputs" do
    test_root = Path.join(System.tmp_dir!(), "symphony-codex-mcp-inherit-errors-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(test_root) end)

    missing_home = Path.join(test_root, "missing")
    assert {:ok, []} = McpConfig.inherited_server_blocks(missing_home, mcp!(%{inherit: "allowlist", allowed_servers: ["a"]}), MapSet.new())

    unreadable_home = Path.join(test_root, "unreadable")
    File.mkdir_p!(Path.join(unreadable_home, "config.toml"))

    assert {:error, {:codex_mcp_inheritance_read_failed, _path, :eisdir}} =
             McpConfig.inherited_server_blocks(unreadable_home, mcp!(%{inherit: "all"}), MapSet.new())

    assert {:ok, []} = McpConfig.inherited_server_blocks(nil, :invalid, MapSet.new())

    invalid_mcp_home = Path.join(test_root, "invalid-mcp")
    File.mkdir_p!(invalid_mcp_home)
    File.write!(Path.join(invalid_mcp_home, "config.toml"), "[mcp_servers.context]\ncommand = \"context\"\n")

    assert {:ok, []} =
             McpConfig.inherited_server_blocks(
               invalid_mcp_home,
               %Schema.Agent.Mcp{inherit: "invalid"},
               MapSet.new()
             )
  end

  test "extract_mcp_server_blocks handles empty, non-MCP, quoted, and invalid quoted tables" do
    assert McpConfig.extract_mcp_server_blocks("") == []
    assert McpConfig.extract_mcp_server_blocks("[tools.example]\ncommand = \"ignored\"\n") == []

    blocks =
      McpConfig.extract_mcp_server_blocks("""
      [mcp_servers."quoted.name"]
      command = "quoted"

      [mcp_servers."bad\\x"]
      command = "fallback"

      [mcp_servers."quote\\"name"]
      command = "escaped"
      """)

    assert {"quoted.name", quoted_block} = List.keyfind(blocks, "quoted.name", 0)
    assert quoted_block =~ ~s(command = "quoted")

    assert {"bad\\x", bad_block} = List.keyfind(blocks, "bad\\x", 0)
    assert bad_block =~ ~s(command = "fallback")

    assert {"quote\"name", escaped_block} = List.keyfind(blocks, "quote\"name", 0)
    assert escaped_block =~ ~s(command = "escaped")
  end

  defp settings!(mcp) do
    {:ok, settings} =
      Schema.parse(%{
        agent: %{
          kind: "codex",
          command: "codex app-server",
          mcp: mcp
        }
      })

    settings
  end

  defp mcp!(mcp) do
    settings!(mcp).agent.mcp
  end

  defp build_config(settings, host_codex_home) do
    McpConfig.build_config(
      settings,
      @mcp_session,
      @mcp_session.socket_path,
      @mcp_session.shim_path,
      host_codex_home: host_codex_home
    )
  end
end
