defmodule SymphonyElixir.ClaudeCode.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ClaudeCode.AppServer
  alias SymphonyElixir.Config.Schema.Agent

  defmodule StubSSH do
    def run(worker_host, command, opts) do
      send(self(), {:stub_ssh_run, worker_host, command, opts})
      Process.get(:stub_ssh_run_result, {:ok, {"", 0}})
    end

    def start_port(_worker_host, _command, _opts), do: {:error, :unexpected_start_port}
  end

  describe "build_sandbox_settings/1" do
    test "allowlist mode includes built-in domains and sets allowManagedDomainsOnly" do
      network_access = %Agent.NetworkAccess{
        mode: "allowlist",
        allowed_domains: ["example.com"],
        denied_domains: []
      }

      result = AppServer.build_sandbox_settings(network_access)

      assert get_in(result, ["sandbox", "enabled"]) == true
      assert get_in(result, ["sandbox", "allowUnsandboxedCommands"]) == false

      assert get_in(result, ["sandbox", "filesystem", "denyRead"]) == [
               "~/.ssh",
               "~/.config/gh",
               "~/.aws",
               "~/.gnupg",
               "~/Library/Application Support",
               "~/.docker"
             ]

      assert get_in(result, ["sandbox", "filesystem", "denyWrite"]) == [
               "./WORKFLOW.md",
               "./symphony.yml",
               "./symphony.local.yml",
               "./.git/hooks",
               "./mise.toml",
               "./.tool-versions"
             ]

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

    test "classifies rate_limit_error message as rate_limited" do
      line =
        ~s({"type":"result","subtype":"error","error":"rate_limit_error: Number of request tokens has exceeded your per-minute rate limit","session_id":"sess-rl"})

      assert {:rate_limited, info, reason} = AppServer.parse_event(line)
      assert info.retry_after_seconds == nil
      assert reason =~ "rate_limit_error"
      assert info.message == reason
    end

    test "classifies plain 'rate limit' phrase as rate_limited" do
      line =
        ~s({"type":"result","subtype":"error","error":"Rate limit exceeded, please slow down","session_id":"sess-rl"})

      assert {:rate_limited, _info, _reason} = AppServer.parse_event(line)
    end

    test "classifies HTTP 429 message as rate_limited" do
      line =
        ~s({"type":"result","subtype":"error","error":"HTTP 429 Too Many Requests","session_id":"sess-rl"})

      assert {:rate_limited, _info, _reason} = AppServer.parse_event(line)
    end

    test "extracts retry_after_seconds from 'retry after Ns' message" do
      line =
        ~s({"type":"result","subtype":"error","error":"rate limit reached, retry after 42 seconds","session_id":"sess-rl"})

      assert {:rate_limited, %{retry_after_seconds: 42}, _reason} = AppServer.parse_event(line)
    end

    test "extracts retry_after_seconds from 'Retry-After: N' header-style message" do
      line =
        ~s({"type":"result","subtype":"error","error":"429 Too Many Requests Retry-After: 30","session_id":"sess-rl"})

      assert {:rate_limited, %{retry_after_seconds: 30}, _reason} = AppServer.parse_event(line)
    end

    test "non-rate-limit errors stay as turn_failed" do
      line =
        ~s({"type":"result","subtype":"error","error":"connection refused","session_id":"sess-x"})

      assert {:turn_failed, "connection refused"} = AppServer.parse_event(line)
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

  describe "event_to_update/1" do
    test "converts {:rate_limited, info} into a worker update map with synthesized rate_limits" do
      info = %{retry_after_seconds: 60, message: "rate limit exceeded"}

      assert %{event: :rate_limited, timestamp: %DateTime{}, rate_limits: rate_limits} =
               AppServer.event_to_update({:rate_limited, info})

      assert rate_limits.limit_id == "claude-throttled"
      assert rate_limits.primary == %{remaining: 0, reset_in_seconds: 60}
    end

    test "omits reset_in_seconds when retry_after_seconds is nil" do
      info = %{retry_after_seconds: nil, message: "rate limited"}

      assert %{rate_limits: %{primary: primary}} =
               AppServer.event_to_update({:rate_limited, info})

      assert primary == %{remaining: 0}
    end

    test "returns nil for events that don't need orchestrator state" do
      assert AppServer.event_to_update({:notification, "hello"}) == nil
      assert AppServer.event_to_update({:turn_failed, "boom"}) == nil
      assert AppServer.event_to_update({:session_started, "sess-1"}) == nil
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
        assert :ok = AppServer.stop_session(session)
        refute File.exists?(settings_path)
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

    test "returns structured error when settings JSON cannot be encoded" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-settings-encode-fail-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:symphony_elixir, :claude_settings_json_encoder, fn _value, _opts ->
        {:error, :bad_json}
      end)

      on_exit(fn -> Application.delete_env(:symphony_elixir, :claude_settings_json_encoder) end)

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-SETTINGS-ENCODE")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:error, {:claude_settings_encode_failed, :bad_json}} =
                 AppServer.start_session(workspace)
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

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        fake_ssh = Path.join(test_root, "ssh")
        trace_file = Path.join(test_root, "remote-settings.trace")
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, trace_only_ssh_script(trace_file))
        File.chmod!(fake_ssh, 0o755)

        assert {:ok, session} =
                 AppServer.start_session(test_root, worker_host: "worker-01")

        assert session.workspace == test_root
        assert session.worker_host == "worker-01"
        assert session.settings_path == Path.join(test_root, ".claude/settings.json")
        refute File.exists?(session.settings_path)

        traced_command = File.read!(trace_file)
        assert traced_command =~ "mkdir -p"
        assert traced_command =~ ".claude/settings.json"
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

    test "returns structured error when remote settings write exits non-zero" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-settings-fail-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        fake_ssh = Path.join(test_root, "ssh")
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, failing_ssh_script(42))
        File.chmod!(fake_ssh, 0o755)

        assert {:error, {:claude_settings_write_failed, :remote, "worker-01", 42, output}} =
                 AppServer.start_session(test_root, worker_host: "worker-01")

        assert output =~ "ssh failed"
      after
        File.rm_rf(test_root)
      end
    end

    test "returns structured error when ssh is unavailable for remote settings write" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-settings-no-ssh-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root)

        assert {:error, {:claude_settings_write_failed, :remote, "worker-01", :ssh_not_found}} =
                 AppServer.start_session(test_root, worker_host: "worker-01")
      after
        File.rm_rf(test_root)
      end
    end
  end

  describe "stop_session/1" do
    test "always returns :ok" do
      assert :ok = AppServer.stop_session(%{workspace: "/tmp/ws", metadata: %{}, worker_host: nil})
    end

    test "returns ok when local Claude settings file is already gone" do
      missing_path = Path.join(System.tmp_dir!(), "missing-claude-settings-#{System.unique_integer([:positive])}.json")

      assert :ok =
               AppServer.stop_session(%{
                 workspace: "/tmp/ws",
                 metadata: %{},
                 worker_host: nil,
                 settings_path: missing_path
               })
    end

    test "logs and returns ok when local Claude settings cleanup fails" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-stop-session-fail-#{System.unique_integer([:positive])}"
        )

      try do
        settings_path = Path.join(test_root, ".claude/settings.json")
        File.mkdir_p!(settings_path)

        log =
          capture_log(fn ->
            assert :ok =
                     AppServer.stop_session(%{
                       workspace: test_root,
                       metadata: %{},
                       worker_host: nil,
                       settings_path: settings_path
                     })
          end)

        assert log =~ "Claude settings cleanup failed"
      after
        File.rm_rf(test_root)
      end
    end

    test "removes local Claude settings file when a session stops" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-stop-session-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-STOP")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude"
        )

        assert {:ok, session} = AppServer.start_session(workspace)
        assert File.exists?(session.settings_path)

        assert :ok = AppServer.stop_session(session)
        refute File.exists?(session.settings_path)
      after
        File.rm_rf(test_root)
      end
    end

    test "removes remote Claude settings file over ssh when a session stops" do
      Application.put_env(:symphony_elixir, :claude_code_ssh_module, StubSSH)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :claude_code_ssh_module) end)

      assert :ok =
               AppServer.stop_session(%{
                 workspace: "/remote/workspace",
                 metadata: %{},
                 worker_host: "worker-01",
                 settings_path: "/remote/workspace/.claude/settings.json"
               })

      assert_receive {:stub_ssh_run, "worker-01", command, [stderr_to_stdout: true]}
      assert command =~ "rm -f '/remote/workspace/.claude/settings.json'"
      assert command =~ "rmdir '/remote/workspace/.claude' 2>/dev/null || true"
    end

    test "logs and returns ok when stubbed remote Claude settings cleanup fails" do
      Application.put_env(:symphony_elixir, :claude_code_ssh_module, StubSSH)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :claude_code_ssh_module) end)

      Process.put(:stub_ssh_run_result, {:ok, {"permission denied", 23}})

      log =
        capture_log(fn ->
          assert :ok =
                   AppServer.stop_session(%{
                     workspace: "/remote/workspace",
                     metadata: %{},
                     worker_host: "worker-01",
                     settings_path: "/remote/workspace/.claude/settings.json"
                   })
        end)

      assert_receive {:stub_ssh_run, "worker-01", command, [stderr_to_stdout: true]}
      assert command =~ ".claude/settings.json"
      assert log =~ "Claude settings cleanup failed"
      assert log =~ "status=23"
      assert log =~ "permission denied"
    end

    test "removes remote Claude settings file through ssh command integration when a session stops" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-stop-session-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        fake_ssh = Path.join(test_root, "ssh")
        trace_file = Path.join(test_root, "remote-stop.trace")
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, trace_only_ssh_script(trace_file))
        File.chmod!(fake_ssh, 0o755)

        assert :ok =
                 AppServer.stop_session(%{
                   workspace: "/remote/workspace",
                   metadata: %{},
                   worker_host: "worker-01",
                   settings_path: "/remote/workspace/.claude/settings.json"
                 })

        traced_command = File.read!(trace_file)
        assert traced_command =~ "rm -f"
        assert traced_command =~ ".claude/settings.json"
      after
        File.rm_rf(test_root)
      end
    end

    test "logs and returns ok when remote Claude settings cleanup fails" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-stop-fail-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        fake_ssh = Path.join(test_root, "ssh")
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, failing_ssh_script(23))
        File.chmod!(fake_ssh, 0o755)

        log =
          capture_log(fn ->
            assert :ok =
                     AppServer.stop_session(%{
                       workspace: "/remote/workspace",
                       metadata: %{},
                       worker_host: "worker-01",
                       settings_path: "/remote/workspace/.claude/settings.json"
                     })
          end)

        assert log =~ "Claude settings cleanup failed"
        assert log =~ "status=23"
      after
        File.rm_rf(test_root)
      end
    end

    test "logs and returns ok when ssh is unavailable for remote settings cleanup" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-stop-no-ssh-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        File.mkdir_p!(test_root)
        System.put_env("PATH", test_root)

        log =
          capture_log(fn ->
            assert :ok =
                     AppServer.stop_session(%{
                       workspace: "/remote/workspace",
                       metadata: %{},
                       worker_host: "worker-01",
                       settings_path: "/remote/workspace/.claude/settings.json"
                     })
          end)

        assert log =~ "Claude settings cleanup failed"
        assert log =~ ":ssh_not_found"
      after
        File.rm_rf(test_root)
      end
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

    test "adds remote-control flag for local Claude runs when enabled" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-control-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-REMOTE-CONTROL")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-remote-control"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_remote_control: true
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:ok, result} =
                 AppServer.run_turn(session, "observe this run", %{identifier: "RSM-REMOTE-CONTROL"}, run_id: "run-123")

        assert result.input_tokens == 6

        assert File.read!(Path.join(workspace, "argv.trace")) |> String.split("\n", trim: true) == [
                 "--remote-control",
                 "RSM-REMOTE-CONTROL-run-123",
                 "--output-format",
                 "stream-json",
                 "--print",
                 "observe this run"
               ]
      after
        File.rm_rf(test_root)
      end
    end

    test "omits remote-control flag for local Claude runs by default" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-no-remote-control-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-NO-REMOTE-CONTROL")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-no-remote-control"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:ok, result} =
                 AppServer.run_turn(session, "normal run", %{identifier: "RSM-NO-REMOTE-CONTROL"}, run_id: "run-123")

        assert result.input_tokens == 6

        args = File.read!(Path.join(workspace, "argv.trace")) |> String.split("\n", trim: true)
        refute "--remote-control" in args
        assert args == ["--output-format", "stream-json", "--print", "normal run"]
      after
        File.rm_rf(test_root)
      end
    end

    test "errors when remote_control is enabled but run_id is missing" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-control-missing-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-REMOTE-MISSING")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-missing"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: fake_claude,
          agent_remote_control: true
        )

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, :missing_remote_control_name} =
                 AppServer.run_turn(session, "no run id", %{identifier: "RSM-REMOTE-MISSING"}, [])

        refute File.exists?(Path.join(workspace, "argv.trace"))
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

    test "forwards rate_limited event and turn_failed when result/error is a rate limit" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-run-turn-rate-limited-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-RL")
        fake_claude = Path.join(test_root, "fake-claude")
        File.mkdir_p!(workspace)

        File.write!(fake_claude, """
        #!/bin/sh
        printf '%s\\n' '{"type":"result","subtype":"error","error":"rate_limit_error: retry after 12 seconds","session_id":"sess-rl"}'
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

        assert {:error, {:turn_failed, reason}} =
                 AppServer.run_turn(session, "do the thing", %{}, on_message: on_message)

        assert reason =~ "rate_limit_error"

        assert_received {:turn_msg, {:rate_limited, %{retry_after_seconds: 12, message: ^reason}}}
        assert_received {:turn_msg, {:turn_failed, ^reason}}
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
        File.mkdir_p!(workspace)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, """
        #!/bin/sh
        last_arg=""
        for arg in "$@"; do
          last_arg="$arg"
        done
        printf '%s' "$last_arg" > "#{trace_file}"
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
        refute File.exists?(Path.join(workspace, ".claude/settings.json"))

        assert {:ok, result} = AppServer.run_turn(session, "remote task", %{}, [])
        assert result.input_tokens == 5
        assert result.output_tokens == 3
        traced_command = File.read!(trace_file)
        assert traced_command =~ "cd"
        assert traced_command =~ workspace
        assert traced_command =~ "fake-claude-remote"
        assert traced_command =~ "--output-format stream-json"
        assert traced_command =~ "--print"
        assert traced_command =~ "remote task"
        refute traced_command =~ "--remote-control"
      after
        File.rm_rf(test_root)
      end
    end

    test "adds remote-control flag for ssh Claude runs when enabled" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-claude-code-remote-control-ssh-#{System.unique_integer([:positive])}"
        )

      previous_path = System.get_env("PATH")

      on_exit(fn ->
        restore_env("PATH", previous_path)
      end)

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "RSM-REMOTE-SSH")
        fake_ssh = Path.join(test_root, "ssh")
        fake_claude = Path.join(test_root, "fake-claude-remote")
        trace_file = Path.join(test_root, "ssh-command.trace")
        File.mkdir_p!(workspace)
        System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

        File.write!(fake_ssh, executing_ssh_script(trace_file))
        File.chmod!(fake_ssh, 0o755)
        File.write!(fake_claude, argv_tracing_fake_claude_script("sess-remote-control-ssh"))
        File.chmod!(fake_claude, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          agent_kind: "claude",
          agent_command: "fake-claude-remote",
          agent_remote_control: true
        )

        {:ok, session} = AppServer.start_session(workspace, worker_host: "worker-01")

        assert {:ok, result} =
                 AppServer.run_turn(session, "remote task", %{identifier: "RSM-REMOTE-SSH"}, run_id: "ssh-run-1")

        assert result.input_tokens == 6

        assert File.read!(Path.join(workspace, "argv.trace")) |> String.split("\n", trim: true) == [
                 "--remote-control",
                 "RSM-REMOTE-SSH-ssh-run-1",
                 "--output-format",
                 "stream-json",
                 "--print",
                 "remote task"
               ]
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

  defp argv_tracing_fake_claude_script(session_id) do
    """
    #!/bin/sh
    : > "$PWD/argv.trace"
    for arg in "$@"; do
      printf '%s\\n' "$arg" >> "$PWD/argv.trace"
    done
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"#{session_id}","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}'
    printf '%s\\n' '{"type":"result","subtype":"success","duration_ms":500,"duration_api_ms":400,"is_error":false,"num_turns":1,"result":"Done.","session_id":"#{session_id}","total_cost_usd":0.001,"usage":{"input_tokens":6,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0}}}'
    exit 0
    """
  end

  defp trace_only_ssh_script(trace_file) do
    """
    #!/bin/sh
    last_arg=""
    for arg in "$@"; do
      last_arg="$arg"
    done
    printf '%s' "$last_arg" > "#{trace_file}"
    exit 0
    """
  end

  defp executing_ssh_script(trace_file) do
    """
    #!/bin/sh
    last_arg=""
    for arg in "$@"; do
      last_arg="$arg"
    done
    printf '%s' "$last_arg" > "#{trace_file}"
    exec sh -c "$last_arg"
    """
  end

  defp failing_ssh_script(status) do
    """
    #!/bin/sh
    printf '%s\\n' 'ssh failed'
    exit #{status}
    """
  end
end
