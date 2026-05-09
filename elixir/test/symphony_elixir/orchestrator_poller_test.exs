defmodule SymphonyElixir.OrchestratorPollerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator

  test "staggered repo poll cache routes cross-repo duplicates to conflicts before dispatch" do
    repos = [
      %{name: "web", team: "RSM", labels: ["web"]},
      %{name: "api", team: "RSM", labels: ["api"]}
    ]

    issue = %Issue{id: "issue-1", identifier: "RSM-1", title: "Shared", state: "Todo"}

    fetcher = fn
      %{name: "web"} ->
        send(self(), {:polled, "web"})
        {:ok, [issue]}

      %{name: "api"} ->
        send(self(), {:polled, "api"})
        {:ok, [issue]}
    end

    state = %Orchestrator.State{poll_interval_ms: 100}

    assert {:ok, %{dispatchable: [], conflicts: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 0)

    assert_receive {:polled, "web"}
    refute_receive {:polled, "api"}, 10
    assert state.repo_poll_due_at_ms == %{"web" => 100, "api" => 50}
    assert Map.has_key?(state.repo_poll_cache, "web")
    refute Map.has_key?(state.repo_poll_cache, "api")

    assert {:ok, %{dispatchable: [], conflicts: [conflict]}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 50)

    assert_receive {:polled, "api"}
    assert conflict.id == "issue-1"
    assert conflict.repo_key == nil
    assert conflict.conflict_repo_keys == ["api", "web"]
    assert state.conflicts["issue-1"].conflict_repo_keys == ["api", "web"]
  end

  test "warmed stagger cache dispatches unique issues with repo metadata" do
    repos = [
      %{name: "web", team: "RSM", labels: ["web"]},
      %{name: "api", team: "RSM", labels: ["api"]}
    ]

    web_issue = %Issue{id: "issue-web", identifier: "RSM-WEB", title: "Web", state: "Todo"}
    api_issue = %Issue{id: "issue-api", identifier: "RSM-API", title: "API", state: "Todo"}

    fetcher = fn
      %{name: "web"} -> {:ok, [web_issue]}
      %{name: "api"} -> {:ok, [api_issue]}
    end

    state = %Orchestrator.State{poll_interval_ms: 100}

    assert {:ok, %{dispatchable: [], conflicts: []}, state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 0)

    assert {:ok, %{dispatchable: dispatchable, conflicts: []}, _state} =
             Orchestrator.poll_candidate_issue_buckets_for_test(state, repos, fetcher, 50)

    assert Enum.map(dispatchable, &{&1.identifier, &1.repo_key}) == [
             {"RSM-API", "api"},
             {"RSM-WEB", "web"}
           ]
  end
end
