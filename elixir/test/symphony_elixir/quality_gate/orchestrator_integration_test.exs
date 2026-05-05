defmodule SymphonyElixir.QualityGate.OrchestratorIntegrationTest do
  use SymphonyElixir.TestSupport

  defmodule PassProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings), do: {:ok, %{score: 9, reason: "passes"}}
  end

  defmodule SkipProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings), do: {:ok, %{score: 3, reason: "vague"}}
  end

  defmodule ErroringProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings), do: {:error, :stub_boom}
  end

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:symphony_elixir, :quality_gate_anthropic_module)
    end)

    :ok
  end

  test "orchestrator skips low-scoring issues, posts a Linear comment, and surfaces them on the snapshot" do
    issue = %Issue{
      id: "issue-skip-1",
      identifier: "MT-SKIP",
      title: "Skip me",
      description: "Investigate something vague",
      state: "Todo",
      url: "https://example.org/issues/MT-SKIP",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SkipProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :SkipOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    assert_receive {:memory_tracker_comment, "issue-skip-1", body}, 500
    assert body =~ "skipped"
    assert body =~ "score 3"
    assert body =~ "threshold 6"

    snapshot = wait_for_skipped(pid, "issue-skip-1")
    assert [%{kind: :scored, issue_id: "issue-skip-1", score: 3, identifier: "MT-SKIP"}] = snapshot.skipped
    assert snapshot.running == []

    # Re-poll: comment is not posted again for unchanged updated_at
    send(pid, :run_poll_cycle)
    refute_receive {:memory_tracker_comment, "issue-skip-1", _}, 200
  end

  test "orchestrator passes high-scoring issues through unchanged" do
    issue = %Issue{
      id: "issue-pass-1",
      identifier: "MT-PASS",
      title: "Pass me",
      description: "Clear scope and acceptance criteria",
      state: "Todo",
      url: "https://example.org/issues/MT-PASS",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, PassProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :PassOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    refute_receive {:memory_tracker_comment, "issue-pass-1", _}, 200

    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.skipped == []
  end

  test "orchestrator with quality gate disabled does not score or skip" do
    issue = %Issue{
      id: "issue-off-1",
      identifier: "MT-OFF",
      title: "Gate off",
      description: "...",
      state: "Todo",
      url: "https://example.org/issues/MT-OFF",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SkipProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory"
      # no quality_gate section -> defaults to disabled
    )

    name = Module.concat(__MODULE__, :OffOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    refute_receive {:memory_tracker_comment, "issue-off-1", _}, 200
    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.skipped == []
  end

  test "on_error: skip surfaces the issue with an error reason and posts a comment" do
    issue = %Issue{
      id: "issue-err-1",
      identifier: "MT-ERR",
      title: "Erroring",
      description: "...",
      state: "Todo",
      url: "https://example.org/issues/MT-ERR",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, ErroringProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "skip"
      }
    )

    name = Module.concat(__MODULE__, :ErrorSkipOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    send(pid, :run_poll_cycle)

    assert_receive {:memory_tracker_comment, "issue-err-1", body}, 500
    assert body =~ "LLM call failed"

    snapshot = wait_for_skipped(pid, "issue-err-1")
    assert [%{kind: :error, issue_id: "issue-err-1", error: :stub_boom}] = snapshot.skipped

    send(pid, :run_poll_cycle)
    refute_receive {:memory_tracker_comment, "issue-err-1", _}, 200

    edited_issue = %{issue | updated_at: ~U[2026-05-05 04:00:00Z]}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [edited_issue])

    send(pid, :run_poll_cycle)
    assert_receive {:memory_tracker_comment, "issue-err-1", edited_body}, 500
    assert edited_body =~ "LLM call failed"
  end

  test "retry dispatch applies the quality gate before requeueing an active issue" do
    issue = %Issue{
      id: "issue-retry-skip-1",
      identifier: "MT-RETRY-SKIP",
      title: "Retry skip me",
      description: "Still vague on retry",
      state: "In Progress",
      url: "https://example.org/issues/MT-RETRY-SKIP",
      updated_at: ~U[2026-05-05 03:00:00Z]
    }

    Application.put_env(:symphony_elixir, :quality_gate_anthropic_module, SkipProvider)
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      quality_gate: %{
        enabled: true,
        provider: "anthropic",
        model: "claude-haiku-4-5-20251001",
        min_score: 6,
        on_error: "pass"
      }
    )

    name = Module.concat(__MODULE__, :RetrySkipOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    retry_token = make_ref()

    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.put(state.claimed, issue.id),
          retry_attempts: %{
            issue.id => %{
              attempt: 2,
              retry_token: retry_token,
              due_at_ms: System.monotonic_time(:millisecond),
              identifier: issue.identifier,
              error: "agent exited: :boom"
            }
          }
      }
    end)

    send(pid, {:retry_issue, issue.id, retry_token})

    assert_receive {:memory_tracker_comment, "issue-retry-skip-1", body}, 500
    assert body =~ "score 3"

    state = :sys.get_state(pid)
    assert state.running == %{}
    assert state.retry_attempts == %{}
    refute MapSet.member?(state.claimed, issue.id)
    assert Map.has_key?(state.quality_gate_skipped, issue.id)
  end

  defp wait_for_skipped(pid, issue_id, timeout_ms \\ 1_000) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_skipped(pid, issue_id, deadline_ms)
  end

  defp do_wait_for_skipped(pid, issue_id, deadline_ms) do
    snapshot = GenServer.call(pid, :snapshot)

    if Enum.any?(snapshot.skipped, &match?(%{issue_id: ^issue_id}, &1)) do
      snapshot
    else
      if System.monotonic_time(:millisecond) > deadline_ms do
        flunk("Timed out waiting for skipped issue #{issue_id}; snapshot=#{inspect(snapshot)}")
      else
        Process.sleep(10)
        do_wait_for_skipped(pid, issue_id, deadline_ms)
      end
    end
  end
end
