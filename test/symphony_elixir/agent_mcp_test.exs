defmodule SymphonyElixir.AgentMcpTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentMcp
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.Agent.Mcp.Server

  test "declared_servers and targets_runtime tolerate unsupported inputs" do
    assert AgentMcp.declared_servers(%{}, "codex") == []
    refute AgentMcp.targets_runtime?(:invalid, "codex")
    refute AgentMcp.targets_runtime?(%Server{runtimes: ["codex"]}, "unknown")
  end

  test "Codex TOML rendering handles empty values, nested env maps, and quoted keys" do
    server = %Server{
      transport: "stdio",
      command: "node",
      args: [],
      env: %{
        "enabled" => true,
        "retries" => 2,
        "nested value" => %{"child-key" => "ok"}
      }
    }

    block = AgentMcp.codex_server_toml_block("context.a8c", server)

    assert block =~ ~s([mcp_servers."context.a8c"])
    assert block =~ ~s(command = "node")
    refute block =~ "args"
    assert block =~ "enabled = true"
    assert block =~ "retries = 2"
    assert block =~ ~s("nested value" = { child-key = "ok" })
  end

  test "Codex TOML rendering drops nil entries and stringifies fallback values" do
    block =
      AgentMcp.codex_server_toml_block("fallback", %Server{
        transport: "stdio",
        command: nil,
        args: [:not_a_string],
        env: %{"mode" => :atom_value}
      })

    refute block =~ "command"
    assert block =~ ~s(args = ["not_a_string"])
    assert block =~ ~s(mode = "atom_value")
  end

  test "Claude stdio config drops nil and empty values" do
    assert AgentMcp.claude_server_config(%Server{transport: "stdio", command: "node"}) == %{"command" => "node"}
    assert AgentMcp.claude_server_config(%Server{transport: "stdio", command: nil}) == %{}
  end

  test "declared_servers filters by runtime from parsed settings" do
    {:ok, settings} =
      Schema.parse(%{
        agent: %{
          kind: "codex",
          command: "codex app-server",
          mcp: %{
            servers: %{
              "codex-server" => %{command: "codex", runtimes: ["codex"]},
              "claude-server" => %{command: "claude", runtimes: ["claude"]}
            }
          }
        }
      })

    assert [{"codex-server", %Server{}}] = AgentMcp.declared_servers(settings, "codex")
  end
end
