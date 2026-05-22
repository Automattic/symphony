defmodule SymphonyElixir.AgentTelemetry do
  @moduledoc false

  @type token_key :: :uncached_input | :cached_input | :cache_creation_input | :output | :total

  @spec extract_token_usage(term()) :: map()
  def extract_token_usage(update) when is_map(update) do
    payloads = [
      Map.get(update, :usage),
      Map.get(update, "usage"),
      Map.get(update, :usage),
      Map.get(update, :payload),
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  def extract_token_usage(_update), do: %{}

  @spec extract_rate_limits(term()) :: map() | nil
  def extract_rate_limits(update) when is_map(update) do
    rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(Map.get(update, :payload)) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  def extract_rate_limits(_update), do: nil

  @spec absolute_token_usage_from_payload(term()) :: map() | nil
  def absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  def absolute_token_usage_from_payload(_payload), do: nil

  @spec turn_completed_usage_from_payload(term()) :: map() | nil
  def turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed, "token_count", :token_count] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  def turn_completed_usage_from_payload(_payload), do: nil

  @spec rate_limits_from_payload(term()) :: map() | nil
  def rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  def rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  def rate_limits_from_payload(_payload), do: nil

  @spec get_token_usage(term(), token_key()) :: non_neg_integer() | nil
  def get_token_usage(usage, :uncached_input) do
    explicit =
      payload_get(usage, [
        "uncached_input_tokens",
        :uncached_input_tokens,
        "uncachedInputTokens",
        :uncachedInputTokens
      ])

    if is_integer(explicit) do
      explicit
    else
      input =
        payload_get(usage, [
          "input_tokens",
          "prompt_tokens",
          :input_tokens,
          :prompt_tokens,
          :input,
          "promptTokens",
          :promptTokens,
          "inputTokens",
          :inputTokens
        ])

      codex_cached =
        payload_get(usage, [
          "cached_input_tokens",
          :cached_input_tokens,
          "cachedInputTokens",
          :cachedInputTokens
        ])

      cond do
        is_integer(input) and anthropic_cache_usage?(usage) -> input
        is_integer(input) and is_integer(codex_cached) -> max(input - codex_cached, 0)
        is_integer(input) -> input
        true -> nil
      end
    end
  end

  def get_token_usage(usage, :cached_input),
    do:
      payload_get(usage, [
        "cached_input_tokens",
        :cached_input_tokens,
        "cachedInputTokens",
        :cachedInputTokens,
        "cache_read_input_tokens",
        :cache_read_input_tokens,
        "cacheReadInputTokens",
        :cacheReadInputTokens
      ])

  def get_token_usage(usage, :cache_creation_input),
    do:
      payload_get(usage, [
        "cache_creation_input_tokens",
        :cache_creation_input_tokens,
        "cacheCreationInputTokens",
        :cacheCreationInputTokens
      ])

  def get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  def get_token_usage(usage, :total) do
    explicit =
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

    if is_integer(explicit) do
      explicit
    else
      [
        get_token_usage(usage, :uncached_input),
        get_token_usage(usage, :cached_input),
        get_token_usage(usage, :cache_creation_input),
        get_token_usage(usage, :output)
      ]
      |> Enum.filter(&is_integer/1)
      |> case do
        [] -> nil
        values -> Enum.sum(values)
      end
    end
  end

  defp rate_limit_payloads(payload) when is_map(payload) do
    payload
    |> Map.values()
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :uncached_input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :uncachedInputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      :cached_input_tokens,
      :cachedInputTokens,
      :cache_read_input_tokens,
      :cache_creation_input_tokens,
      :cacheCreationInputTokens,
      "input_tokens",
      "uncached_input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "uncachedInputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens",
      "cached_input_tokens",
      "cachedInputTokens",
      "cache_read_input_tokens",
      "cache_creation_input_tokens",
      "cacheCreationInputTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp anthropic_cache_usage?(usage) do
    is_integer(
      payload_get(usage, [
        "cache_read_input_tokens",
        :cache_read_input_tokens,
        "cacheReadInputTokens",
        :cacheReadInputTokens,
        "cache_creation_input_tokens",
        :cache_creation_input_tokens,
        "cacheCreationInputTokens",
        :cacheCreationInputTokens
      ])
    )
  end

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
