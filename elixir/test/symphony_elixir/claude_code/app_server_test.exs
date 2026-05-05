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
      line =
        ~s({"type":"system","subtype":"init","session_id":"sess-abc123","cwd":"/tmp/workspace","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"})

      assert {:session_started, "sess-abc123"} = AppServer.parse_event(line)
    end

    test "parses result/success event and returns turn_completed with token counts" do
      line =
        ~s({"type":"result","subtype":"success","duration_ms":1500,"duration_api_ms":1200,"is_error":false,"num_turns":1,"result":"done","session_id":"sess-abc","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}})

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
      line =
        ~s({"type":"assistant","message":{"id":"msg-1","type":"message","role":"assistant","content":[{"type":"text","text":"I will help you."}],"model":"claude-opus-4-5","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-1"})

      assert {:notification, text} = AppServer.parse_event(line)
      assert text =~ "I will help you."
    end

    test "parses tool_use event and returns tool_use with tool name" do
      line = ~s({"type":"tool_use","name":"bash","id":"tool-1","input":{"command":"ls"}})

      assert {:tool_use, "bash"} = AppServer.parse_event(line)
    end

    test "parses assistant event with no text content items and returns generic notification" do
      line =
        ~s({"type":"assistant","message":{"id":"msg-2","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t-1","name":"bash","input":{}}],"model":"claude-opus-4-5","stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-2"})

      assert {:notification, "assistant message"} = AppServer.parse_event(line)
    end

    test "parses assistant event with non-list content and returns generic notification" do
      line =
        ~s({"type":"assistant","message":{"id":"msg-3","type":"message","role":"assistant","content":"text response","model":"claude-opus-4-5","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":2}},"session_id":"sess-3"})

      assert {:notification, "assistant message"} = AppServer.parse_event(line)
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

    test "returns structured error when settings directory cannot be created" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-settings-fail-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-SETTINGS")
        claude_path = Path.join(workspace, ".claude")
        File.mkdir_p!(workspace)
        File.write!(claude_path, "not a directory")

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:error, {:claude_settings_write_failed, :mkdir_p, failed_path, _reason}} =
                 AppServer.start_session(workspace)

        assert String.ends_with?(failed_path, "/RSM-SETTINGS/.claude")
      after
        File.rm_rf(test_root)
      end
    end

    test "returns structured error when settings file cannot be written" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-settings-write-fail-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-SETTINGS-WRITE")
        settings_path = Path.join(workspace, ".claude/settings.json")
        File.mkdir_p!(settings_path)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:error, {:claude_settings_write_failed, :write, failed_path, _reason}} =
                 AppServer.start_session(workspace)

        assert String.ends_with?(failed_path, "/RSM-SETTINGS-WRITE/.claude/settings.json")
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when workspace path cannot be read due to permissions" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-unreadable-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        locked_dir = Path.join(workspace_root, "locked")
        workspace = Path.join(locked_dir, "RSM-99")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        # Remove read/execute permission on parent dir so lstat on workspace fails
        File.chmod!(locked_dir, 0o000)

        assert {:error, {:invalid_workspace_cwd, :path_unreadable, _, _}} =
                 AppServer.start_session(workspace)
      after
        locked_dir = Path.join(Path.join(test_root, "workspaces"), "locked")

        if File.exists?(locked_dir) or not is_nil(File.stat(locked_dir)) do
          File.chmod(locked_dir, 0o755)
        end

        File.rm_rf(test_root)
      end
    end

    test "returns error when workspace path equals the workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-workspace-root-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        File.mkdir_p!(workspace_root)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:error, {:invalid_workspace_cwd, :workspace_root, _}} =
                 AppServer.start_session(workspace_root)
      after
        File.rm_rf(test_root)
      end
    end

    test "accepts remote worker host without validating against workspace root" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-session-#{System.unique_integer([:positive])}"
        )

      try do
        File.mkdir_p!(test_root)

        assert {:ok, session} =
                 AppServer.start_session(test_root, worker_host: "worker-01")

        assert session.workspace == test_root
        assert session.worker_host == "worker-01"
      after
        File.rm_rf(test_root)
      end
    end

    test "rejects empty workspace path for remote workers" do
      assert {:error, {:invalid_workspace_cwd, :empty_remote_workspace, _}} =
               AppServer.start_session("   ", worker_host: "worker-01")
    end

    test "rejects workspace path with newline for remote workers" do
      assert {:error, {:invalid_workspace_cwd, :invalid_remote_workspace, _, _}} =
               AppServer.start_session("/remote/work\nspace", worker_host: "worker-01")
    end
  end

  describe "stop_session/1" do
    test "always returns :ok" do
      assert :ok = AppServer.stop_session(%{workspace: "/tmp/ws", metadata: %{}, worker_host: nil})
    end
  end

  describe "run_turn/4" do
    test "runs a successful turn and returns token usage" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-1")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-run-1","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"assistant","message":{"id":"msg-1","type":"message","role":"assistant","content":[{"type":"text","text":"Done."}],"model":"claude-opus-4-5","stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}},"session_id":"sess-run-1"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-run-1","total_cost_usd":0.001,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        test_pid = self()
        on_message = fn msg -> send(test_pid, {:turn_msg, msg}) end

        assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, on_message: on_message)
        assert result.input_tokens == 10
        assert result.output_tokens == 5

        assert_received {:turn_msg, {:notification, _}}
        assert_received {:turn_msg, {:turn_completed, _}}
      after
        File.rm_rf(test_root)
      end
    end

    test "runs a successful turn using a command found on PATH" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-path-command-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-PATH")
        fake_claude = Path.join(test_root, "fake-claude-path")
        File.mkdir_p!(workspace)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_claude, successful_fake_claude_script("sess-path", 8, 4))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "fake-claude-path"
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, [])
        assert result.input_tokens == 8
        assert result.output_tokens == 4
      after
        File.rm_rf(test_root)
      end
    end

    test "runs a successful turn using a relative command path" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-relative-command-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-RELATIVE")
        bin_dir = Path.join(workspace, "bin")
        fake_claude = Path.join(bin_dir, "fake-claude")
        File.mkdir_p!(bin_dir)

        File.write!(fake_claude, successful_fake_claude_script("sess-relative", 7, 3))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "./bin/fake-claude"
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, [])
        assert result.input_tokens == 7
        assert result.output_tokens == 3
      after
        File.rm_rf(test_root)
      end
    end

    test "runs a successful turn when workspace and command paths contain spaces" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony elixir claude code spaced #{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "work spaces")
        workspace = Path.join(workspace_root, "RSM 1")
        bin_dir = Path.join(test_root, "bin dir")
        fake_claude = Path.join(bin_dir, "fake claude")
        File.mkdir_p!(workspace)
        File.mkdir_p!(bin_dir)

        File.write!(fake_claude, """
        #!/bin/sh
        capture_next=0
        for arg in "$@"; do
          if [ "$capture_next" = "1" ]; then
            printf '%s' "$arg" > "$PWD/args.trace"
            capture_next=0
          fi

          if [ "$arg" = "--print" ]; then
            capture_next=1
          fi
        done
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-spaced","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"sess-spaced","total_cost_usd":0.001,"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "'#{fake_claude}'"
        )

        {:ok, session} = AppServer.start_session(workspace)
        prompt = "do the thing from a path with spaces and \"quotes\""

        assert {:ok, result} = AppServer.run_turn(session, prompt, %{}, [])
        assert result.input_tokens == 10
        assert File.read!(Path.join(workspace, "args.trace")) == prompt
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when agent command is empty" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-empty-command-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-EMPTY")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "   "
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :empty_agent_command} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when agent command cannot be parsed" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-invalid-command-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-INVALID")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "'unterminated"
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, {:invalid_agent_command, _message}} =
                 AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when agent command cannot be found" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-missing-command-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-MISSING")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "missing-claude-command"
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, {:agent_command_not_found, "missing-claude-command"}} =
                 AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when turn exits with non-zero status" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-exit-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-2")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' 'some error output'
        exit 1
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, {:exit_status, 1}} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error and forwards turn_failed event on result/error stream line" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-failed-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-3")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"result","subtype":"error","error":"claude api error","session_id":"sess-run-3"}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        test_pid = self()
        on_message = fn msg -> send(test_pid, {:turn_msg, msg}) end

        assert {:error, {:turn_failed, "claude api error"}} =
                 AppServer.run_turn(session, "do the thing", %{}, on_message: on_message)

        assert_received {:turn_msg, {:turn_failed, "claude api error"}}
      after
        File.rm_rf(test_root)
      end
    end

    test "returns turn timeout when the cli process stops producing events" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-timeout-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-TIMEOUT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        sleep 1
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_turn_timeout_ms: 20
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :turn_timeout} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "runs a turn over ssh for remote workers" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-run-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-REMOTE")
        fake_ssh = Path.join(test_root, "ssh")
        trace_file = Path.join(test_root, "ssh-command.trace")
        previous_trace = System.get_env("SYMPHONY_TEST_SSH_TRACE")
        File.mkdir_p!(workspace)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
        System.put_env("SYMPHONY_TEST_SSH_TRACE", trace_file)

        on_exit(fn ->
          restore_env("SYMPHONY_TEST_SSH_TRACE", previous_trace)
        end)

        File.write!(fake_ssh, """
        #!/bin/sh
        last_arg=""
        for arg in "$@"; do
          last_arg="$arg"
        done
        printf '%s' "$last_arg" > "$SYMPHONY_TEST_SSH_TRACE"
        printf '%s\\n' '{"type":"system","subtype":"init","session_id":"sess-remote","cwd":"/remote","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":200,"duration_api_ms":150,"is_error":false,"num_turns":1,"result":"remote done","session_id":"sess-remote","total_cost_usd":0.0,"usage":{"input_tokens":5,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_ssh, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "fake-claude-remote"
        )

        {:ok, session} = AppServer.start_session(workspace, worker_host: "worker-01")

        assert {:ok, result} = AppServer.run_turn(session, "remote task", %{}, [])
        assert result.input_tokens == 5
        assert result.output_tokens == 3
        traced_command = File.read!(trace_file)
        assert traced_command =~ "fake-claude-remote"
        assert traced_command =~ "--output-format stream-json"
        assert traced_command =~ "--print"
        assert traced_command =~ "remote task"
      after
        File.rm_rf(test_root)
      end
    end

    test "returns error when process exits 0 without emitting a result event" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-no-result-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-NORESULT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' 'some unexpected non-json output'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :no_result_event} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "returns command_timeout when a tool call runs too long" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-command-timeout-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-CMDTIMEOUT")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"tool_use","name":"bash","id":"t-1","input":{"command":"sleep 10"}}'
        sleep 1
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_turn_timeout_ms: 5_000,
          agent_command_timeout_ms: 30
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :command_timeout} = AppServer.run_turn(session, "do the thing", %{}, [])
      after
        File.rm_rf(test_root)
      end
    end

    test "correctly reassembles lines split by port line limit into parseable events" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-noeol-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-4")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        # Build a tool_use event whose JSON is padded to exceed @port_line_bytes (1 MB)
        # by stuffing extra whitespace into an otherwise valid JSON field.
        padding = String.duplicate("a", 1_100_000)

        oversized_tool_use =
          Jason.encode!(%{
            "type" => "tool_use",
            "name" => "bash",
            "id" => "t-large",
            "input" => %{"padding" => padding}
          })

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '#{oversized_tool_use}'
        printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":100,"duration_api_ms":80,"is_error":false,"num_turns":1,"result":"ok","session_id":"sess-run-4","total_cost_usd":0.0,"usage":{"input_tokens":7,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
        exit 0
        """)

        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)
        test_pid = self()
        on_message = fn msg -> send(test_pid, {:turn_msg, msg}) end

        assert {:ok, result} = AppServer.run_turn(session, "do the thing", %{}, on_message: on_message)
        assert result.input_tokens == 7
        assert result.output_tokens == 3

        # The oversized tool_use line must have been reassembled and parsed correctly
        assert_received {:turn_msg, {:notification, "tool: bash"}}
      after
        File.rm_rf(test_root)
      end
    end
  end

  defp successful_fake_claude_script(session_id, input_tokens, output_tokens) do
    """
    #!/bin/sh
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"#{session_id}","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"#{session_id}","total_cost_usd":0.001,"usage":{"input_tokens":#{input_tokens},"output_tokens":#{output_tokens},"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
    exit 0
    """
  end
end
