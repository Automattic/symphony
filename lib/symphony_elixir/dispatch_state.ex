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
          | %{
              kind: :tracker_unavailable,
              tracker: atom(),
              reason: atom(),
              since: DateTime.t(),
              consecutive_failures: non_neg_integer()
            }

  @type t :: %{active?: boolean(), blockers: [blocker]}

  @default_tracker_unavailable_threshold 3
  @api_key_feature_keys [:quality_gate, :self_review, :learnings]
  @provider_env_vars %{
    anthropic: "ANTHROPIC_API_KEY",
    openai: "OPENAI_API_KEY"
  }

  @spec compute(map(), map(), map()) :: t()
  def compute(state, config, env) do
    blockers =
      []
      |> maybe_manual(state)
      |> maybe_budget(state, config)
      |> maybe_missing_api_keys(config, env)
      |> maybe_missing_tracker_api_key(config)
      |> maybe_tracker_unavailable(state, config)
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

  defp maybe_missing_api_keys(blockers, config, env) do
    config
    |> required_api_key_providers()
    |> Enum.reduce(blockers, fn provider, blockers ->
      env_var = Map.fetch!(@provider_env_vars, provider)

      case Map.get(env, env_var) do
        key when is_binary(key) and key != "" -> blockers
        _ -> [%{kind: :missing_api_key, provider: provider} | blockers]
      end
    end)
  end

  defp required_api_key_providers(config) when is_map(config) do
    @api_key_feature_keys
    |> Enum.map(&Map.get(config, &1))
    |> Enum.filter(&feature_enabled?/1)
    |> Enum.map(&feature_provider/1)
    |> Enum.flat_map(&normalize_provider/1)
    |> Enum.uniq()
  end

  defp feature_enabled?(feature) when is_map(feature), do: Map.get(feature, :enabled) == true
  defp feature_enabled?(_feature), do: false

  defp feature_provider(feature) when is_map(feature), do: Map.get(feature, :provider)

  defp normalize_provider(:anthropic), do: [:anthropic]
  defp normalize_provider("anthropic"), do: [:anthropic]
  defp normalize_provider(:openai), do: [:openai]
  defp normalize_provider("openai"), do: [:openai]
  defp normalize_provider(_provider), do: []

  defp maybe_missing_tracker_api_key(blockers, %{tracker_kind: "linear", tracker_api_key_present?: false}),
    do: [%{kind: :missing_api_key, provider: :linear} | blockers]

  defp maybe_missing_tracker_api_key(blockers, _config), do: blockers

  defp maybe_tracker_unavailable(blockers, %{tracker_health: tracker_health}, config)
       when is_map(tracker_health) and is_map(config) do
    consecutive_failures = Map.get(tracker_health, :consecutive_failures, 0)
    since = Map.get(tracker_health, :since)
    threshold = tracker_unavailable_threshold(config)

    if is_integer(consecutive_failures) and consecutive_failures >= threshold and match?(%DateTime{}, since) do
      [
        %{
          kind: :tracker_unavailable,
          tracker: normalize_tracker(Map.get(tracker_health, :tracker)),
          reason: normalize_tracker_unavailable_reason(Map.get(tracker_health, :reason)),
          since: since,
          consecutive_failures: consecutive_failures
        }
        | blockers
      ]
    else
      blockers
    end
  end

  defp maybe_tracker_unavailable(blockers, _state, _config), do: blockers

  defp tracker_unavailable_threshold(%{tracker_unavailable_threshold: threshold})
       when is_integer(threshold) and threshold > 0 do
    threshold
  end

  defp tracker_unavailable_threshold(_config), do: @default_tracker_unavailable_threshold

  defp normalize_tracker(:linear), do: :linear
  defp normalize_tracker("linear"), do: :linear
  defp normalize_tracker(:memory), do: :memory
  defp normalize_tracker("memory"), do: :memory
  defp normalize_tracker(tracker) when is_atom(tracker), do: tracker
  defp normalize_tracker(_tracker), do: :unknown

  defp normalize_tracker_unavailable_reason(:missing_linear_api_token), do: :missing_linear_api_token
  defp normalize_tracker_unavailable_reason(:linear_api_request), do: :linear_api_request
  defp normalize_tracker_unavailable_reason({:linear_api_request, _reason}), do: :linear_api_request
  defp normalize_tracker_unavailable_reason(_reason), do: :unknown
end
