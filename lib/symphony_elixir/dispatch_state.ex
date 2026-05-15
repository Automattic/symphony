defmodule SymphonyElixir.DispatchState do
  @moduledoc """
  Computes a unified dispatch-state view from orchestrator state, config and env.

  A dispatch is `active?` only when zero operational blockers apply. Blockers
  are tagged maps so callers can render each one with a specific message +
  remediation.
  """

  @type blocker ::
          %{kind: :manual, reason: String.t() | nil, since: DateTime.t() | nil}
          | %{
              kind: :budget,
              used: non_neg_integer(),
              limit: pos_integer(),
              day_started_on: Date.t(),
              resets_on: Date.t()
            }
          | %{kind: :missing_api_key, provider: atom()}

  @type t :: %{active?: boolean(), blockers: [blocker]}

  @spec compute(map(), map(), map()) :: t()
  def compute(state, config, env) do
    blockers =
      []
      |> maybe_manual(state)
      |> maybe_budget(state, config)
      |> maybe_missing_api_key(env)
      |> Enum.reverse()

    %{active?: blockers == [], blockers: blockers}
  end

  defp maybe_manual(blockers, %{pause: %{paused: true} = pause}) do
    [
      %{
        kind: :manual,
        reason: Map.get(pause, :reason),
        since: Map.get(pause, :paused_at)
      }
      | blockers
    ]
  end

  defp maybe_manual(blockers, _state), do: blockers

  defp maybe_budget(blockers, state, %{daily_limit: limit})
       when is_integer(limit) and limit > 0 do
    used = Map.get(state, :budget_daily_used, 0) || 0

    if used >= limit do
      day = Map.get(state, :budget_day_started_on) || Date.utc_today()

      [
        %{
          kind: :budget,
          used: used,
          limit: limit,
          day_started_on: day,
          resets_on: Date.add(day, 1)
        }
        | blockers
      ]
    else
      blockers
    end
  end

  defp maybe_budget(blockers, _state, _config), do: blockers

  defp maybe_missing_api_key(blockers, env) do
    case Map.get(env, "ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" -> blockers
      _ -> [%{kind: :missing_api_key, provider: :anthropic} | blockers]
    end
  end
end
