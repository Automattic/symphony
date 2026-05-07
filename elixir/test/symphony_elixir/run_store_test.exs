defmodule SymphonyElixir.RunStoreTest do
  use SymphonyElixir.TestSupport

  setup do
    :ok = RunStore.clear()
  end

  test "persists run records, retry queue entries, and codex totals" do
    started_at = DateTime.utc_now()
    due_at = DateTime.add(started_at, 60_000, :millisecond)

    assert :ok =
             RunStore.put_run(%{
               run_id: "run-1",
               issue_id: "issue-1",
               issue_identifier: "RSM-1",
               title: "Persist me",
               state: "In Progress",
               status: "running",
               attempt: 2,
               started_at: started_at,
               ended_at: nil,
               error: nil,
               worker_host: "worker-a",
               workspace_path: "/tmp/workspaces/RSM-1",
               session_id: "thread-1-turn-1",
               transcript_path: "/tmp/transcript.jsonl",
               tokens: %{input_tokens: 10, output_tokens: 4, total_tokens: 14},
               runtime_seconds: 0
             })

    assert :ok =
             RunStore.update_run("run-1", %{
               status: "success",
               ended_at: DateTime.add(started_at, 10, :second),
               runtime_seconds: 10
             })

    assert [
             %{
               run_id: "run-1",
               issue_id: "issue-1",
               status: "success",
               attempt: 2,
               session_id: "thread-1-turn-1",
               transcript_path: "/tmp/transcript.jsonl",
               runtime_seconds: 10
             }
           ] = RunStore.list_runs()

    assert :ok =
             RunStore.put_retry(%{
               issue_id: "issue-1",
               issue_identifier: "RSM-1",
               identifier: "RSM-1",
               attempt: 3,
               due_at: due_at,
               error: "agent exited: :boom",
               worker_host: "worker-a",
               workspace_path: "/tmp/workspaces/RSM-1"
             })

    assert [
             %{
               issue_id: "issue-1",
               identifier: "RSM-1",
               attempt: 3,
               due_at: ^due_at,
               error: "agent exited: :boom"
             }
           ] = RunStore.list_retries()

    assert :ok = RunStore.delete_retry("issue-1")
    assert [] = RunStore.list_retries()

    assert :ok =
             RunStore.put_pr_review(%{
               issue_id: "issue-1",
               issue_identifier: "RSM-1",
               pr_url: "https://github.com/example/repo/pull/1",
               workspace_path: "/tmp/workspaces/RSM-1",
               status: "watching",
               updated_at: started_at
             })

    assert :ok =
             RunStore.update_pr_review("issue-1", %{
               status: "cooling_down",
               last_activity_at: due_at,
               last_addressed_comment_id: "comment-1"
             })

    assert [
             %{
               issue_id: "issue-1",
               pr_url: "https://github.com/example/repo/pull/1",
               workspace_path: "/tmp/workspaces/RSM-1",
               status: "cooling_down",
               last_activity_at: ^due_at,
               last_addressed_comment_id: "comment-1"
             }
           ] = RunStore.list_pr_reviews()

    assert :ok = RunStore.delete_pr_review("issue-1")
    assert [] = RunStore.list_pr_reviews()

    assert :ok =
             RunStore.put_ci_check(%{
               issue_id: "issue-1",
               issue_identifier: "RSM-1",
               pr_url: "https://github.com/example/repo/pull/1",
               commit_sha: "abc123",
               status: "dispatch_requested",
               ci_retry_count: 1,
               updated_at: started_at
             })

    assert :ok =
             RunStore.update_ci_check("issue-1", %{
               status: "green",
               ci_retry_count: 0,
               updated_at: due_at
             })

    assert [
             %{
               issue_id: "issue-1",
               pr_url: "https://github.com/example/repo/pull/1",
               commit_sha: "abc123",
               status: "green",
               ci_retry_count: 0,
               updated_at: ^due_at
             }
           ] = RunStore.list_ci_checks()

    assert :ok = RunStore.delete_ci_check("issue-1")
    assert [] = RunStore.list_ci_checks()

    totals = %{input_tokens: 10, output_tokens: 4, total_tokens: 14, seconds_running: 10}
    assert :ok = RunStore.put_codex_totals(totals)
    assert totals == RunStore.get_codex_totals()

    quality_gate_cache = %{
      "issue-1" => %{
        updated_at: started_at,
        comment_signature: "comments",
        score: 5,
        reason: "needs answer",
        passed?: false,
        awaiting_clarification?: true,
        questions: ["What should pass?", "Which module?", "What is out of scope?"],
        rounds_asked: 1,
        comment_posted?: true,
        identifier: "RSM-1",
        title: "Persist me",
        state: "Todo",
        url: "https://example.org/RSM-1",
        scored_at: started_at
      }
    }

    assert :ok = RunStore.put_quality_gate_cache(quality_gate_cache)
    assert quality_gate_cache == RunStore.get_quality_gate_cache()
  end

  test "persists dispatch pause state across run store restart" do
    assert %{paused: false, reason: nil, paused_at: nil} = RunStore.get_paused()

    assert :ok = RunStore.set_paused(true, "overnight deploy")

    assert %{paused: true, reason: "overnight deploy", paused_at: %DateTime{} = paused_at} =
             RunStore.get_paused()

    pid = Process.whereis(RunStore)
    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    restarted_pid = await_restarted_run_store(pid)

    assert %{paused: true, reason: "overnight deploy", paused_at: ^paused_at} =
             RunStore.get_paused()

    assert :ok = RunStore.set_paused(true, "ignored because already paused")

    assert %{paused: true, reason: "overnight deploy", paused_at: ^paused_at} =
             RunStore.get_paused()

    assert :ok = RunStore.set_paused(false, nil)
    assert %{paused: false, reason: nil, paused_at: nil} = RunStore.get_paused()

    assert Process.alive?(restarted_pid)
  end

  test "interrupt_running_runs marks stale running records as failures" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_run(%{
               run_id: "run-stale",
               issue_id: "issue-stale",
               issue_identifier: "RSM-2",
               status: "running",
               attempt: 1,
               started_at: now
             })

    assert {:ok, 1} = RunStore.interrupt_running_runs("orchestrator restarted before worker exit")

    assert [
             %{
               run_id: "run-stale",
               status: "failure",
               error: "orchestrator restarted before worker exit",
               ended_at: %DateTime{}
             }
           ] = RunStore.list_runs()
  end

  test "interrupt_running_runs skips malformed running records" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_run(%{
               run_id: "run-valid",
               issue_id: "issue-valid",
               issue_identifier: "RSM-3",
               status: "running",
               attempt: 1,
               started_at: now
             })

    assert {:atomic, :ok} =
             :mnesia.transaction(fn ->
               :mnesia.write({:symphony_run_store_runs, "malformed", %{status: "running"}})
               :ok
             end)

    log =
      capture_log(fn ->
        assert {:ok, 1} = RunStore.interrupt_running_runs("orchestrator restarted before worker exit")
      end)

    assert log =~ "Skipping malformed running run store record"

    assert [
             %{run_id: "run-valid", status: "failure"},
             %{status: "running"}
           ] = Enum.sort_by(RunStore.list_runs(:all), &Map.get(&1, :run_id, "zzz"))
  end

  test "persists eval logs with indexed filter fields" do
    now = DateTime.utc_now()
    yesterday = DateTime.add(now, -1, :day)

    assert :ok =
             RunStore.put_eval_log(%{
               eval_id: "eval-1",
               run_id: "run-1",
               issue_identifier: "RSM-1",
               issue_labels: ["bug", "backend"],
               outcome: "pr_opened",
               agent_kind: "codex",
               tokens: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
               tests_run: true,
               duration_seconds: 12,
               workspace_path: "/tmp/workspaces/RSM-1",
               session_id: "session-1",
               logged_at: now,
               date: DateTime.to_date(now)
             })

    assert :ok =
             RunStore.put_eval_log(%{
               eval_id: "eval-2",
               run_id: "run-2",
               issue_identifier: "RSM-2",
               issue_labels: ["feature"],
               outcome: "error",
               agent_kind: "claude",
               tokens: %{input_tokens: 3, output_tokens: 2, total_tokens: 5},
               tests_run: false,
               duration_seconds: 4,
               logged_at: yesterday,
               date: DateTime.to_date(yesterday)
             })

    assert [%{eval_id: "eval-1"}] = RunStore.list_eval_logs(outcome: "pr_opened", limit: :all)
    assert [%{eval_id: "eval-2"}] = RunStore.list_eval_logs(agent_kind: "claude", limit: :all)
    assert [%{eval_id: "eval-1"}] = RunStore.list_eval_logs(issue_label: "backend", limit: :all)
    assert [%{eval_id: "eval-1"}] = RunStore.list_eval_logs(date_from: DateTime.to_date(now), limit: :all)

    attributes = :mnesia.table_info(:symphony_run_store_eval_logs, :attributes)
    indexes = :mnesia.table_info(:symphony_run_store_eval_logs, :index)

    for indexed_field <- [:outcome, :agent_kind, :issue_label, :date] do
      assert attribute_position(attributes, indexed_field) in indexes
    end
  end

  defp attribute_position(attributes, field) do
    Enum.find_index(attributes, &(&1 == field)) + 2
  end

  defp await_restarted_run_store(old_pid, attempts \\ 20)

  defp await_restarted_run_store(old_pid, attempts) when attempts > 0 do
    case Process.whereis(RunStore) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        await_restarted_run_store(old_pid, attempts - 1)
    end
  end

  defp await_restarted_run_store(_old_pid, 0), do: flunk("RunStore did not restart")
end
