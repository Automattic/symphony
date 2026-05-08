defmodule SymphonyElixir.DispatchStateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DispatchState

  describe "compute/3" do
    test "returns active when nothing is blocking" do
      state = base_state()
      config = base_config()
      env = %{"ANTHROPIC_API_KEY" => "sk-test"}

      assert %{active?: true, blockers: []} = DispatchState.compute(state, config, env)
    end

    test "manual pause blocker carries reason and timestamp" do
      paused_at = ~U[2026-05-08 10:00:00Z]

      state =
        base_state()
        |> Map.put(:pause, %{paused: true, reason: "investigating", paused_at: paused_at})

      result = DispatchState.compute(state, base_config(), full_env())

      assert result.active? == false
      assert [%{kind: :manual, reason: "investigating", since: ^paused_at}] = result.blockers
    end

    test "budget exhaustion blocker includes used/limit/reset" do
      state =
        base_state()
        |> Map.put(:budget_daily_used, 6_000_000)
        |> Map.put(:budget_day_started_on, ~D[2026-05-08])

      result = DispatchState.compute(state, base_config(), full_env())

      assert result.active? == false

      assert [
               %{
                 kind: :budget,
                 used: 6_000_000,
                 limit: 5_000_000,
                 day_started_on: ~D[2026-05-08],
                 resets_on: ~D[2026-05-09]
               }
             ] = result.blockers
    end

    test "workspace_dirty blocker captures repo and dirty summary" do
      state =
        base_state()
        |> Map.put(:workspace_dirty, %{repo: "/path/repo", summary: "M elixir/WORKFLOW.md"})

      result = DispatchState.compute(state, base_config(), full_env())

      assert [%{kind: :workspace_dirty, repo: "/path/repo", dirty_summary: "M elixir/WORKFLOW.md"}] =
               result.blockers
    end

    test "missing api key blocker fires when env var is empty" do
      result = DispatchState.compute(base_state(), base_config(), %{"ANTHROPIC_API_KEY" => ""})

      assert [%{kind: :missing_api_key, provider: :anthropic}] = result.blockers
    end

    test "all blockers stack" do
      state =
        base_state()
        |> Map.put(:pause, %{paused: true, reason: "stop", paused_at: ~U[2026-05-08 10:00:00Z]})
        |> Map.put(:budget_daily_used, 10_000_000)
        |> Map.put(:budget_day_started_on, ~D[2026-05-08])
        |> Map.put(:workspace_dirty, %{repo: "/r", summary: "M f"})

      result = DispatchState.compute(state, base_config(), %{"ANTHROPIC_API_KEY" => ""})

      kinds = Enum.map(result.blockers, & &1.kind)
      assert :manual in kinds
      assert :budget in kinds
      assert :workspace_dirty in kinds
      assert :missing_api_key in kinds
      assert result.active? == false
    end
  end

  defp base_state do
    %{
      pause: %{paused: false, reason: nil, paused_at: nil},
      budget_daily_used: 0,
      budget_day_started_on: ~D[2026-05-08],
      workspace_dirty: nil
    }
  end

  defp base_config, do: %{daily_limit: 5_000_000}

  defp full_env, do: %{"ANTHROPIC_API_KEY" => "sk-test"}
end
