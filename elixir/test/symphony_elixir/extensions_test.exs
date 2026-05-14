defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.Tracker.Memory
  alias SymphonyElixirWeb.ObservabilityPubSub

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_candidate_issues_for_repo(repo) do
      send(self(), {:fetch_candidate_issues_for_repo_called, repo})
      {:ok, [repo]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def fetch_issue_enrichment(issue) do
      send(self(), {:fetch_issue_enrichment_called, issue})
      {:ok, %{issue | comments: [%{author: "Reviewer", body: "Existing context", created_at: ~U[2026-05-05 01:00:00Z]}]}}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      if owner = Keyword.get(state, :owner), do: send(owner, :request_refresh_called)

      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = terminate_workflow_store()
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert :ok = restart_workflow_store()
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = terminate_workflow_store()

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)

    restart_result =
      case workflow_store_supervisor() do
        nil -> WorkflowStore.start_link()
        supervisor -> Supervisor.restart_child(supervisor, workflow_store_child_id())
      end

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory and linear adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert {:ok, ^issue} = SymphonyElixir.Tracker.enrich_issue(issue)
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == Adapter
  end

  test "memory tracker repo fetch ignores unrouted issues" do
    routed_issue = %Issue{
      id: "issue-routed",
      identifier: "RSM-ROUTED",
      state: "Todo",
      team: %{key: "RSM"},
      labels: ["web"]
    }

    unrouted_issue = %Issue{id: "issue-unrouted", identifier: "RSM-UNROUTED", state: "Todo"}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [routed_issue, unrouted_issue])

    assert {:ok, [^routed_issue]} =
             Memory.fetch_candidate_issues_for_repo(%{name: "web", team: "RSM", labels: ["web"]})
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    repo = %{name: "web", team: "RSM"}
    assert {:ok, [^repo]} = Adapter.fetch_candidate_issues_for_repo(repo)
    assert_receive {:fetch_candidate_issues_for_repo_called, ^repo}

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    issue = %Issue{id: "issue-1", identifier: "MT-1"}
    assert {:ok, enriched_issue} = Adapter.enrich_issue(issue)
    assert enriched_issue.comments == [%{author: "Reviewer", body: "Existing context", created_at: ~U[2026-05-05 01:00:00Z]}]
    assert_receive {:fetch_issue_enrichment_called, ^issue}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = Adapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             Adapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = Adapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = Adapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             Adapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = Adapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = Adapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = Adapter.update_issue_state("issue-1", "Odd")
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "repos" => ["default"],
             "counts" => %{"running" => 1, "watching" => 1, "conflicts" => 0, "retrying" => 1},
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "repo_key" => "default",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "url" => "https://linear.app/example/issue/MT-HTTP",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "transcript_path" => nil,
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{
                   "input_tokens" => 4,
                   "cached_input_tokens" => 0,
                   "uncached_input_tokens" => 4,
                   "output_tokens" => 8,
                   "total_tokens" => 12
                 },
                 "self_review" => nil
               }
             ],
             "watching" => [
               %{
                 "issue_id" => "issue-watch",
                 "repo_key" => "default",
                 "issue_identifier" => "MT-WATCH",
                 "state" => "In Review",
                 "url" => "https://linear.app/example/issue/MT-WATCH",
                 "pull_request_url" => "https://github.com/example/repo/pull/123",
                 "last_ran_at" => state_payload["watching"] |> List.first() |> Map.fetch!("last_ran_at"),
                 "seconds_since_last_run" => 3_600
               }
             ],
             "conflicts" => [],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "repo_key" => "default",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "awaiting_clarification" => [],
             "skipped" => [],
             "run_history" => [
               %{
                 "run_id" => "run-http",
                 "repo_key" => "default",
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "title" => "HTTP snapshot",
                 "state" => "In Progress",
                 "status" => "success",
                 "attempt" => 1,
                 "started_at" => state_payload["run_history"] |> List.first() |> Map.fetch!("started_at"),
                 "ended_at" => state_payload["run_history"] |> List.first() |> Map.fetch!("ended_at"),
                 "error" => nil,
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "transcript_path" => nil,
                 "turn_count" => 7,
                 "runtime_seconds" => 42,
                 "tokens" => %{"input_tokens" => 4, "output_tokens" => 8, "total_tokens" => 12},
                 "self_review" => nil
               }
             ],
             "codex_totals" => %{
               "input_tokens" => 4,
               "cached_input_tokens" => 0,
               "uncached_input_tokens" => 4,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "pause" => %{
               "paused" => false,
               "reason" => nil,
               "paused_at" => nil
             },
             "budget" => %{
               "per_issue_limit" => 500,
               "daily_limit" => 1_000,
               "daily_used" => 400,
               "daily_remaining" => 600,
               "daily_paused" => false
             },
             "dispatch_state" => %{
               "active?" => true,
               "blockers" => []
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "repo_key" => "default",
             "issue_id" => "issue-http",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "repo_key" => "default",
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "transcript_path" => nil,
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{
                 "input_tokens" => 4,
                 "cached_input_tokens" => 0,
                 "uncached_input_tokens" => 4,
                 "output_tokens" => 8,
                 "total_tokens" => 12
               }
             },
             "retry" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-WATCH")
    watching_payload = json_response(conn, 200)

    assert watching_payload == %{
             "issue_identifier" => "MT-WATCH",
             "repo_key" => "default",
             "issue_id" => "issue-watch",
             "status" => "watching",
             "workspace" => nil,
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => nil,
             "retry" => nil,
             "watching" => %{
               "repo_key" => "default",
               "state" => "In Review",
               "url" => "https://linear.app/example/issue/MT-WATCH",
               "pull_request_url" => "https://github.com/example/repo/pull/123",
               "last_ran_at" => state_payload["watching"] |> List.first() |> Map.fetch!("last_ran_at"),
               "seconds_since_last_run" => 3_600
             },
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1:4000")
      |> post("/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api rejects cross-origin refresh before orchestration" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :CrossOriginRefreshOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        owner: self(),
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    missing_origin_conn = post(build_conn(), "/api/v1/refresh", %{})

    assert json_response(missing_origin_conn, 403) == %{
             "error" => %{"code" => "forbidden_origin", "message" => "Origin is not allowed"}
           }

    refute_received :request_refresh_called

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "https://evil.example")
      |> Plug.Conn.put_req_header("content-type", "text/plain")
      |> post("/api/v1/refresh", "")

    assert json_response(conn, 403) == %{
             "error" => %{"code" => "forbidden_origin", "message" => "Origin is not allowed"}
           }

    refute_received :request_refresh_called

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)
    assert state_payload["counts"] == %{"running" => 1, "watching" => 1, "conflicts" => 0, "retrying" => 1}
  end

  test "phoenix observability api allows configured origins to refresh" do
    allowed_origins = System.get_env("SYMPHONY_DASHBOARD_ALLOWED_ORIGINS")

    on_exit(fn ->
      case allowed_origins do
        nil -> System.delete_env("SYMPHONY_DASHBOARD_ALLOWED_ORIGINS")
        value -> System.put_env("SYMPHONY_DASHBOARD_ALLOWED_ORIGINS", value)
      end
    end)

    System.put_env("SYMPHONY_DASHBOARD_ALLOWED_ORIGINS", "https://dashboard.internal")

    orchestrator_name = Module.concat(__MODULE__, :AllowedOriginRefreshOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        owner: self(),
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "https://dashboard.internal")
      |> post("/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll"]} =
             json_response(conn, 202)

    assert_received :request_refresh_called
  end

  test "phoenix observability api exposes filtered quality runs and session reports" do
    now = DateTime.utc_now()
    yesterday = DateTime.add(now, -1, :day)

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: "default",
               eval_id: "eval-api-1",
               run_id: "run-api-1",
               issue_id: "issue-api-1",
               issue_identifier: "RSM-API-1",
               issue_labels: ["bug"],
               outcome: "pr_opened",
               status: "success",
               agent_kind: "codex",
               tokens: %{input_tokens: 20, output_tokens: 10, total_tokens: 30},
               duration_seconds: 45,
               tests_run: true,
               workspace_path: "/tmp/workspaces/RSM-API-1",
               session_id: "session-api-1",
               logged_at: now,
               date: DateTime.to_date(now)
             })

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: "default",
               eval_id: "eval-api-2",
               run_id: "run-api-2",
               issue_id: "issue-api-2",
               issue_identifier: "RSM-API-2",
               issue_labels: ["feature"],
               outcome: "error",
               status: "failure",
               error: "boom",
               agent_kind: "claude",
               tokens: %{input_tokens: 5, output_tokens: 5, total_tokens: 10},
               duration_seconds: 5,
               tests_run: false,
               session_id: "session-api-2",
               logged_at: yesterday,
               date: DateTime.to_date(yesterday)
             })

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :QualityApiOrchestrator), snapshot_timeout_ms: 5)

    payload =
      build_conn()
      |> get("/api/v1/runs?outcome=pr_opened&agent=codex&date_from=#{Date.to_iso8601(DateTime.to_date(now))}")
      |> json_response(200)

    assert payload["count"] == 1
    assert [%{"issue_identifier" => "RSM-API-1", "outcome" => "pr_opened", "agent_kind" => "codex"}] = payload["runs"]

    export_conn = get(build_conn(), "/api/v1/runs?export=json")

    assert Plug.Conn.get_resp_header(export_conn, "content-disposition") == [
             ~s(attachment; filename="symphony-quality-runs.json")
           ]

    assert json_response(export_conn, 200)["count"] == 2

    report =
      build_conn()
      |> get("/api/v1/runs/session-api-1/report")
      |> json_response(200)

    assert report["session_id"] == "session-api-1"
    assert report["metrics"]["pr_opened_rate"] == 1.0
    assert [%{"run_id" => "run-api-1"}] = report["runs"]
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/runs", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    unavailable_refresh_conn =
      build_conn()
      |> Plug.Conn.put_req_header("origin", "http://127.0.0.1:4000")
      |> post("/api/v1/refresh", %{})

    assert json_response(unavailable_refresh_conn, 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    assert html =~ ~r|/dashboard\.css\?v=[a-f0-9]{16}|
    assert html =~ ~r|/vendor/phoenix_html/phoenix_html\.js\?v=[a-f0-9]{16}|
    assert html =~ ~r|/vendor/phoenix/phoenix\.js\?v=[a-f0-9]{16}|
    assert html =~ ~r|/vendor/phoenix_live_view/phoenix_live_view\.js\?v=[a-f0-9]{16}|
    assert html =~ ~s(phx-track-static)
    assert html =~ "TranscriptFilter"
    assert html =~ "installRestartAwareReconnect"
    assert html =~ "liveSocket.getSocket().connect()"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css_conn = get(build_conn(), "/dashboard.css")
    dashboard_css = response(dashboard_css_conn, 200)

    assert Plug.Conn.get_resp_header(dashboard_css_conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]

    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ "minmax(150px, 1fr)"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"
    assert dashboard_css =~ ".transcript-list[data-filter-active=\"true\"] .transcript-event"

    for {filter, class} <- [
          {"agent-text", "agent-text"},
          {"tool-call", "tool-call"},
          {"tool-result", "tool-result"},
          {"session", "session"},
          {"error", "error"},
          {"event", "event"}
        ] do
      assert dashboard_css =~
               ".transcript-list[data-filter-#{filter}=\"true\"] .transcript-event-#{class}"
    end

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "Dispatch active"
    assert html =~ "Pause All"
    assert html =~ ~s(class="secondary pause-dispatch-button")
    assert html =~ ~s(href="/quality")
    assert html =~ "MT-HTTP"
    assert html =~ "MT-WATCH"
    assert html =~ "MT-RETRY"
    assert_repo_chip(html, "default")
    assert html =~ "Conflict"
    assert html =~ "No repo conflicts"
    assert html =~ "https://linear.app/example/issue/MT-WATCH"
    assert html =~ "https://linear.app/example/issue/MT-HTTP"
    assert html =~ "https://github.com/example/repo/pull/123"
    assert html =~ ~s(href="https://linear.app/example/issue/MT-HTTP" target="_blank")
    assert html =~ ~s(href="https://linear.app/example/issue/MT-WATCH" target="_blank")
    assert html =~ ~s(href="https://github.com/example/repo/pull/123" target="_blank")
    refute html =~ "Linear ↗"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert Regex.scan(~r/<th>Links<\/th>/, html) |> length() == 2
    assert html =~ "<th>Control</th>"
    assert html =~ "Stop"
    assert html =~ ~s(<td class="links-cell">)
    assert html =~ ~s(<div class="link-actions">)
    assert html =~ "thread-h…"
    assert html =~ "Codex update"
    assert html =~ "Budget: 488 left"
    assert html =~ "/repos/default/issues/MT-HTTP/transcript"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"
    assert html =~ "Awaiting clarification"
    assert html =~ "No issues awaiting clarification"
    assert html =~ "Skipped (quality gate)"
    assert html =~ "No issues skipped this session"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          repo_key: "default",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    assert :ok = ObservabilityPubSub.broadcast_update("github.com/acme/other")

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview narrows rows from repo query string" do
    orchestrator_name = Module.concat(__MODULE__, :FilteredDashboardOrchestrator)
    snapshot = multi_repo_snapshot()

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/?repo=api")

    assert html =~ ~s(<option value="api" selected)
    refute html =~ ~s(<option value="conflict")
    assert html =~ "MT-API"
    assert html =~ "MT-API-WATCH"
    assert html =~ "MT-CONFLICT"
    assert_repo_chip(html, "api")
    refute html =~ "MT-HTTP"
    refute html =~ "MT-WEB-RETRY"

    {:ok, _view, html} = live(build_conn(), "/?repo=conflict")

    assert html =~ ~s(<option value="" selected)
    refute html =~ ~s(<option value="conflict")
    assert html =~ "MT-API"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-CONFLICT"
    assert html =~ "MT-WEB-RETRY"
  end

  test "dashboard liveview allows an actual repo named conflict" do
    orchestrator_name = Module.concat(__MODULE__, :ConflictRepoDashboardOrchestrator)

    snapshot =
      multi_repo_snapshot()
      |> Map.update!(:running, fn rows ->
        [
          %{
            issue_id: "issue-conflict-repo",
            repo_key: "conflict",
            identifier: "MT-CONFLICT-REPO",
            state: "In Progress",
            url: "https://linear.app/example/issue/MT-CONFLICT-REPO",
            session_id: "thread-conflict-repo",
            turn_count: 1,
            codex_app_server_pid: nil,
            last_codex_message: "conflict repo update",
            last_codex_timestamp: nil,
            last_codex_event: :notification,
            codex_input_tokens: 1,
            codex_output_tokens: 2,
            codex_total_tokens: 3,
            started_at: DateTime.utc_now()
          }
          | rows
        ]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/?repo=conflict")

    assert html =~ ~s(<option value="conflict" selected)
    assert html =~ "MT-CONFLICT-REPO"
    assert_repo_chip(html, "conflict")
    refute html =~ "MT-API"
    refute html =~ conflict_repo_chip_pattern("api")
  end

  test "observability state payload exposes conflict row data shape" do
    orchestrator_name = Module.concat(__MODULE__, :ConflictStateOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: multi_repo_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = get(build_conn(), "/api/v1/state") |> json_response(200)

    assert payload["repos"] == ["api", "default", "web"]

    assert [
             %{
               "issue_id" => "issue-conflict",
               "issue_identifier" => "MT-CONFLICT",
               "state" => "Conflict",
               "linear_state" => "Todo",
               "repo_keys" => ["api", "web"]
             }
           ] = payload["conflicts"]
  end

  test "dashboard liveview renders empty retry and quality gate sections" do
    orchestrator_name = Module.concat(__MODULE__, :EmptyQueuesDashboardOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:retrying, [])
      |> Map.put(:awaiting_clarification, [])
      |> Map.put(:skipped, [])

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Retry queue"
    assert html =~ "No queued retries"
    assert html =~ "Awaiting clarification"
    assert html =~ "No issues awaiting clarification"
    assert html =~ "Skipped (quality gate)"
    assert html =~ "No issues skipped this session"
  end

  test "dashboard liveview renders quality gate issue sections" do
    orchestrator_name = Module.concat(__MODULE__, :QualityGateSectionsDashboardOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:awaiting_clarification, [
        %{
          kind: :clarification,
          issue_id: "issue-await",
          repo_key: "api",
          identifier: "MT-AWAIT",
          url: "https://example.org/MT-AWAIT",
          score: 5,
          reason: "needs acceptance criteria",
          rounds_asked: 2,
          updated_at: ~U[2026-05-05 03:00:00Z]
        }
      ])
      |> Map.put(:skipped, [
        %{
          kind: :scored,
          issue_id: "issue-skip",
          repo_key: "web",
          identifier: "MT-SKIP",
          url: "https://example.org/MT-SKIP",
          score: 3,
          reason: "vague description",
          updated_at: ~U[2026-05-05 04:00:00Z]
        },
        %{
          kind: :error,
          issue_id: "issue-error",
          repo_key: "api",
          identifier: "MT-ERR",
          url: "https://example.org/MT-ERR",
          error: :llm_timeout,
          updated_at: ~U[2026-05-05 05:00:00Z]
        }
      ])

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "MT-AWAIT"
    assert_repo_chip(html, "api")
    assert html =~ "needs acceptance criteria"
    assert html =~ "https://example.org/MT-AWAIT"
    assert html =~ "2026-05-05T03:00:00Z"
    assert html =~ "MT-SKIP"
    assert_repo_chip(html, "web")
    assert html =~ "Scored"
    assert html =~ "vague description"
    assert html =~ "MT-ERR"
    assert html =~ "Error"
    assert html =~ ":llm_timeout"
  end

  test "dashboard liveview renders persisted pause reason and timestamp" do
    orchestrator_name = Module.concat(__MODULE__, :PausedDashboardOrchestrator)
    paused_at = ~U[2026-05-06 08:30:00Z]
    snapshot = Map.put(static_snapshot(), :pause, %{paused: true, reason: "deploy window", paused_at: paused_at})

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Dispatch paused"
    assert html =~ "deploy window"
    assert html =~ "2026-05-06T08:30:00Z"
    assert html =~ "Resume All"
  end

  test "dashboard liveview renders operational dispatch_state blocker chips" do
    orchestrator_name = Module.concat(__MODULE__, :BlockerChipsDashboardOrchestrator)

    snapshot =
      Map.put(static_snapshot(), :dispatch_state, %{
        active?: false,
        blockers: [
          %{
            kind: :budget,
            used: 88_402_765,
            limit: 5_000_000,
            day_started_on: ~D[2026-05-08],
            resets_on: ~D[2026-05-09]
          },
          %{
            kind: :workspace_dirty,
            repo: "/Users/chihsuan/Projects/symphony",
            dirty_summary: "M elixir/WORKFLOW.md"
          }
        ]
      })

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Dispatch paused"
    assert html =~ "Daily token budget exhausted"
    assert html =~ "88.4M / 5M"
    assert html =~ "resets 2026-05-09"
    assert html =~ "ops-control-blocker-budget"
    refute html =~ "Primary worktree has uncommitted changes"
    refute html =~ "ops-control-blocker-workspace_dirty"
  end

  test "dashboard liveview ignores stale workspace dirty dispatch blockers" do
    orchestrator_name = Module.concat(__MODULE__, :WorkspaceDirtyDashboardOrchestrator)

    snapshot =
      Map.put(static_snapshot(), :dispatch_state, %{
        active?: false,
        blockers: [
          %{
            kind: :workspace_dirty,
            repo: "/Users/chihsuan/Projects/symphony",
            dirty_summary: "M elixir/WORKFLOW.md"
          }
        ]
      })

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "Dispatch active"
    refute html =~ "Dispatch paused"
    refute html =~ "Primary worktree has uncommitted changes"
  end

  test "dashboard liveview disarms armed pause control after timeout" do
    Application.put_env(:symphony_elixir, :dashboard_control_confirm_timeout_ms, 5)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :dashboard_control_confirm_timeout_ms)
    end)

    orchestrator_name = Module.concat(__MODULE__, :DisarmDashboardOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot()
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, _html} = live(build_conn(), "/")

    assert view
           |> element("button", "Pause All")
           |> render_click() =~ "Confirm Pause"

    assert_eventually(fn ->
      html = render(view)
      String.contains?(html, "Pause All") and not String.contains?(html, "Confirm Pause")
    end)
  end

  test "quality liveview renders metrics, recent eval logs, and filters" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: "default",
               eval_id: "eval-live-1",
               run_id: "run-live-1",
               issue_id: "issue-live-1",
               issue_identifier: "RSM-LIVE-1",
               issue_labels: ["bug"],
               outcome: "pr_opened",
               status: "stopped",
               error: "agent stopped by orchestrator",
               error_kind: "failure",
               agent_kind: "codex",
               tokens: %{input_tokens: 30, output_tokens: 20, total_tokens: 50},
               duration_seconds: 90,
               tests_run: true,
               session_id: "session-live-1",
               logged_at: now,
               date: DateTime.to_date(now)
             })

    assert :ok =
             RunStore.put_eval_log(%{
               repo_key: "default",
               eval_id: "eval-live-2",
               run_id: "run-live-2",
               issue_id: "issue-live-2",
               issue_identifier: "RSM-LIVE-2",
               issue_labels: ["feature"],
               outcome: "error",
               status: "failure",
               agent_kind: "claude",
               tokens: %{input_tokens: 10, output_tokens: 5, total_tokens: 15},
               duration_seconds: 30,
               tests_run: false,
               logged_at: now,
               date: DateTime.to_date(now)
             })

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :QualityLiveOrchestrator), snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/quality?agent=codex&outcome=pr_opened")

    assert html =~ "Quality Dashboard"
    assert html =~ "PR-opened rate"
    assert html =~ "Avg tokens"
    assert html =~ "Tests-run rate"
    assert html =~ "Error rate"
    assert html =~ "RSM-LIVE-1"
    refute html =~ "RSM-LIVE-2"
    assert html =~ "Status"
    assert html =~ "Stopped"
    assert html =~ "agent stopped by orchestrator"
    refute html =~ "failure"
    assert html =~ ~s(name="agent")
    assert html =~ ~s(name="outcome")
    assert html =~ ~s(href="/")
    assert html =~ "/api/v1/runs?export=json"
  end

  test "learnings liveview renders records and filters by repo and tag" do
    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_learnings(
               [
                 %{
                   repo_key: "default",
                   id: "learning-live-1",
                   host: "github.com",
                   owner: "example",
                   repo: "repo",
                   rule: "Prefer existing dashboard helpers.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Prefer the existing helper.",
                   evidence_issue_identifier: "RSM-LIVE-1",
                   evidence_issue_url: "https://linear.app/a8c/issue/RSM-LIVE-1",
                   evidence_pr_number: 12,
                   evidence_run_id: "run-live-1",
                   created_at: now
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-3",
                   repo: "github.com/example/repo",
                   rule: "Do not reconstruct Linear links without canonical issue URLs.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Avoid workspace-specific Linear URL assumptions.",
                   evidence_issue_identifier: "RSM-LIVE-3",
                   evidence_issue_url: nil,
                   evidence_pr_number: 14,
                   evidence_run_id: "run-live-3",
                   created_at: DateTime.add(now, -30, :second)
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-2",
                   repo: "github.com/other/repo",
                   rule: "Keep unrelated records filterable.",
                   tags: ["docs", "workflow-config"],
                   evidence_quote: "Update docs too.",
                   evidence_issue_identifier: "RSM-LIVE-2",
                   evidence_issue_url: "https://linear.example.test/acme/RSM-LIVE-2",
                   evidence_pr_number: 13,
                   evidence_run_id: "run-live-2",
                   created_at: DateTime.add(now, -60, :second)
                 }
               ],
               500
             )

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :LearningsLiveOrchestrator), snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/learnings?repo=github.com/example/repo&tag=dashboard")

    assert html =~ "Learnings"
    assert html =~ "Prefer existing dashboard helpers."
    assert html =~ "Prefer the existing helper."
    assert html =~ "Do not reconstruct Linear links without canonical issue URLs."
    assert html =~ "github.com/example/repo"
    assert html =~ ~s(href="https://github.com/example/repo/pull/12" target="_blank")
    assert html =~ ~s(href="https://linear.app/a8c/issue/RSM-LIVE-1" target="_blank")
    refute html =~ "https://linear.app/a8c/issue/RSM-LIVE-3"
    assert html =~ ~s(name="repo")
    assert html =~ ~s(name="tag")
    assert html =~ ~s(href="/quality")
    refute html =~ "Keep unrelated records filterable."
  end

  test "learnings liveview hides untrusted PR and Linear evidence links" do
    write_workflow_file!(Workflow.workflow_file_path(), github: %{enterprise_hosts: ["github.example.com"]})

    now = DateTime.utc_now()

    assert :ok =
             RunStore.put_learnings(
               [
                 %{
                   repo_key: "default",
                   id: "learning-live-trusted",
                   host: "github.com",
                   owner: "example",
                   repo: "repo",
                   rule: "Keep trusted GitHub PRs linked.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Trusted PR.",
                   evidence_issue_identifier: "RSM-LIVE-TRUSTED",
                   evidence_issue_url: "https://linear.app/a8c/issue/RSM-LIVE-TRUSTED",
                   evidence_pr_number: 123,
                   evidence_run_id: "run-live-trusted",
                   created_at: now
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-ghe",
                   host: "github.example.com",
                   owner: "enterprise",
                   repo: "service",
                   rule: "Keep configured GitHub Enterprise PRs linked.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Trusted GHE PR.",
                   evidence_issue_identifier: "RSM-LIVE-GHE",
                   evidence_issue_url: "https://linear.app/a8c/issue/RSM-LIVE-GHE",
                   evidence_pr_number: 456,
                   evidence_run_id: "run-live-ghe",
                   created_at: DateTime.add(now, -15, :second)
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-attacker",
                   host: "login-github.attacker.tld",
                   owner: "foo",
                   repo: "bar",
                   rule: "Do not link attacker PR hosts.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Attacker PR.",
                   evidence_issue_identifier: "RSM-LIVE-ATTACKER",
                   evidence_issue_url: "https://linear.attacker.tld/a8c/issue/RSM-LIVE-ATTACKER",
                   evidence_pr_number: 9,
                   evidence_run_id: "run-live-attacker",
                   created_at: DateTime.add(now, -30, :second)
                 },
                 %{
                   repo_key: "default",
                   id: "learning-live-linear-scheme",
                   host: "github.com",
                   owner: "example",
                   repo: "other",
                   rule: "Do not link non-HTTPS Linear URLs.",
                   tags: ["dashboard", "repo-patterns"],
                   evidence_quote: "Unsafe Linear scheme.",
                   evidence_issue_identifier: "RSM-LIVE-SCHEME",
                   evidence_issue_url: "http://linear.app/a8c/issue/RSM-LIVE-SCHEME",
                   evidence_pr_number: 124,
                   evidence_run_id: "run-live-linear-scheme",
                   created_at: DateTime.add(now, -60, :second)
                 }
               ],
               500
             )

    start_test_endpoint(orchestrator: Module.concat(__MODULE__, :LearningsLiveSecurityOrchestrator), snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/learnings?tag=dashboard")

    assert html =~ "Keep trusted GitHub PRs linked."
    assert html =~ ~s(href="https://github.com/example/repo/pull/123" target="_blank")
    assert html =~ ~s(href="https://linear.app/a8c/issue/RSM-LIVE-TRUSTED" target="_blank")

    assert html =~ "Keep configured GitHub Enterprise PRs linked."
    assert html =~ ~s(href="https://github.example.com/enterprise/service/pull/456" target="_blank")

    assert html =~ "Do not link attacker PR hosts."
    assert html =~ "login-github.attacker.tld/foo/bar"
    refute html =~ "https://login-github.attacker.tld/foo/bar/pull/9"
    refute html =~ "https://linear.attacker.tld/a8c/issue/RSM-LIVE-ATTACKER"

    assert html =~ "Do not link non-HTTPS Linear URLs."
    assert html =~ ~s(href="https://github.com/example/other/pull/124" target="_blank")
    refute html =~ "http://linear.app/a8c/issue/RSM-LIVE-SCHEME"
  end

  test "dashboard liveview omits watching PR link when pull request URL is unavailable" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardNoPrOrchestrator)

    snapshot =
      update_in(static_snapshot().watching, fn [watching] ->
        [
          Map.put(watching, :pull_request_url, ""),
          %{watching | issue_id: "issue-watch-nil", identifier: "MT-WATCH-NIL", pull_request_url: nil},
          watching
          |> Map.merge(%{issue_id: "issue-watch-missing", identifier: "MT-WATCH-MISSING"})
          |> Map.delete(:pull_request_url)
        ]
      end)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "MT-WATCH"
    assert html =~ "MT-WATCH-NIL"
    assert html =~ "MT-WATCH-MISSING"
    refute html =~ ">PR</a>"
    refute html =~ ~s(href="" target="_blank")
  end

  test "dashboard liveview tolerates snapshots with partial codex totals" do
    orchestrator_name = Module.concat(__MODULE__, :PartialTotalsDashboardOrchestrator)

    snapshot =
      static_snapshot()
      |> Map.put(:codex_totals, %{input_tokens: 4, output_tokens: 8, total_tokens: 12})

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload["codex_totals"] == %{
             "input_tokens" => 4,
             "cached_input_tokens" => 0,
             "uncached_input_tokens" => 4,
             "output_tokens" => 8,
             "total_tokens" => 12,
             "seconds_running" => 0
           }

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "Runtime"
  end

  test "transcript liveview replays buffered events and appends pubsub events" do
    orchestrator_name = Module.concat(__MODULE__, :TranscriptOrchestrator)

    buffered_agent_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "buffered hello"}
      },
      timestamp: DateTime.utc_now()
    }

    buffered_tool_call_event = %{
      event: :notification,
      payload: %{
        "method" => "item/tool/call",
        "params" => %{
          "name" => "linear_graphql",
          "arguments" => %{"query" => "query Viewer { viewer { id } }"}
        }
      },
      timestamp: DateTime.utc_now()
    }

    buffered_tool_result_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "buffered command output"}
      },
      timestamp: DateTime.utc_now()
    }

    buffered_progress_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "."}
      },
      timestamp: DateTime.utc_now()
    }

    buffered_progress_continuation_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "...."}
      },
      timestamp: DateTime.utc_now()
    }

    snapshot =
      update_in(static_snapshot().running, fn [running] ->
        [
          running
          |> Map.put(:transcript_buffer, [
            buffered_agent_event,
            buffered_tool_call_event,
            buffered_progress_event,
            buffered_progress_continuation_event,
            buffered_tool_result_event
          ])
          |> Map.put(:transcript_buffer_size, 5)
        ]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/repos/default/issues/MT-HTTP/transcript")
    assert html =~ "Live Transcript"
    assert html =~ "MT-HTTP"
    assert html =~ ~s(phx-hook="TranscriptFilter")
    assert html =~ ~s(data-transcript-filter="all")
    assert html =~ ~s(data-transcript-filter="agent-text")
    assert html =~ ~s(data-transcript-filter="tool-call")
    assert html =~ ~s(data-transcript-filter="tool-result")
    assert html =~ ~s(data-transcript-filter="session")
    assert html =~ ~s(data-transcript-filter="error")
    assert html =~ ~s(data-transcript-filter="event")
    assert html =~ ~s(data-transcript-events)
    refute html =~ "phx-click"
    assert html =~ "buffered hello"
    assert html =~ "transcript-event-agent-text"
    assert html =~ "Tool call"
    assert html =~ "linear_graphql"
    assert html =~ "transcript-event-tool-call"
    assert html =~ "Tool result"
    assert html =~ "command output streaming: 5 progress dots"
    assert html =~ "buffered command output"
    assert html =~ "transcript-event-tool-result"

    live_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/requestApproval",
        "params" => %{"msg" => %{"command" => "mix test"}}
      },
      timestamp: DateTime.utc_now()
    }

    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-http", live_event)

    assert_eventually(fn ->
      live_html = render(view)

      live_html =~ "mix test" and live_html =~ "transcript-event-tool-call"
    end)

    live_progress_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "."}
      },
      timestamp: DateTime.utc_now()
    }

    live_progress_continuation_event = %{
      event: :notification,
      payload: %{
        "method" => "item/commandExecution/outputDelta",
        "params" => %{"outputDelta" => "."}
      },
      timestamp: DateTime.utc_now()
    }

    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-http", live_progress_event)
    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-http", live_progress_continuation_event)

    assert_eventually(fn ->
      render(view) =~ "command output streaming: 2 progress dots"
    end)
  end

  test "transcript liveview replays watched issue buffered events" do
    orchestrator_name = Module.concat(__MODULE__, :WatchingTranscriptOrchestrator)

    watched_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "watched hello"}
      },
      timestamp: DateTime.utc_now()
    }

    watched_at = DateTime.utc_now()

    snapshot =
      static_snapshot()
      |> Map.put(:running, [])
      |> update_in([:watching], fn [watching] ->
        [
          watching
          |> Map.put(:session_id, "thread-watch-turn-1")
          |> Map.put(:started_at, DateTime.add(watched_at, -300, :second))
          |> Map.put(:last_event_at, watched_at)
          |> Map.put(:turn_count, 4)
          |> Map.put(:tokens, %{
            input_tokens: 21,
            cached_input_tokens: 5,
            uncached_input_tokens: 16,
            output_tokens: 13,
            total_tokens: 34
          })
          |> Map.put(:transcript_buffer, [watched_event])
          |> Map.put(:transcript_buffer_size, 1)
        ]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-WATCH/transcript")
    assert html =~ "Live Transcript"
    assert html =~ "MT-WATCH"
    assert html =~ "In Review"
    assert html =~ "thread-watch-turn-1"
    assert html =~ "watched hello"
    assert html =~ "34"
    assert html =~ "buffered and live events for this issue"
  end

  test "transcript liveview routes encoded non-default repo keys" do
    orchestrator_name = Module.concat(__MODULE__, :EncodedRepoTranscriptOrchestrator)
    repo_key = "github.com/acme/repo"

    snapshot =
      update_in(static_snapshot().running, fn [running] ->
        [Map.put(running, :repo_key, repo_key)]
      end)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    encoded_repo_key = URI.encode_www_form(repo_key)
    {:ok, view, html} = live(build_conn(), "/repos/#{encoded_repo_key}/issues/MT-HTTP/transcript")

    assert html =~ "Live Transcript"
    assert html =~ "MT-HTTP"

    ignored_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "wrong repo event"}
      },
      timestamp: DateTime.utc_now()
    }

    assert :ok = ObservabilityPubSub.broadcast_transcript_event("default", "issue-http", ignored_event)
    Process.sleep(50)
    refute render(view) =~ "wrong repo event"

    matching_event = %{
      event: :notification,
      payload: %{
        "method" => "item/agentMessage/delta",
        "params" => %{"delta" => "encoded route event"}
      },
      timestamp: DateTime.utc_now()
    }

    assert :ok = ObservabilityPubSub.broadcast_transcript_event(repo_key, "issue-http", matching_event)

    assert_eventually(fn ->
      render(view) =~ "encoded route event"
    end)
  end

  test "transcript liveview renders an error state for missing issues" do
    orchestrator_name = Module.concat(__MODULE__, :MissingTranscriptOrchestrator)

    {:ok, _orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: :unavailable
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos/default/issues/MT-MISSING/transcript")
    assert html =~ "Transcript unavailable"
    assert html =~ "No running issue matched this identifier."
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server starts on an ephemeral port by default" do
    orchestrator_name = Module.concat(__MODULE__, :DefaultPortOrchestrator)

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: static_snapshot()})
    start_supervised!({HttpServer, [orchestrator: orchestrator_name, snapshot_timeout_ms: 50]})

    port = wait_for_bound_port()
    assert is_integer(port)
    assert port > 0
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    orchestrator_opts = [
      name: orchestrator_name,
      owner: self(),
      snapshot: snapshot,
      refresh: refresh
    ]

    start_supervised!({StaticOrchestrator, orchestrator_opts})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200
    assert response.body["counts"] == %{"running" => 1, "watching" => 1, "conflicts" => 0, "retrying" => 1}

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    cross_origin_refresh =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"origin", "https://evil.example"}, {"content-type", "text/plain"}],
        body: ""
      )

    assert cross_origin_refresh.status == 403
    assert cross_origin_refresh.body["error"]["code"] == "forbidden_origin"
    refute_received :request_refresh_called

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"origin", "http://127.0.0.1:#{port}"}, {"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true
    assert_received :request_refresh_called

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp assert_repo_chip(html, repo) do
    assert html =~ repo_chip_pattern(repo)
    assert html =~ ~s(<span class="repo-chip-text">#{repo}</span>)
  end

  defp repo_chip_pattern(repo) do
    escaped_repo = Regex.escape(repo)

    ~r/<span(?=[^>]*class="[^"]*\brepo-chip\b[^"]*")(?=[^>]*title="#{escaped_repo}")(?=[^>]*aria-label="Repository #{escaped_repo}")/
  end

  defp conflict_repo_chip_pattern(repo) do
    escaped_repo = Regex.escape(repo)

    ~r/<span(?=[^>]*class="[^"]*\brepo-chip-conflict\b[^"]*")(?=[^>]*title="#{escaped_repo}")(?=[^>]*aria-label="Repository #{escaped_repo}")/
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          repo_key: "default",
          identifier: "MT-HTTP",
          state: "In Progress",
          url: "https://linear.app/example/issue/MT-HTTP",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      watching: [
        %{
          issue_id: "issue-watch",
          repo_key: "default",
          identifier: "MT-WATCH",
          state: "In Review",
          url: "https://linear.app/example/issue/MT-WATCH",
          pull_request_url: "https://github.com/example/repo/pull/123",
          last_ran_at: DateTime.add(DateTime.utc_now(), -3_600, :second),
          seconds_since_last_run: 3_600
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          repo_key: "default",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      run_history: [
        %{
          run_id: "run-http",
          repo_key: "default",
          issue_id: "issue-http",
          issue_identifier: "MT-HTTP",
          title: "HTTP snapshot",
          state: "In Progress",
          status: "success",
          attempt: 1,
          started_at: DateTime.utc_now(),
          ended_at: DateTime.utc_now(),
          error: nil,
          worker_host: nil,
          workspace_path: nil,
          session_id: "thread-http",
          transcript_path: nil,
          turn_count: 7,
          runtime_seconds: 42,
          tokens: %{input_tokens: 4, output_tokens: 8, total_tokens: 12}
        }
      ],
      codex_totals: %{input_tokens: 4, output_tokens: 8, total_tokens: 12, seconds_running: 42.5},
      budget: %{
        per_issue_limit: 500,
        daily_limit: 1_000,
        daily_used: 400,
        daily_remaining: 600,
        daily_paused: false
      },
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp multi_repo_snapshot do
    now = DateTime.utc_now()

    static_snapshot()
    |> Map.put(:running, [
      %{
        issue_id: "issue-http",
        repo_key: "default",
        identifier: "MT-HTTP",
        state: "In Progress",
        url: "https://linear.app/example/issue/MT-HTTP",
        session_id: "thread-default",
        turn_count: 1,
        codex_app_server_pid: nil,
        last_codex_message: "default update",
        last_codex_timestamp: nil,
        last_codex_event: :notification,
        codex_input_tokens: 1,
        codex_output_tokens: 2,
        codex_total_tokens: 3,
        started_at: now
      },
      %{
        issue_id: "issue-api",
        repo_key: "api",
        identifier: "MT-API",
        state: "In Progress",
        url: "https://linear.app/example/issue/MT-API",
        session_id: "thread-api",
        turn_count: 2,
        codex_app_server_pid: nil,
        last_codex_message: "api update",
        last_codex_timestamp: nil,
        last_codex_event: :notification,
        codex_input_tokens: 5,
        codex_output_tokens: 7,
        codex_total_tokens: 12,
        started_at: now
      }
    ])
    |> Map.put(:watching, [
      %{
        issue_id: "issue-api-watch",
        repo_key: "api",
        identifier: "MT-API-WATCH",
        state: "In Review",
        url: "https://linear.app/example/issue/MT-API-WATCH",
        pull_request_url: nil,
        last_ran_at: DateTime.add(now, -600, :second),
        seconds_since_last_run: 600
      }
    ])
    |> Map.put(:retrying, [
      %{
        issue_id: "issue-web-retry",
        repo_key: "web",
        identifier: "MT-WEB-RETRY",
        attempt: 3,
        due_in_ms: 5_000,
        error: "rate limited"
      }
    ])
    |> Map.put(:conflicts, [
      %{
        issue_id: "issue-conflict",
        identifier: "MT-CONFLICT",
        state: "Conflict",
        linear_state: "Todo",
        url: "https://linear.app/example/issue/MT-CONFLICT",
        repo_keys: ["api", "web"]
      }
    ])
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      restart_workflow_store()
    end
  end

  defp terminate_workflow_store do
    case workflow_store_supervisor() do
      nil ->
        stop_unsupervised_workflow_store()

      supervisor ->
        case Supervisor.terminate_child(supervisor, workflow_store_child_id()) do
          :ok -> :ok
          {:error, :not_found} -> stop_unsupervised_workflow_store()
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp restart_workflow_store do
    case workflow_store_supervisor() do
      nil ->
        case WorkflowStore.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      supervisor ->
        case Supervisor.restart_child(supervisor, workflow_store_child_id()) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp stop_unsupervised_workflow_store do
    if pid = Process.whereis(WorkflowStore) do
      GenServer.stop(pid)
    end

    :ok
  end

  defp workflow_store_supervisor do
    case workflow_store_repo_name() do
      nil -> nil
      repo_name -> SymphonyElixir.Repo.Supervisor.supervisor_name(repo_name)
    end
    |> fallback_workflow_store_supervisor()
  end

  defp workflow_store_child_id do
    {WorkflowStore, workflow_store_repo_name() || supervised_repo_name()}
  end

  defp workflow_store_repo_name do
    ["default", "symphony", Application.get_env(:symphony_elixir, :primary_repo_name)]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(fn repo_name ->
      if Process.whereis(SymphonyElixir.Repo.Registry) do
        repo_name
        |> SymphonyElixir.Repo.Supervisor.supervisor_name()
        |> GenServer.whereis()
        |> is_pid()
      else
        false
      end
    end)
  end

  defp fallback_workflow_store_supervisor(nil) do
    case supervised_repo_child() do
      {_repo_name, repo_pid} -> repo_pid
      nil -> nil
    end
  end

  defp fallback_workflow_store_supervisor(supervisor), do: supervisor

  defp supervised_repo_name do
    case supervised_repo_child() do
      {repo_name, _repo_pid} -> repo_name
      nil -> nil
    end
  end

  defp supervised_repo_child do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        pid
        |> Supervisor.which_children()
        |> Enum.find_value(fn
          {{SymphonyElixir.Repo.Supervisor, repo_name}, repo_pid, :supervisor, _modules}
          when is_pid(repo_pid) ->
            {repo_name, repo_pid}

          _child ->
            nil
        end)

      _pid ->
        nil
    end
  end
end
