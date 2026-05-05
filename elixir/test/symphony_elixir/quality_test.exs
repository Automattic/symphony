defmodule SymphonyElixir.QualityTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Quality

  test "builds eval logs with outcome, labels, tokens, duration, and test-read signal" do
    started_at = ~U[2026-05-05 08:00:00Z]
    ended_at = ~U[2026-05-05 08:01:30Z]

    running_entry = %{
      run_id: "run-quality-1",
      identifier: "RSM-1",
      issue: %Issue{
        id: "issue-1",
        identifier: "RSM-1",
        labels: ["bug"],
        pull_request_url: "https://github.com/example/repo/pull/1"
      },
      workspace_path: "/tmp/workspaces/RSM-1",
      session_id: "session-1",
      codex_input_tokens: 10,
      codex_output_tokens: 4,
      codex_total_tokens: 14,
      started_at: started_at
    }

    eval =
      Quality.build_eval_log_for_test(running_entry, "success", nil,
        agent_kind: "codex",
        ended_at: ended_at,
        now: ended_at,
        touched_paths: ["lib/symphony_elixir/run_store.ex"],
        existing_test_paths: ["test/symphony_elixir/run_store_test.exs"],
        transcript_events: [
          %{
            payload: %{
              "params" => %{
                "msg" => %{"command" => "sed -n '1,120p' test/symphony_elixir/run_store_test.exs"}
              }
            }
          }
        ]
      )

    assert eval.outcome == "pr_opened"
    assert eval.agent_kind == "codex"
    assert eval.issue_labels == ["bug"]
    assert eval.tokens == %{input_tokens: 10, output_tokens: 4, total_tokens: 14}
    assert eval.duration_seconds == 90
    assert eval.tests_read == true
  end

  test "marks tests_read false only when transcript evidence exists but matching tests were not read" do
    running_entry = %{
      run_id: "run-quality-2",
      identifier: "RSM-2",
      issue: %Issue{id: "issue-2", identifier: "RSM-2", labels: []},
      workspace_path: "/tmp/workspaces/RSM-2",
      started_at: DateTime.utc_now()
    }

    eval =
      Quality.build_eval_log_for_test(running_entry, "success", nil,
        agent_kind: "claude",
        touched_paths: ["lib/symphony_elixir/run_store.ex"],
        existing_test_paths: ["test/symphony_elixir/run_store_test.exs"],
        transcript_events: [
          %{
            payload: %{
              "params" => %{
                "msg" => %{"command" => "sed -n '1,120p' lib/symphony_elixir/run_store.ex"}
              }
            }
          }
        ]
      )

    assert eval.outcome == "no_changes"
    assert eval.tests_read == false

    no_read_evidence =
      Quality.build_eval_log_for_test(running_entry, "success", nil,
        agent_kind: "claude",
        touched_paths: ["lib/symphony_elixir/run_store.ex"],
        existing_test_paths: ["test/symphony_elixir/run_store_test.exs"],
        transcript_events: [%{"type" => "message"}]
      )

    assert no_read_evidence.tests_read == false

    unavailable =
      Quality.build_eval_log_for_test(running_entry, "success", nil,
        agent_kind: "claude",
        touched_paths: ["lib/symphony_elixir/run_store.ex"],
        existing_test_paths: ["test/symphony_elixir/run_store_test.exs"],
        transcript_events: nil
      )

    assert unavailable.tests_read == nil
  end

  test "error statuses produce error outcomes" do
    eval =
      Quality.build_eval_log_for_test(
        %{
          run_id: "run-quality-3",
          issue: %Issue{id: "issue-3", identifier: "RSM-3"},
          started_at: DateTime.utc_now()
        },
        "failure",
        "agent exited: :boom",
        agent_kind: "codex",
        transcript_events: nil
      )

    assert eval.outcome == "error"
    assert eval.error == "agent exited: :boom"
  end
end
