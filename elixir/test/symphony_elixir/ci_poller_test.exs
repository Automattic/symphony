defmodule SymphonyElixir.CiPollerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CiPoller
  alias SymphonyElixir.Notifications

  defmodule FakeTracker do
    alias SymphonyElixir.Linear.Issue

    def fetch_issues_by_states(_states) do
      {:ok, Application.get_env(:symphony_elixir, :ci_test_issues, [])}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      wanted = MapSet.new(issue_ids)

      issues =
        :symphony_elixir
        |> Application.get_env(:ci_test_issues, [])
        |> Enum.filter(fn %Issue{id: id} -> MapSet.member?(wanted, id) end)

      {:ok, issues}
    end

    def update_issue_state(issue_id, state_name) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:issue_state_update, issue_id, state_name})
      :ok
    end

    def add_label(issue_id, label_name) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:add_label, issue_id, label_name})
      :ok
    end

    def remove_label(issue_id, label_name) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:remove_label, issue_id, label_name})
      :ok
    end
  end

  defmodule FakeGitHub do
    def fetch_ci_status(pr_url, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:fetch_ci_status, pr_url})
      next_status()
    end

    def rerun_failed(run_id, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:rerun_failed, run_id})
      :ok
    end

    def fetch_failed_log(run_id, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:fetch_failed_log, run_id})
      {:ok, Application.get_env(:symphony_elixir, :ci_test_failed_log, "line 1\nERROR: failed\nline 3")}
    end

    defp next_status do
      case Application.get_env(:symphony_elixir, :ci_test_statuses, []) do
        [status | rest] ->
          Application.put_env(:symphony_elixir, :ci_test_statuses, rest)
          {:ok, status}

        [] ->
          {:ok, Application.fetch_env!(:symphony_elixir, :ci_test_status)}
      end
    end
  end

  defmodule FailingGitHub do
    def fetch_ci_status(pr_url, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:fetch_ci_status, pr_url})
      {:error, :rate_limited}
    end
  end

  defmodule ReviewGitHub do
    def fetch_activity(_pr_url, _opts) do
      {:ok, Application.fetch_env!(:symphony_elixir, :ci_test_review_activity)}
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :ci_test_issues)
      Application.delete_env(:symphony_elixir, :ci_test_status)
      Application.delete_env(:symphony_elixir, :ci_test_statuses)
      Application.delete_env(:symphony_elixir, :ci_test_failed_log)
      Application.delete_env(:symphony_elixir, :ci_test_recipient)
      Application.delete_env(:symphony_elixir, :ci_test_review_activity)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 3}
    )

    Application.put_env(:symphony_elixir, :ci_test_recipient, self())
    :ok
  end

  test "disabled ci config makes no GitHub calls" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: false}
    )

    assert {:ok, %{mode: :disabled, discovered: 0, processed: 0, actions: []}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FailingGitHub)

    refute_receive {:fetch_ci_status, _}
  end

  test "green ci records no dispatch and posts no comments" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, green_status())
    put_run(issue, now)

    assert {:ok, %{discovered: 1, processed: 1, actions: [{:green, "issue-2401"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _, _}
    refute_receive {:add_label, _, _}
    refute_receive {:memory_tracker_comment, _, _}
  end

  test "first failure reruns failed jobs without dispatching" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))
    put_run(issue, now)

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:rerun_failed, "987"}
    refute_receive {:issue_state_update, _, _}
    refute_receive {:add_label, _, _}

    assert [%{status: "rerun_requested", rerun_attempted_shas: ["abc123"], ci_retry_count: 0}] =
             RunStore.list_ci_checks()
  end

  test "second failure dispatches once with prompt ci failure context" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_statuses, [failed_status("abc123"), failed_status("abc123"), failed_status("abc123")])
    Application.put_env(:symphony_elixir, :ci_test_failed_log, Enum.map_join(1..5, "\n", &"line #{&1}") <> "\nERROR: specs failed\nstack")
    put_run(issue, now)

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert {:ok, %{actions: [{:state_transitioned, "issue-2401", :ci_failure, "In Progress"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:add_label, "issue-2401", "ci-failed"}
    assert_receive {:issue_state_update, "issue-2401", "In Progress"}
    assert_receive {:fetch_failed_log, "987"}

    assert %{
             commit_sha: "abc123",
             failed_checks: [%{name: "specs"}],
             log_excerpt: log_excerpt
           } = CiPoller.pending_ci_failure("issue-2401")

    assert log_excerpt =~ "ERROR: specs failed"
    refute log_excerpt =~ "line 1"

    prompt = PromptBuilder.build_prompt(issue, ci_failure: CiPoller.pending_ci_failure("issue-2401"))
    assert prompt =~ "CI failure:"
    assert prompt =~ "Failed checks: specs"
    assert prompt =~ "Commit SHA: abc123"
    assert prompt =~ "ERROR: specs failed"

    Application.put_env(:symphony_elixir, :ci_test_issues, [%{issue | labels: ["ci-failed"]}])

    assert {:ok, %{actions: [{:already_handled, "issue-2401", "abc123"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 2, :minute))

    refute_receive {:issue_state_update, _, _}
  end

  test "max retries escalates instead of dispatching again" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = %{in_review_issue() | labels: ["ci-failed"]}
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("def456"))

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      ci: %{enabled: true, log_excerpt_lines: 3, max_retries: 1, escalation_state: "In Review"}
    )

    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/RSM-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               ci_failed_label_confirmed: true,
               rerun_attempted_shas: ["def456"],
               dispatched_shas: ["abc123"],
               updated_at: now
             })

    Notifications.subscribe()

    assert {:ok, %{actions: [{:escalated, "issue-2401", "In Review"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:add_label, "issue-2401", "needs-human-ci-help"}
    assert_receive {:issue_state_update, "issue-2401", "In Review"}
    assert_receive {:notification_event, %{event: "ci_escalated", metadata: %{max_retries: 1}}}

    assert [%{status: "escalated", ci_retry_count: 1}] = RunStore.list_ci_checks()
  end

  test "green ci removes labels and resets retry state" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = %{in_review_issue() | labels: ["ci-failed", "needs-human-ci-help"]}
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, green_status("def456"))
    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/RSM-2401",
               status: "dispatch_requested",
               ci_retry_count: 2,
               ci_failed_label_confirmed: true,
               dispatched_shas: ["abc123"],
               rerun_attempted_shas: ["abc123"],
               updated_at: now
             })

    assert {:ok, %{actions: [{:green, "issue-2401"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:remove_label, "issue-2401", "ci-failed"}
    assert_receive {:remove_label, "issue-2401", "needs-human-ci-help"}

    assert [
             %{
               status: "green",
               ci_retry_count: 0,
               dispatched_shas: [],
               rerun_attempted_shas: [],
               ci_failure: nil
             }
           ] = RunStore.list_ci_checks()
  end

  test "pr review poller yields rework ownership while ci owns the issue" do
    now = ~U[2026-05-06 09:00:00Z]

    assert :ok =
             RunStore.put_ci_check(%{
               issue_id: "issue-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               updated_at: now
             })

    assert :ok =
             RunStore.put_pr_review(%{
               issue_id: "issue-2401",
               issue_identifier: "RSM-2401",
               pr_url: "https://github.com/example/repo/pull/2401",
               workspace_path: "/tmp/workspaces/RSM-2401",
               status: "watching",
               updated_at: now
             })

    Application.put_env(:symphony_elixir, :ci_test_review_activity, %{
      pr_url: "https://github.com/example/repo/pull/2401",
      state: "OPEN",
      review_decision: "CHANGES_REQUESTED",
      latest_activity_at: DateTime.add(now, -31, :minute),
      latest_review_activity_at: DateTime.add(now, -31, :minute),
      comments: []
    })

    assert {:ok, %{actions: [{:ci_owned, "issue-2401", :rework}]}} =
             SymphonyElixir.PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: ReviewGitHub,
               now: now
             )

    refute_receive {:issue_state_update, _, _}
  end

  test "log truncation starts at the first error inside the retained window" do
    log = Enum.map_join(1..5, "\n", &"line #{&1}") <> "\nwarning\nERROR: broken\nstack\nlast"

    assert CiPoller.log_excerpt_for_test(log, 5) == "ERROR: broken\nstack\nlast"
  end

  test "transient GitHub errors are recorded without dispatching" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    put_run(issue, now)

    assert {:ok, %{actions: [{:poll_error, "issue-2401", :rate_limited}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FailingGitHub, now: now)

    refute_receive {:issue_state_update, _, _}
    assert [%{status: "poll_error", error: ":rate_limited"}] = RunStore.list_ci_checks()
  end

  defp in_review_issue do
    %Issue{
      id: "issue-2401",
      identifier: "RSM-2401",
      title: "Handle CI",
      state: "In Review",
      url: "https://linear.test/RSM-2401",
      pr_urls: ["https://github.com/example/repo/pull/2401"],
      labels: []
    }
  end

  defp put_run(issue, now) do
    RunStore.put_run(%{
      run_id: "run-1",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      status: "success",
      workspace_path: "/tmp/workspaces/RSM-2401",
      worker_host: nil,
      started_at: DateTime.add(now, -2, :minute),
      ended_at: DateTime.add(now, -1, :minute)
    })
  end

  defp green_status(sha \\ "abc123") do
    %{
      pr_url: "https://github.com/example/repo/pull/2401",
      pr_title: "Handle CI",
      state: "OPEN",
      commit_sha: sha,
      checks: [
        %{name: "specs", status: "COMPLETED", conclusion: "SUCCESS", run_id: "987"}
      ]
    }
  end

  defp failed_status(sha) do
    %{
      pr_url: "https://github.com/example/repo/pull/2401",
      pr_title: "Handle CI",
      state: "OPEN",
      commit_sha: sha,
      checks: [
        %{name: "specs", status: "COMPLETED", conclusion: "FAILURE", run_id: "987"}
      ]
    }
  end
end
