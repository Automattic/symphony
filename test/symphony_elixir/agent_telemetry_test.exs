defmodule SymphonyElixir.AgentTelemetryTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentTelemetry

  test "extracts Claude Code token usage and preserves Anthropic cache semantics" do
    usage = %{
      input_tokens: "800",
      cache_read_input_tokens: "9200",
      cache_creation_input_tokens: "400",
      output_tokens: "600",
      total_tokens: "11000"
    }

    update = %{
      event: :token_count,
      usage: usage,
      payload: %{method: "token_count", usage: usage}
    }

    assert AgentTelemetry.extract_token_usage(update) == usage
    assert AgentTelemetry.turn_completed_usage_from_payload(update.payload) == usage
    assert AgentTelemetry.get_token_usage(usage, :uncached_input) == 800
    assert AgentTelemetry.get_token_usage(usage, :cached_input) == 9200
    assert AgentTelemetry.get_token_usage(usage, :cache_creation_input) == 400
    assert AgentTelemetry.get_token_usage(usage, :output) == 600
    assert AgentTelemetry.get_token_usage(usage, :total) == 11_000
  end

  test "extracts Codex absolute token usage and rate limits from nested payloads" do
    usage = %{
      "input_tokens" => 12_000,
      "cached_input_tokens" => 10_000,
      "output_tokens" => 500,
      "total_tokens" => 12_500
    }

    rate_limits = %{
      "limit_id" => "codex",
      "primary" => %{"remaining" => 90, "limit" => 100},
      "secondary" => nil,
      "credits" => %{"has_credits" => false, "unlimited" => false, "balance" => nil}
    }

    update = %{
      payload: %{
        "method" => "codex/event/token_count",
        "params" => %{
          "msg" => %{
            "payload" => %{
              "info" => %{"total_token_usage" => usage},
              "rate_limits" => rate_limits
            }
          }
        }
      }
    }

    assert AgentTelemetry.extract_token_usage(update) == usage
    assert AgentTelemetry.absolute_token_usage_from_payload(update.payload) == usage
    assert AgentTelemetry.extract_rate_limits(update) == rate_limits
    assert AgentTelemetry.rate_limits_from_payload(update.payload) == rate_limits
    assert AgentTelemetry.get_token_usage(usage, :uncached_input) == 2_000
    assert AgentTelemetry.get_token_usage(usage, :cached_input) == 10_000
    assert AgentTelemetry.get_token_usage(usage, :output) == 500
    assert AgentTelemetry.get_token_usage(usage, :total) == 12_500
  end

  test "extracts alternate token usage payload shapes" do
    usage = %{"input_tokens" => 10, "output_tokens" => 5}

    assert AgentTelemetry.turn_completed_usage_from_payload(%{
             "method" => "turn/completed",
             "usage" => usage
           }) == usage

    assert AgentTelemetry.turn_completed_usage_from_payload(%{
             "method" => "turn/completed",
             "params" => %{"usage" => usage}
           }) == usage

    assert AgentTelemetry.turn_completed_usage_from_payload(%{
             method: :turn_completed,
             params: %{usage: usage}
           }) == usage
  end

  test "extracts alternate rate-limit payload shapes" do
    rate_limits = %{
      limit_id: "codex",
      primary: %{remaining: 1, limit: 2}
    }

    assert AgentTelemetry.extract_rate_limits(%{rate_limits: rate_limits}) == rate_limits

    assert AgentTelemetry.extract_rate_limits(%{limit_id: "codex", primary: %{remaining: 1}}) ==
             %{limit_id: "codex", primary: %{remaining: 1}}

    assert AgentTelemetry.rate_limits_from_payload(rate_limits) == rate_limits
    assert AgentTelemetry.rate_limits_from_payload([%{}, %{rate_limits: rate_limits}]) == rate_limits
  end

  test "rejects malformed payloads without token or rate-limit maps" do
    invalid_usage_payload = %{method: "token_count", usage: %{"output_tokens" => "nope"}}

    assert AgentTelemetry.extract_token_usage(:not_a_map) == %{}
    assert AgentTelemetry.extract_token_usage(%{payload: invalid_usage_payload}) == %{}
    assert AgentTelemetry.absolute_token_usage_from_payload(nil) == nil
    assert AgentTelemetry.turn_completed_usage_from_payload(invalid_usage_payload) == nil
    assert AgentTelemetry.rate_limits_from_payload(%{"limit_id" => "missing-buckets"}) == nil
    assert AgentTelemetry.extract_rate_limits(:not_a_map) == nil
  end

  test "coerces integer-like token values using existing edge behavior" do
    assert AgentTelemetry.get_token_usage(%{"total_tokens" => " 42left "}, :total) == 42
    assert AgentTelemetry.get_token_usage(%{"uncached_input_tokens" => "7"}, :uncached_input) == 7
    assert AgentTelemetry.get_token_usage(%{"output_tokens" => "0"}, :output) == 0
    assert AgentTelemetry.get_token_usage(%{"total_tokens" => "-1"}, :total) == nil
    assert AgentTelemetry.get_token_usage(%{"total_tokens" => 3.14}, :total) == nil

    usage_without_total = %{
      "input_tokens" => "9",
      "cached_input_tokens" => "4",
      "output_tokens" => "2"
    }

    assert AgentTelemetry.get_token_usage(usage_without_total, :uncached_input) == 5
    assert AgentTelemetry.get_token_usage(usage_without_total, :total) == 11
  end
end
