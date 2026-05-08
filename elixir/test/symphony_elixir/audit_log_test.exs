defmodule SymphonyElixir.AuditLogTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AuditLog

  @linear_secret "linear-secret-123456"

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-audit-log-#{System.unique_integer([:positive])}"
      )

    audit_dir = Path.join(test_root, "audit")
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)

    System.put_env("LINEAR_API_KEY", @linear_secret)
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "$LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      restore_app_env(:audit_log_dir, previous_audit_dir)
      File.rm_rf(test_root)
    end)

    {:ok, audit_dir: audit_dir}
  end

  test "writes append-only redacted NDJSON and lists by issue/date", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]
    issue = %Issue{id: "issue-1", identifier: "RSM-1"}
    prompt = "Handle this issue with #{@linear_secret} but do not leak it."

    assert :ok =
             AuditLog.record_prompt_sent(issue, "run-1", prompt,
               timestamp: timestamp,
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-2",
                 run_id: "run-2",
                 timestamp: timestamp,
                 event_type: "tool_call",
                 args: %{"api_key" => @linear_secret}
               },
               dir: audit_dir
             )

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    contents = File.read!(path)
    lines = String.split(contents, "\n", trim: true)

    assert length(lines) == 2
    refute contents =~ @linear_secret

    assert {:ok, [%{"event_type" => "prompt_sent"} = event]} =
             AuditLog.list_events("issue-1", ~D[2026-05-07], ~D[2026-05-07], dir: audit_dir)

    assert event["run_id"] == "run-1"
    assert event["prompt_preview"] =~ "[REDACTED]"
    assert String.length(event["prompt_hash"]) == 64
    refute Map.has_key?(event, "prompt")
    assert is_binary(event["record_hash"])
    assert {:ok, 2} = AuditLog.verify_file(path)
  end

  test "lists events chronologically across date ranges", %{audit_dir: audit_dir} do
    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-1",
                 run_id: "run-1",
                 timestamp: ~U[2026-05-08 10:00:00Z],
                 event_type: "tool_call",
                 sequence: "second"
               },
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-1",
                 run_id: "run-1",
                 timestamp: ~U[2026-05-07 09:00:00Z],
                 event_type: "tool_call",
                 sequence: "first"
               },
               dir: audit_dir
             )

    assert {:ok, events} =
             AuditLog.list_events("issue-1", ~D[2026-05-07], ~D[2026-05-08], dir: audit_dir)

    assert Enum.map(events, & &1["sequence"]) == ["first", "second"]
  end

  test "verify_file detects edited records", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]

    assert :ok =
             AuditLog.record(
               %{issue_id: "issue-1", run_id: "run-1", timestamp: timestamp, event_type: "tool_call"},
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{issue_id: "issue-1", run_id: "run-1", timestamp: timestamp, event_type: "file_change"},
               dir: audit_dir
             )

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    tampered = path |> File.read!() |> String.replace("tool_call", "tool_call_edited", global: false)
    File.write!(path, tampered)

    assert {:error, {:hash_mismatch, 1}} = AuditLog.verify_file(path)
  end

  test "records tool, Linear, file-change, PR, and token side-effect events", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]
    issue = %Issue{id: "issue-1", identifier: "RSM-1"}
    running_entry = %{issue: issue, run_id: "run-1", session_id: "thread-1-turn-1"}

    assert :ok =
             AuditLog.record_agent_update(
               running_entry,
               %{
                 event: :tool_call_completed,
                 timestamp: timestamp,
                 payload: %{
                   "method" => "item/tool/call",
                   "params" => %{
                     "tool" => "linear_graphql",
                     "arguments" => %{
                       "query" => "mutation CreateComment { commentCreate(input: {issueId: $issueId, body: $body}) { success comment { id url } } }",
                       "variables" => %{"issueId" => "linear-issue-1"}
                     }
                   }
                 },
                 result: %{
                   "success" => true,
                   "output" =>
                     Jason.encode!(%{
                       "data" => %{
                         "commentCreate" => %{
                           "comment" => %{"id" => "comment-1", "url" => "https://linear.test/comment-1"}
                         }
                       }
                     })
                 }
               },
               %{
                 input_tokens: 3,
                 output_tokens: 2,
                 total_tokens: 5,
                 input_reported: 3,
                 output_reported: 2,
                 total_reported: 5
               }
             )

    diff = """
    diff --git a/lib/example.ex b/lib/example.ex
    --- a/lib/example.ex
    +++ b/lib/example.ex
    @@
    -old
    +new
    """

    assert :ok =
             AuditLog.record_agent_update(
               running_entry,
               %{
                 event: :notification,
                 timestamp: DateTime.add(timestamp, 1, :second),
                 payload: %{"method" => "turn/diff/updated", "params" => %{"diff" => diff}}
               },
               %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
             )

    assert :ok =
             AuditLog.record_pr_opened(Map.put(running_entry, :pull_request_url, nil), "https://github.com/acme/repo/pull/42",
               timestamp: DateTime.add(timestamp, 2, :second),
               dir: audit_dir
             )

    assert {:ok, events} =
             AuditLog.list_events("issue-1", ~D[2026-05-07], ~D[2026-05-07], dir: audit_dir)

    assert Enum.map(events, & &1["event_type"]) == [
             "tool_call",
             "linear_comment",
             "token_usage_delta",
             "file_change",
             "pr_opened"
           ]

    assert Enum.find(events, &(&1["event_type"] == "linear_comment"))["comment_id"] == "comment-1"
    assert Enum.find(events, &(&1["event_type"] == "token_usage_delta"))["token_usage_delta"]["total_tokens"] == 5

    file_change = Enum.find(events, &(&1["event_type"] == "file_change"))
    assert file_change["paths"] == ["lib/example.ex"]
    assert file_change["diff_stats"] == %{"additions" => 1, "deletions" => 1, "files_changed" => 1}

    pr_opened = Enum.find(events, &(&1["event_type"] == "pr_opened"))

    assert pr_opened["pr"] == %{
             "number" => 42,
             "repo" => "acme/repo",
             "url" => "https://github.com/acme/repo/pull/42"
           }
  end

  test "records observed Linear state transitions", %{audit_dir: audit_dir} do
    previous = %Issue{id: "issue-1", identifier: "RSM-1", state: "In Progress"}
    refreshed = %Issue{id: "issue-1", identifier: "RSM-1", state: "In Review"}

    assert :ok =
             AuditLog.record_linear_state_transition(previous, refreshed, "run-1",
               timestamp: ~U[2026-05-07 12:00:00Z],
               dir: audit_dir
             )

    assert {:ok, [event]} =
             AuditLog.list_events("issue-1", ~D[2026-05-07], ~D[2026-05-07], dir: audit_dir)

    assert event["event_type"] == "linear_state_change"
    assert event["from_state"] == "In Progress"
    assert event["to_state"] == "In Review"
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
