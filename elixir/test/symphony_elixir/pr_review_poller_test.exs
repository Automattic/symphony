defmodule SymphonyElixir.PrReviewPollerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PrReviewPoller

  defmodule FakeTracker do
    alias SymphonyElixir.Linear.Issue

    @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issues_by_states(_states) do
      {:ok, Application.get_env(:symphony_elixir, :pr_review_test_issues, [])}
    end

    @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]}
    def fetch_issue_states_by_ids(issue_ids) do
      wanted = MapSet.new(issue_ids)

      issues =
        :symphony_elixir
        |> Application.get_env(:pr_review_test_issues, [])
        |> Enum.filter(fn %Issue{id: id} -> MapSet.member?(wanted, id) end)

      {:ok, issues}
    end

    @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
    def update_issue_state(issue_id, state_name) do
      if take_failure(:pr_review_test_state_update_failures, issue_id) do
        {:error, :linear_unavailable}
      else
        recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
        send(recipient, {:issue_state_update, issue_id, state_name})
        :ok
      end
    end

    defp take_failure(key, value) do
      failures = Application.get_env(:symphony_elixir, key, [])

      if value in failures do
        Application.put_env(:symphony_elixir, key, List.delete(failures, value))
        true
      else
        false
      end
    end
  end

  defmodule FakeGitHub do
    @spec fetch_activity(String.t(), keyword()) :: {:ok, map()}
    def fetch_activity(_pr_url, _opts) do
      {:ok, Application.fetch_env!(:symphony_elixir, :pr_review_test_activity)}
    end
  end

  defmodule FailingGitHub do
    @spec fetch_activity(String.t(), keyword()) :: {:error, term()}
    def fetch_activity(pr_url, _opts) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:github_fetch, pr_url})

      {:error, Application.get_env(:symphony_elixir, :pr_review_test_github_error, :rate_limited)}
    end
  end

  defmodule RaisingRunStore do
    @spec list_runs(:all) :: no_return()
    def list_runs(:all), do: raise("poll exploded")

    @spec list_pr_reviews() :: [map()]
    def list_pr_reviews, do: []
  end

  defmodule StatefulRunStore do
    @spec list_runs(:all) :: [map()]
    def list_runs(:all), do: Application.get_env(:symphony_elixir, :pr_review_test_runs, [])

    @spec list_pr_reviews() :: [map()]
    def list_pr_reviews do
      :symphony_elixir
      |> Application.get_env(:pr_review_test_review_records, %{})
      |> Map.values()
    end

    @spec put_pr_review(map()) :: :ok | {:error, term()}
    def put_pr_review(%{issue_id: issue_id} = record) do
      if take_failure(:pr_review_test_put_failures, issue_id) do
        {:error, :disk_full}
      else
        records = Application.get_env(:symphony_elixir, :pr_review_test_review_records, %{})
        Application.put_env(:symphony_elixir, :pr_review_test_review_records, Map.put(records, issue_id, record))
        recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
        send(recipient, {:put_review, issue_id})
        :ok
      end
    end

    @spec update_pr_review(String.t(), map()) :: :ok | {:error, term()}
    def update_pr_review(issue_id, attrs) do
      if take_failure(:pr_review_test_update_status_failures, Map.get(attrs, :status)) do
        {:error, :disk_full}
      else
        records = Application.get_env(:symphony_elixir, :pr_review_test_review_records, %{})

        case Map.fetch(records, issue_id) do
          {:ok, record} ->
            Application.put_env(
              :symphony_elixir,
              :pr_review_test_review_records,
              Map.put(records, issue_id, Map.merge(record, attrs))
            )

            recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
            send(recipient, {:update_review, issue_id, attrs})
            :ok

          :error ->
            {:error, :pr_review_not_found}
        end
      end
    end

    @spec delete_pr_review(String.t()) :: :ok | {:error, term()}
    def delete_pr_review(issue_id) do
      if take_failure(:pr_review_test_delete_failures, issue_id) do
        {:error, :disk_full}
      else
        records = Application.get_env(:symphony_elixir, :pr_review_test_review_records, %{})
        Application.put_env(:symphony_elixir, :pr_review_test_review_records, Map.delete(records, issue_id))
        :ok
      end
    end

    defp take_failure(key, value) do
      failures = Application.get_env(:symphony_elixir, key, [])

      if value in failures do
        Application.put_env(:symphony_elixir, key, List.delete(failures, value))
        true
      else
        false
      end
    end
  end

  defmodule FakeWorkspace do
    @spec remove(String.t(), String.t() | nil) :: {:ok, [String.t()]}
    def remove(workspace_path, worker_host) do
      recipient = Application.fetch_env!(:symphony_elixir, :pr_review_test_recipient)
      send(recipient, {:remove_workspace, workspace_path, worker_host})

      {:ok, [workspace_path]}
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :pr_review_test_issues)
      Application.delete_env(:symphony_elixir, :pr_review_test_activity)
      Application.delete_env(:symphony_elixir, :pr_review_test_recipient)
      Application.delete_env(:symphony_elixir, :pr_review_test_runs)
      Application.delete_env(:symphony_elixir, :pr_review_test_review_records)
      Application.delete_env(:symphony_elixir, :pr_review_test_put_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_update_status_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_state_update_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_delete_failures)
      Application.delete_env(:symphony_elixir, :pr_review_test_github_error)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      pr_review_mode: "polling",
      pr_review_cooldown_minutes: 30,
      pr_review_stale_days: 7
    )

    Application.put_env(:symphony_elixir, :pr_review_test_recipient, self())
    :ok
  end

  test "discovers in-review PRs and persists workspace tracking metadata" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now))

    assert :ok =
             RunStore.put_run(%{
               run_id: "run-1",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               status: "success",
               workspace_path: "/tmp/workspaces/RSM-1780",
               worker_host: nil,
               started_at: DateTime.add(now, -120, :second),
               ended_at: DateTime.add(now, -60, :second)
             })

    assert {:ok, %{discovered: 1, processed: 1}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    assert [
             %{
               issue_id: "issue-1780",
               issue_identifier: "RSM-1780",
               pr_url: "https://github.com/example/repo/pull/1780",
               workspace_path: "/tmp/workspaces/RSM-1780",
               status: "watching"
             }
           ] = RunStore.list_pr_reviews()
  end

  test "discovers workspace from newest completed run regardless of store order" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now))

    Application.put_env(:symphony_elixir, :pr_review_test_runs, [
      review_run(issue, "/tmp/workspaces/old", DateTime.add(now, -2, :hour)),
      review_run(issue, "/tmp/workspaces/new", DateTime.add(now, -5, :minute)),
      review_run(issue, "/tmp/workspaces/running", now, %{status: "running"})
    ])

    assert {:ok, %{discovered: 1, processed: 1, actions: [{:watching, "issue-1780"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    assert [%{workspace_path: "/tmp/workspaces/new"}] =
             StatefulRunStore.list_pr_reviews()
  end

  test "waits for cooldown before moving a rework issue back to an active state" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_review_at = DateTime.add(now, -10, :minute)
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    :ok = put_review(now)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_review_at,
        review_decision: "CHANGES_REQUESTED",
        comments: [%{kind: "inline_comment", author: "reviewer", body: "Please split this.", url: "https://github.com/example/repo/pull/1780#discussion_r1"}]
      )
    )

    assert {:ok, %{actions: [{:cooling_down, "issue-1780"}]}} =
             PrReviewPoller.poll_once(tracker: FakeTracker, github: FakeGitHub, now: now)

    refute_receive {:issue_state_update, _, _}

    latest_review_at = DateTime.add(now, -31, :minute)

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_review_at,
        review_decision: "CHANGES_REQUESTED",
        comments: [%{kind: "inline_comment", author: "reviewer", body: "Please split this.", url: "https://github.com/example/repo/pull/1780#discussion_r1"}]
      )
    )

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :rework, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{status: "rework_requested", target_issue_state: "In Progress", last_action: "rework"}] =
             RunStore.list_pr_reviews()
  end

  test "moves an approved issue back to an active state for orchestrator-owned merge handling" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, review_decision: "APPROVED"))
    :ok = put_review(now)

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :merge, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [%{status: "merge_requested", target_issue_state: "In Progress", last_action: "merge"}] =
             RunStore.list_pr_reviews()
  end

  test "approval wins over stale cleanup" do
    now = ~U[2026-05-01 09:00:00Z]
    old_activity_at = DateTime.add(now, -8, :day)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(old_activity_at, review_decision: "APPROVED")
    )

    :ok = put_review(now)

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :merge, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}
    refute_receive {:remove_workspace, _, _}, 50
  end

  test "does not respawn rework when only PR activity changed after handled review comments" do
    now = ~U[2026-05-01 09:00:00Z]
    review_activity_at = DateTime.add(now, -90, :minute)
    latest_pr_activity_at = DateTime.add(now, -10, :minute)
    last_action_at = DateTime.add(review_activity_at, 30, :minute)

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    :ok =
      put_review(now, %{
        status: "rework_requested",
        last_action: "rework",
        last_action_at: last_action_at,
        last_activity_at: review_activity_at,
        last_review_activity_at: review_activity_at
      })

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_pr_activity_at,
        latest_review_activity_at: review_activity_at,
        review_decision: "CHANGES_REQUESTED",
        comments: [%{kind: "review", author: "reviewer", body: "Already handled.", url: "https://github.com/example/repo/pull/1780#pullrequestreview-1"}]
      )
    )

    assert {:ok, %{actions: [{:already_handled, "issue-1780", :rework}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    refute_receive {:issue_state_update, _, _}

    assert [
             %{
               status: "watching",
               last_activity_at: ^latest_pr_activity_at,
               last_review_activity_at: ^review_activity_at
             }
           ] = RunStore.list_pr_reviews()
  end

  test "records issue state transition errors without crashing the poll" do
    now = ~U[2026-05-01 09:00:00Z]
    latest_review_at = DateTime.add(now, -31, :minute)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    Application.put_env(
      :symphony_elixir,
      :pr_review_test_activity,
      open_activity(latest_review_at, review_decision: "APPROVED")
    )

    :ok = put_review(now)

    Application.put_env(:symphony_elixir, :pr_review_test_state_update_failures, ["issue-1780"])

    assert {:ok, %{actions: [{:state_transition_error, "issue-1780", :merge, :linear_unavailable}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               now: now
             )

    assert [%{status: "state_transition_error", error: ":linear_unavailable", last_action: "merge"}] =
             RunStore.list_pr_reviews()
  end

  test "cleans up workspace and tracking when PR is closed or stale" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    :ok = put_review(now)

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "closed"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/RSM-1780", nil}
    assert [] = RunStore.list_pr_reviews()

    stale_activity_at = DateTime.add(now, -8, :day)
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(stale_activity_at))
    :ok = put_review(now)

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "stale"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/RSM-1780", nil}
    assert [] = RunStore.list_pr_reviews()
  end

  test "does not remove workspace again when review delete fails after cleanup" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    Application.put_env(:symphony_elixir, :pr_review_test_delete_failures, ["issue-1780"])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" => review_record(now)
    })

    assert {:ok, %{actions: [{:cleanup_error, "issue-1780", :disk_full}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/RSM-1780", nil}

    assert [%{status: "cleanup_pending", workspace_removed_at: ^now}] =
             StatefulRunStore.list_pr_reviews()

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "closed"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: DateTime.add(now, 5, :second)
             )

    refute_receive {:remove_workspace, _, _}, 50
    assert [] = StatefulRunStore.list_pr_reviews()
  end

  test "does not remove workspace again when cleanup mark update fails before delete failure" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    Application.put_env(:symphony_elixir, :pr_review_test_update_status_failures, ["cleanup_pending"])
    Application.put_env(:symphony_elixir, :pr_review_test_delete_failures, ["issue-1780"])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" => review_record(now)
    })

    assert {:ok, %{actions: [{:cleanup_error, "issue-1780", :disk_full}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: now
             )

    assert_receive {:remove_workspace, "/tmp/workspaces/RSM-1780", nil}
    assert_receive {:put_review, "issue-1780"}

    assert [%{status: "cleanup_pending", workspace_removed_at: ^now}] =
             StatefulRunStore.list_pr_reviews()

    assert {:ok, %{actions: [{:cleanup, "issue-1780", "closed"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               workspace: FakeWorkspace,
               now: DateTime.add(now, 5, :second)
             )

    refute_receive {:remove_workspace, _, _}, 50
    assert [] = StatefulRunStore.list_pr_reviews()
  end

  test "reports cleanup error when workspace removal update and fallback put both fail" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, state: "MERGED"))
    Application.put_env(:symphony_elixir, :pr_review_test_update_status_failures, ["cleanup_pending"])
    Application.put_env(:symphony_elixir, :pr_review_test_put_failures, ["issue-1780"])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" => review_record(now)
    })

    expected_reason =
      {:workspace_removed_update_failed, {:update_pr_review_failed, :disk_full}, :disk_full}

    log =
      capture_log([level: :warning], fn ->
        assert {:ok,
                %{
                  actions: [
                    {:cleanup_error, "issue-1780", ^expected_reason}
                  ]
                }} =
                 PrReviewPoller.poll_once(
                   tracker: FakeTracker,
                   run_store: StatefulRunStore,
                   github: FakeGitHub,
                   workspace: FakeWorkspace,
                   now: now
                 )
      end)

    assert_receive {:remove_workspace, "/tmp/workspaces/RSM-1780", nil}
    assert log =~ "Failed to update PR review workspace removal issue_id=issue-1780"
    assert log =~ "Failed to persist PR review workspace removal issue_id=issue-1780"

    assert [%{status: "watching"} = record] = StatefulRunStore.list_pr_reviews()
    refute Map.has_key?(record, :workspace_removed_at)
  end

  test "continues review discovery when one record fails to persist" do
    now = ~U[2026-05-01 09:00:00Z]

    failing_issue =
      in_review_issue(
        id: "issue-fail",
        identifier: "RSM-FAIL",
        pr_url: "https://github.com/example/repo/pull/1",
        updated_at: now
      )

    ok_issue =
      in_review_issue(
        id: "issue-ok",
        identifier: "RSM-OK",
        pr_url: "https://github.com/example/repo/pull/2",
        updated_at: now
      )

    Application.put_env(:symphony_elixir, :pr_review_test_issues, [failing_issue, ok_issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now))
    Application.put_env(:symphony_elixir, :pr_review_test_put_failures, ["issue-fail"])

    Application.put_env(:symphony_elixir, :pr_review_test_runs, [
      review_run(failing_issue, "/tmp/workspaces/RSM-FAIL", now),
      review_run(ok_issue, "/tmp/workspaces/RSM-OK", now)
    ])

    assert {:ok, %{discovered: 1, processed: 1}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:put_review, "issue-ok"}

    assert [%{issue_id: "issue-ok", workspace_path: "/tmp/workspaces/RSM-OK"}] =
             StatefulRunStore.list_pr_reviews()
  end

  test "backs off GitHub polling after repeated fetch failures" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now, %{consecutive_errors: 2})
    })

    assert {:ok, %{actions: [{:poll_error, "issue-1780", :rate_limited}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FailingGitHub,
               now: now,
               poll_interval_ms: 5_000
             )

    assert_receive {:github_fetch, "https://github.com/example/repo/pull/1780"}

    assert [%{consecutive_errors: 3, next_poll_at: next_poll_at}] =
             StatefulRunStore.list_pr_reviews()

    assert DateTime.diff(next_poll_at, now, :millisecond) == 5_000

    assert {:ok, %{actions: [{:backing_off, "issue-1780", ^next_poll_at}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FailingGitHub,
               now: DateTime.add(now, 1, :second),
               poll_interval_ms: 5_000
             )

    refute_receive {:github_fetch, _pr_url}, 50
  end

  test "poll callback uses cached interval when workflow config becomes invalid" do
    {:ok, state} = PrReviewPoller.init(poll_interval_ms: 123)
    Process.cancel_timer(state.timer_ref)

    File.write!(Workflow.workflow_file_path(), "---\npr_review:\n  mode: [broken]\n---\n")

    assert {:noreply, next_state} = PrReviewPoller.handle_info(:poll, state)
    assert next_state.poll_interval_ms == 123
    assert Keyword.fetch!(next_state.opts, :poll_interval_ms) == 123
    assert is_reference(next_state.timer_ref)

    Process.cancel_timer(next_state.timer_ref)
  end

  test "poll callback logs exceptions and keeps scheduling" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])

    {:ok, state} =
      PrReviewPoller.init(
        tracker: FakeTracker,
        run_store: RaisingRunStore,
        poll_interval_ms: 123,
        now: now
      )

    Process.cancel_timer(state.timer_ref)

    log =
      capture_log([level: :error], fn ->
        assert {:noreply, next_state} = PrReviewPoller.handle_info(:poll, state)
        assert next_state.poll_interval_ms == 123
        assert Keyword.fetch!(next_state.opts, :poll_interval_ms) == 123
        assert is_reference(next_state.timer_ref)
        Process.cancel_timer(next_state.timer_ref)
      end)

    assert log =~ "PR review poll raised"
    assert log =~ "poll exploded"
  end

  test "poll callback logs warning-level signals for review action errors" do
    now = ~U[2026-05-01 09:00:00Z]
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [in_review_issue(updated_at: now)])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, review_decision: "APPROVED"))
    Application.put_env(:symphony_elixir, :pr_review_test_update_status_failures, ["merge_requested"])

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      "issue-1780" => review_record(now)
    })

    {:ok, state} =
      PrReviewPoller.init(
        tracker: FakeTracker,
        run_store: StatefulRunStore,
        github: FakeGitHub,
        poll_interval_ms: 123,
        now: now
      )

    Process.cancel_timer(state.timer_ref)

    log =
      capture_log([level: :warning], fn ->
        assert {:noreply, next_state} = PrReviewPoller.handle_info(:poll, state)
        Process.cancel_timer(next_state.timer_ref)
      end)

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}
    assert log =~ "PR review transition update error issue_id=issue-1780 action=merge"
    assert log =~ "update_pr_review_failed"
  end

  test "does not report state transition success when final review update fails" do
    now = ~U[2026-05-01 09:00:00Z]
    issue = in_review_issue(updated_at: now)
    Application.put_env(:symphony_elixir, :pr_review_test_issues, [issue])
    Application.put_env(:symphony_elixir, :pr_review_test_activity, open_activity(now, review_decision: "APPROVED"))

    Application.put_env(:symphony_elixir, :pr_review_test_review_records, %{
      issue.id => review_record(now)
    })

    Application.put_env(:symphony_elixir, :pr_review_test_update_status_failures, ["merge_requested"])

    assert {:ok,
            %{
              actions: [
                {:state_transition_update_error, "issue-1780", :merge, {:update_pr_review_failed, :disk_full}}
              ]
            }} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: now
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}

    assert [
             %{
               status: "watching"
             }
           ] = StatefulRunStore.list_pr_reviews()

    assert {:ok, %{actions: [{:state_transitioned, "issue-1780", :merge, "In Progress"}]}} =
             PrReviewPoller.poll_once(
               tracker: FakeTracker,
               run_store: StatefulRunStore,
               github: FakeGitHub,
               now: DateTime.add(now, 5, :second)
             )

    assert_receive {:issue_state_update, "issue-1780", "In Progress"}
  end

  defp put_review(now, attrs \\ %{}) do
    now
    |> review_record(attrs)
    |> RunStore.put_pr_review()
  end

  defp review_record(now, attrs \\ %{}) do
    %{
      issue_id: "issue-1780",
      issue_identifier: "RSM-1780",
      issue_url: "https://linear.app/a8c/issue/RSM-1780",
      pr_url: "https://github.com/example/repo/pull/1780",
      workspace_path: "/tmp/workspaces/RSM-1780",
      worker_host: nil,
      status: "watching",
      inserted_at: now,
      updated_at: now
    }
    |> Map.merge(attrs)
  end

  defp in_review_issue(opts) do
    updated_at = Keyword.fetch!(opts, :updated_at)
    id = Keyword.get(opts, :id, "issue-1780")
    identifier = Keyword.get(opts, :identifier, "RSM-1780")
    pr_url = Keyword.get(opts, :pr_url, "https://github.com/example/repo/pull/1780")

    %Issue{
      id: id,
      identifier: identifier,
      title: "Review manager",
      description: "Poll PR state",
      state: "In Review",
      url: "https://linear.app/a8c/issue/#{identifier}",
      pr_urls: [pr_url],
      updated_at: updated_at
    }
  end

  defp review_run(%Issue{} = issue, workspace_path, now, attrs \\ %{}) do
    %{
      run_id: "run-#{issue.id}",
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      status: "success",
      workspace_path: workspace_path,
      worker_host: nil,
      started_at: DateTime.add(now, -120, :second),
      ended_at: DateTime.add(now, -60, :second)
    }
    |> Map.merge(attrs)
  end

  defp open_activity(latest_activity_at, opts \\ []) do
    %{
      pr_url: "https://github.com/example/repo/pull/1780",
      state: Keyword.get(opts, :state, "OPEN"),
      review_decision: Keyword.get(opts, :review_decision),
      latest_activity_at: latest_activity_at,
      latest_review_activity_at: Keyword.get(opts, :latest_review_activity_at, latest_activity_at),
      comments: Keyword.get(opts, :comments, [])
    }
  end
end
