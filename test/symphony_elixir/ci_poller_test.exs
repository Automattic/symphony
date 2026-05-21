defmodule SymphonyElixir.CiPollerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CiPoller
  alias SymphonyElixir.Notifications

  @repo_key "default"

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
      send(recipient, {:ci_failure_at_transition, issue_id, SymphonyElixir.CiPoller.pending_ci_failure(issue_id)})
      send(recipient, {:issue_state_update, issue_id, state_name})
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

      case Application.get_env(:symphony_elixir, :ci_test_failed_log_error) do
        nil ->
          logs_by_run_id = Application.get_env(:symphony_elixir, :ci_test_failed_logs_by_run_id, %{})
          {:ok, Map.get(logs_by_run_id, run_id, Application.get_env(:symphony_elixir, :ci_test_failed_log, "line 1\nERROR: failed\nline 3"))}

        reason ->
          {:error, reason}
      end
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

  defmodule FailingUpdateRunStore do
    def list_runs(:all), do: []
    def list_ci_checks, do: [Application.fetch_env!(:symphony_elixir, :ci_test_ci_record)]
    def update_ci_check(_issue_id, _attrs), do: {:error, :write_failed}
    def put_ci_check(_record), do: :ok
    def delete_ci_check(_issue_id), do: :ok
  end

  defmodule FailingTransitionTracker do
    def fetch_issues_by_states(_states), do: {:ok, []}

    def update_issue_state(issue_id, state_name) do
      recipient = Application.fetch_env!(:symphony_elixir, :ci_test_recipient)
      send(recipient, {:issue_state_update, issue_id, state_name})
      {:error, :linear_unavailable}
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :ci_test_issues)
      Application.delete_env(:symphony_elixir, :ci_test_status)
      Application.delete_env(:symphony_elixir, :ci_test_statuses)
      Application.delete_env(:symphony_elixir, :ci_test_failed_log)
      Application.delete_env(:symphony_elixir, :ci_test_failed_log_error)
      Application.delete_env(:symphony_elixir, :ci_test_failed_logs_by_run_id)
      Application.delete_env(:symphony_elixir, :ci_test_recipient)
      Application.delete_env(:symphony_elixir, :ci_test_review_activity)
      Application.delete_env(:symphony_elixir, :ci_test_ci_record)
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

    assert [%{status: "rerun_requested", rerun_attempted_shas: ["abc123"], ci_retry_count: 0}] =
             RunStore.list_ci_checks()
  end

  test "first failure reruns every distinct failed workflow run before dispatching" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, multi_failed_status("abc123"))
    put_run(issue, now)

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", ["987", "654"]}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert_receive {:rerun_failed, "987"}
    assert_receive {:rerun_failed, "654"}
    refute_receive {:issue_state_update, _, _}

    assert [%{status: "rerun_requested", rerun_attempted_shas: ["abc123"], rerun_run_ids: ["987", "654"], ci_retry_count: 0}] =
             RunStore.list_ci_checks()
  end

  test "second failure dispatches once with prompt ci failure context" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_statuses, [failed_status("abc123"), failed_status("abc123"), failed_status("abc123")])
    Application.put_env(:symphony_elixir, :ci_test_failed_log, Enum.map_join(1..5, "\n", &"line #{&1}") <> "\nERROR: specs failed\nstack")
    put_run(issue, now)
    Notifications.subscribe()

    assert {:ok, %{actions: [{:rerun_requested, "issue-2401", "987"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert {:ok, %{actions: [{:state_transitioned, "issue-2401", :ci_failure, "In Progress"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:ci_failure_at_transition, "issue-2401", %{commit_sha: "abc123", log_excerpt: transition_log_excerpt}}
    assert_receive {:issue_state_update, "issue-2401", "In Progress"}
    assert_receive {:fetch_failed_log, "987"}
    assert_receive {:notification_event, %{event: "ci_failed", state: "In Progress", metadata: %{retry_count: 1}}}
    assert transition_log_excerpt =~ "ERROR: specs failed"

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

    assert {:ok, %{actions: [{:already_handled, "issue-2401", "abc123"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 2, :minute))

    refute_receive {:issue_state_update, _, _}
  end

  test "failed log fetch errors back off without dispatching or consuming retries" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))
    Application.put_env(:symphony_elixir, :ci_test_failed_log_error, :log_not_ready)
    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "rerun_requested",
               ci_retry_count: 0,
               rerun_attempted_shas: ["abc123"],
               dispatched_shas: [],
               updated_at: now
             })

    assert {:ok, %{actions: [{:poll_error, "issue-2401", {:failed_log_unavailable, "987", :log_not_ready}}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:fetch_failed_log, "987"}
    refute_receive {:issue_state_update, _, _}

    assert [%{status: "poll_error", ci_retry_count: 0, dispatched_shas: [], error: "{:failed_log_unavailable, \"987\", :log_not_ready}"}] =
             RunStore.list_ci_checks()
  end

  test "failed persistence prevents dispatch transition and ci notification" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))

    Application.put_env(:symphony_elixir, :ci_test_ci_record, %{
      repo_key: @repo_key,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_url: issue.url,
      pr_url: List.first(issue.pr_urls),
      workspace_path: "/tmp/workspaces/ACME-2401",
      status: "rerun_requested",
      ci_retry_count: 0,
      rerun_attempted_shas: ["abc123"],
      dispatched_shas: [],
      updated_at: now
    })

    Notifications.subscribe()

    assert {:ok, %{actions: [{:update_error, "issue-2401", {:update_ci_check_failed, :write_failed}}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, run_store: FailingUpdateRunStore, now: DateTime.add(now, 1, :minute))

    refute_receive {:issue_state_update, _, _}
    refute_receive {:notification_event, %{event: "ci_failed"}}
  end

  test "max retries escalates instead of dispatching again" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
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
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               rerun_attempted_shas: ["def456"],
               dispatched_shas: ["abc123"],
               updated_at: now
             })

    Notifications.subscribe()

    assert {:ok, %{actions: [{:escalated, "issue-2401", "In Review"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

    assert_receive {:issue_state_update, "issue-2401", "In Review"}
    assert_receive {:notification_event, %{event: "ci_escalated", state: "In Review", metadata: %{max_retries: 1, escalation_state: "In Review"}}}

    assert [%{status: "escalated", ci_retry_count: 1}] = RunStore.list_ci_checks()
  end

  test "green ci resets retry state without Linear label writes" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [issue])
    Application.put_env(:symphony_elixir, :ci_test_status, green_status("def456"))
    put_run(issue, now)

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "dispatch_requested",
               ci_retry_count: 2,
               dispatched_shas: ["abc123"],
               rerun_attempted_shas: ["abc123"],
               updated_at: now
             })

    assert {:ok, %{actions: [{:green, "issue-2401"}]}} =
             CiPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: DateTime.add(now, 1, :minute))

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

  test "Linear transition errors use CI poll backoff" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "rerun_requested",
               consecutive_errors: 2,
               ci_retry_count: 0,
               rerun_attempted_shas: ["abc123"],
               dispatched_shas: [],
               updated_at: now
             })

    poll_time = DateTime.add(now, 1, :minute)

    assert {:ok, %{actions: [{:state_transition_error, "issue-2401", :dispatch, :linear_unavailable}]}} =
             CiPoller.poll_once(
               tracker: FailingTransitionTracker,
               github: FakeGitHub,
               poll_interval_ms: 1_000,
               now: poll_time
             )

    assert_receive {:issue_state_update, "issue-2401", "In Progress"}

    assert [%{status: "state_transition_error", consecutive_errors: 3, next_poll_at: next_poll_at}] =
             RunStore.list_ci_checks()

    assert DateTime.diff(next_poll_at, poll_time, :millisecond) == 1_000

    assert {:ok, %{actions: [{:backing_off, "issue-2401", ^next_poll_at}]}} =
             CiPoller.poll_once(
               tracker: FailingTransitionTracker,
               github: FakeGitHub,
               poll_interval_ms: 1_000,
               now: DateTime.add(poll_time, 999, :millisecond)
             )
  end

  test "pr review poller yields rework ownership while ci owns the issue" do
    now = ~U[2026-05-06 09:00:00Z]

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: "issue-2401",
               status: "dispatch_requested",
               ci_retry_count: 1,
               updated_at: now
             })

    assert :ok =
             RunStore.put_pr_review(%{
               repo_key: @repo_key,
               issue_id: "issue-2401",
               issue_identifier: "ACME-2401",
               pr_url: "https://github.com/example/repo/pull/2401",
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "watching",
               updated_at: now
             })

    Application.put_env(:symphony_elixir, :ci_test_review_activity, %{
      pr_url: "https://github.com/example/repo/pull/2401",
      state: "OPEN",
      review_decision: "CHANGES_REQUESTED",
      latest_activity_at: DateTime.add(now, -31, :minute),
      latest_review_activity_at: DateTime.add(now, -31, :minute),
      comments: [
        %{
          id: "reviewer-review",
          kind: "review",
          state: "CHANGES_REQUESTED",
          author: "human-reviewer",
          body: "Please address.",
          url: "https://github.com/example/repo/pull/2401#pullrequestreview-1",
          created_at: DateTime.add(now, -31, :minute),
          updated_at: DateTime.add(now, -31, :minute)
        }
      ]
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

  test "log truncation replaces invalid utf-8 bytes instead of raising" do
    log = <<"ERROR: broken\n", 0xFF, 0xFE, "\nlast">>

    assert CiPoller.log_excerpt_for_test(log, 5) == "ERROR: broken\n??\nlast"
  end

  test "Linear transition failure leaves dispatch state recorded so the SHA is not redispatched" do
    now = ~U[2026-05-06 09:00:00Z]
    issue = in_review_issue()
    Application.put_env(:symphony_elixir, :ci_test_issues, [])
    Application.put_env(:symphony_elixir, :ci_test_status, failed_status("abc123"))

    assert :ok =
             RunStore.put_ci_check(%{
               repo_key: @repo_key,
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               issue_url: issue.url,
               pr_url: List.first(issue.pr_urls),
               workspace_path: "/tmp/workspaces/ACME-2401",
               status: "rerun_requested",
               ci_retry_count: 0,
               rerun_attempted_shas: ["abc123"],
               dispatched_shas: [],
               updated_at: now
             })

    poll_time = DateTime.add(now, 1, :minute)

    assert {:ok, %{actions: [{:state_transition_error, "issue-2401", :dispatch, :linear_unavailable}]}} =
             CiPoller.poll_once(
               tracker: FailingTransitionTracker,
               github: FakeGitHub,
               poll_interval_ms: 1_000,
               now: poll_time
             )

    assert_receive {:issue_state_update, "issue-2401", "In Progress"}

    assert [
             %{
               status: "state_transition_error",
               ci_retry_count: 1,
               dispatched_shas: ["abc123"],
               ci_failure: %{commit_sha: "abc123"},
               log_excerpt: log_excerpt
             }
           ] = RunStore.list_ci_checks()

    assert is_binary(log_excerpt) and log_excerpt != ""

    # A subsequent poll past the backoff window must not re-dispatch the same SHA.
    later = DateTime.add(poll_time, 2, :minute)

    assert {:ok, %{actions: [{:already_handled, "issue-2401", "abc123"}]}} =
             CiPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               poll_interval_ms: 1_000,
               now: later
             )

    refute_receive {:issue_state_update, _, _}
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
      identifier: "ACME-2401",
      title: "Handle CI",
      state: "In Review",
      url: "https://linear.test/ACME-2401",
      pr_urls: ["https://github.com/example/repo/pull/2401"],
      labels: []
    }
  end

  defp put_run(issue, now) do
    RunStore.put_run(%{
      repo_key: @repo_key,
      run_id: "run-1",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      status: "success",
      workspace_path: "/tmp/workspaces/ACME-2401",
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

  defp multi_failed_status(sha) do
    %{
      pr_url: "https://github.com/example/repo/pull/2401",
      pr_title: "Handle CI",
      state: "OPEN",
      commit_sha: sha,
      checks: [
        %{name: "specs", status: "COMPLETED", conclusion: "FAILURE", run_id: "987"},
        %{name: "lint", status: "COMPLETED", conclusion: "FAILURE", run_id: "654"},
        %{name: "specs retry", status: "COMPLETED", conclusion: "FAILURE", run_id: "987"}
      ]
    }
  end
end
