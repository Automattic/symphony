defmodule SymphonyElixir.ClaudeCode.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.AppServer
  alias SymphonyElixir.Config.Schema.Agent

  describe "build_sandbox_settings/1" do
    test "allowlist mode includes built-in domains and sets allowManagedDomainsOnly" do
      network_access = %Agent.NetworkAccess{
        mode: "allowlist",
        allowed_domains: ["example.com"],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access)

      assert get_in(result, ["sandbox", "enabled"]) == true
      assert get_in(result, ["sandbox", "network", "allowManagedDomainsOnly"]) == true

      allowed = get_in(result, ["sandbox", "network", "allowedDomains"])
      assert is_list(allowed)
      assert "github.com" in allowed
      assert "api.github.com" in allowed
      assert "example.com" in allowed
    end

    test "allowlist mode excludes denied domains" do
      network_access = %Agent.NetworkAccess{
        mode: "allowlist",
        allowed_domains: [],
        denied_domains: ["github.com"]
      }

      result = AppServer.build_sandbox_settings(network_access)

      allowed = get_in(result, ["sandbox", "network", "allowedDomains"])
      refute "github.com" in allowed
      assert "api.github.com" in allowed
    end

    test "block mode sets empty allowedDomains" do
      network_access = %Agent.NetworkAccess{
        mode: "block",
        allowed_domains: [],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access)

      assert get_in(result, ["sandbox", "enabled"]) == true
      assert get_in(result, ["sandbox", "network", "allowedDomains"]) == []
      assert get_in(result, ["sandbox", "network", "allowManagedDomainsOnly"]) == true
    end

    test "open mode does not include network key in sandbox" do
      network_access = %Agent.NetworkAccess{
        mode: "open",
        allowed_domains: [],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access)

      assert get_in(result, ["sandbox", "enabled"]) == true
      refute Map.has_key?(result["sandbox"], "network")
    end
  end

  describe "parse_event/1" do
    test "parses system event and returns session_started tuple" do
      line = ~s({"type":"system","subtype":"init","session_id":"sess-abc123","cwd":"/tmp/workspace","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"})

      assert {:session_started, "sess-abc123"} = AppServer.parse_event(line)
    end

    test "parses result/success event and returns turn_completed with token counts" do
      line = ~s({"type":"result","subtype":"success","duration_ms":1500,"duration_api_ms":1200,"is_error":false,"num_turns":1,"result":"done","session_id":"sess-abc","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}})

      assert {:turn_completed, result} = AppServer.parse_event(line)
      assert result.input_tokens == 100
      assert result.output_tokens == 50
    end

    test "parses result/error event and returns turn_failed with reason" do
      line = ~s({"type":"result","subtype":"error","error":"something went wrong","session_id":"sess-xyz"})

      assert {:turn_failed, "something went wrong"} = AppServer.parse_event(line)
    end

    test "parses result/error event with no error field and returns unknown error" do
      line = ~s({"type":"result","subtype":"error","session_id":"sess-xyz"})

      assert {:turn_failed, "unknown error"} = AppServer.parse_event(line)
    end

    test "returns malformed for invalid JSON" do
      line = "not valid json {"

      assert {:malformed, ^line} = AppServer.parse_event(line)
    end

    test "returns malformed for valid JSON with unrecognized shape" do
      line = ~s({"type":"unknown_event","data":"something"})

      assert {:malformed, ^line} = AppServer.parse_event(line)
    end

    test "parses assistant event and returns notification" do
      line = ~s({"type":"assistant","message":{"id":"msg-1","type":"message","role":"assistant","content":[{"type":"text","text":"I will help you."}],"model":"claude-opus-4-5","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-1"})

      assert {:notification, text} = AppServer.parse_event(line)
      assert text =~ "I will help you."
    end

    test "parses tool_use event and returns notification with tool name" do
      line = ~s({"type":"tool_use","name":"bash","id":"tool-1","input":{"command":"ls"}})

      assert {:notification, "tool: bash"} = AppServer.parse_event(line)
    end
  end

  describe "start_session/2" do
    test "writes .claude/settings.json and returns ok session for valid local workspace" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-start-session-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "TEST-1")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

        assert {:ok, session} = AppServer.start_session(workspace)
        assert session.workspace == canonical_workspace
        assert session.worker_host == nil
        assert is_map(session.metadata)

        settings_path = Path.join(workspace, ".claude/settings.json")
        assert File.exists?(settings_path)

        {:ok, contents} = Jason.decode(File.read!(settings_path))
        assert get_in(contents, ["sandbox", "enabled"]) == true
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error for workspace outside workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-session-guard-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        outside_workspace = Path.join(test_root, "outside")
        File.mkdir_p!(workspace_root)
        File.mkdir_p!(outside_workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _, _}} =
                 AppServer.start_session(outside_workspace)
      after
        File.rm_rf(test_root)
      end
    end
  end
end
