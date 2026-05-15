defmodule SymphonyElixir.DispatchStateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DispatchState

  describe "compute/3" do
    test "returns active when nothing is blocking" do
      state = base_state()
      config = base_config()
      env = %{}

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

    test "workspace dirty state does not block dispatch" do
      state =
        base_state()
        |> Map.put(:workspace_dirty, %{repo: "/path/repo", summary: "M WORKFLOW.md"})

      result = DispatchState.compute(state, base_config(), full_env())

      assert result.active? == true
      assert result.blockers == []
    end

    test "disabled feature providers do not require api keys" do
      result = DispatchState.compute(base_state(), base_config(), %{})

      assert result.active? == true
      assert result.blockers == []
    end

    test "enabled anthropic quality gate requires anthropic api key" do
      config = base_config(%{quality_gate: feature_config(true, :anthropic)})

      result = DispatchState.compute(base_state(), config, %{"ANTHROPIC_API_KEY" => ""})

      assert [%{kind: :missing_api_key, provider: :anthropic}] = result.blockers
    end

    test "enabled openai quality gate requires openai api key" do
      config = base_config(%{quality_gate: feature_config(true, :openai)})

      result = DispatchState.compute(base_state(), config, %{"ANTHROPIC_API_KEY" => "sk-test"})

      assert [%{kind: :missing_api_key, provider: :openai}] = result.blockers
    end

    test "enabled features can require multiple provider api keys" do
      config =
        base_config(%{
          quality_gate: feature_config(true, :anthropic),
          self_review: feature_config(true, :openai)
        })

      result = DispatchState.compute(base_state(), config, %{})

      assert [
               %{kind: :missing_api_key, provider: :anthropic},
               %{kind: :missing_api_key, provider: :openai}
             ] = result.blockers
    end

    test "present provider api keys satisfy enabled feature checks" do
      config =
        base_config(%{
          quality_gate: feature_config(true, :anthropic),
          self_review: feature_config(true, :openai),
          learnings: feature_config(true, :anthropic)
        })

      result = DispatchState.compute(base_state(), config, full_env())

      assert result.active? == true
      assert result.blockers == []
    end

    test "missing api key blockers are de-duped by provider" do
      config =
        base_config(%{
          quality_gate: feature_config(true, "openai"),
          self_review: feature_config(true, :openai),
          learnings: feature_config(true, "openai")
        })

      result = DispatchState.compute(base_state(), config, %{})

      assert [%{kind: :missing_api_key, provider: :openai}] = result.blockers
    end

    test "missing feature sections and unsupported providers do not require api keys" do
      config = %{
        daily_limit: 5_000_000,
        quality_gate: feature_config(true, :unsupported)
      }

      result = DispatchState.compute(base_state(), config, %{})

      assert result.active? == true
      assert result.blockers == []
    end

    test "all blockers stack" do
      state =
        base_state()
        |> Map.put(:pause, %{paused: true, reason: "stop", paused_at: ~U[2026-05-08 10:00:00Z]})
        |> Map.put(:budget_daily_used, 10_000_000)
        |> Map.put(:budget_day_started_on, ~D[2026-05-08])
        |> Map.put(:workspace_dirty, %{repo: "/r", summary: "M f"})

      config = base_config(%{quality_gate: feature_config(true, :anthropic)})

      result = DispatchState.compute(state, config, %{"ANTHROPIC_API_KEY" => ""})

      kinds = Enum.map(result.blockers, & &1.kind)
      assert :manual in kinds
      assert :budget in kinds
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

  defp base_config(overrides \\ %{}) do
    %{
      daily_limit: 5_000_000,
      quality_gate: feature_config(false, :anthropic),
      self_review: feature_config(false, :anthropic),
      learnings: feature_config(false, :anthropic)
    }
    |> Map.merge(overrides)
  end

  defp feature_config(enabled, provider), do: %{enabled: enabled, provider: provider}

  defp full_env, do: %{"ANTHROPIC_API_KEY" => "sk-test", "OPENAI_API_KEY" => "sk-test"}
end
