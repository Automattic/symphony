defmodule SymphonyElixir.QualityGateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.QualityGate, as: QualityGateConfig
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QualityGate

  defmodule StubProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(issue, _settings) do
      results = Process.get(:quality_gate_stub_results, %{})

      case Map.get(results, issue.id) do
        nil -> {:ok, %{score: 8, reason: "default ok"}}
        result -> result
      end
    end
  end

  defmodule ErroringProvider do
    @behaviour SymphonyElixir.QualityGate.Provider

    @impl true
    def score(_issue, _settings), do: {:error, :stub_boom}
  end

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")
    System.put_env("OPENAI_API_KEY", "test-openai-key")

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
    end)

    :ok
  end

  describe "evaluate/4 disabled" do
    test "returns all issues unchanged when config is disabled" do
      issues = [issue("ID-1"), issue("ID-2")]
      config = %QualityGateConfig{enabled: false, min_score: 6}

      assert %{passed: ^issues, skipped: [], cache: cache} =
               QualityGate.evaluate(issues, config, %{})

      assert cache == %{}
    end

    test "returns all issues unchanged when config is nil" do
      issues = [issue("ID-1")]

      assert %{passed: ^issues, skipped: [], cache: %{}} =
               QualityGate.evaluate(issues, nil, %{})
    end
  end

  describe "evaluate/4 enabled" do
    test "passes issues that meet the threshold and skips those below" do
      issues = [issue("ID-1"), issue("ID-2")]
      config = config_enabled(min_score: 6)

      Process.put(:quality_gate_stub_results, %{
        "ID-1" => {:ok, %{score: 9, reason: "clear scope"}},
        "ID-2" => {:ok, %{score: 3, reason: "vague"}}
      })

      result =
        QualityGate.evaluate(issues, config, %{},
          provider_module: StubProvider,
          now: DateTime.utc_now()
        )

      assert [%Issue{id: "ID-1"}] = result.passed
      assert [%{issue_id: "ID-2", score: 3, reason: "vague", comment_posted?: false}] = result.skipped

      assert %{passed?: true, score: 9} = Map.get(result.cache, "ID-1")
      assert %{passed?: false, score: 3, comment_posted?: false} = Map.get(result.cache, "ID-2")
    end

    test "treats min_score as inclusive (score == threshold passes)" do
      config = config_enabled(min_score: 6)
      Process.put(:quality_gate_stub_results, %{"ID-X" => {:ok, %{score: 6, reason: "exactly"}}})

      result = QualityGate.evaluate([issue("ID-X")], config, %{}, provider_module: StubProvider)

      assert [%Issue{id: "ID-X"}] = result.passed
      assert result.skipped == []
    end

    test "uses cache when issue updated_at has not changed" do
      config = config_enabled(min_score: 6)
      updated_at = ~U[2026-05-05 03:00:00Z]
      cached_issue = issue("ID-1", updated_at: updated_at)

      cache = %{
        "ID-1" => %{
          updated_at: updated_at,
          score: 9,
          reason: "cached",
          passed?: true,
          comment_posted?: false,
          identifier: "RSM-1",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/RSM-1",
          scored_at: ~U[2026-05-05 02:00:00Z]
        }
      }

      Process.put(:quality_gate_stub_results, %{
        "ID-1" => {:ok, %{score: 1, reason: "should not be called"}}
      })

      result = QualityGate.evaluate([cached_issue], config, cache, provider_module: StubProvider)

      assert [%Issue{id: "ID-1"}] = result.passed
      assert Map.get(result.cache, "ID-1").reason == "cached"
    end

    test "re-evaluates when updated_at changes (cache invalidated)" do
      config = config_enabled(min_score: 6)
      stale_at = ~U[2026-05-05 03:00:00Z]
      fresh_at = ~U[2026-05-05 04:00:00Z]
      fresh_issue = issue("ID-1", updated_at: fresh_at)

      cache = %{
        "ID-1" => %{
          updated_at: stale_at,
          score: 9,
          reason: "stale",
          passed?: true,
          comment_posted?: true,
          identifier: "RSM-1",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/RSM-1",
          scored_at: stale_at
        }
      }

      Process.put(:quality_gate_stub_results, %{"ID-1" => {:ok, %{score: 4, reason: "rescored"}}})

      result = QualityGate.evaluate([fresh_issue], config, cache, provider_module: StubProvider)

      assert result.passed == []
      assert [%{score: 4, reason: "rescored", comment_posted?: false}] = result.skipped
      assert %{updated_at: ^fresh_at, comment_posted?: false} = Map.get(result.cache, "ID-1")
    end

    test "reuses prior skip decision and preserves comment_posted? when cached" do
      config = config_enabled(min_score: 6)
      updated_at = ~U[2026-05-05 03:00:00Z]
      cached_issue = issue("ID-1", updated_at: updated_at)

      cache = %{
        "ID-1" => %{
          updated_at: updated_at,
          score: 3,
          reason: "vague",
          passed?: false,
          comment_posted?: true,
          identifier: "RSM-1",
          title: "Title",
          state: "Todo",
          url: "https://linear.app/x/RSM-1",
          scored_at: updated_at
        }
      }

      result = QualityGate.evaluate([cached_issue], config, cache, provider_module: StubProvider)

      assert result.passed == []
      assert [%{comment_posted?: true, score: 3}] = result.skipped
    end

    test "on_error: pass lets the issue through when the LLM call fails" do
      config = config_enabled(min_score: 6, on_error: "pass")
      issues = [issue("ID-FAIL")]

      result = QualityGate.evaluate(issues, config, %{}, provider_module: ErroringProvider)

      assert [%Issue{id: "ID-FAIL"}] = result.passed
      assert result.skipped == []
      # Cache is not updated on failure
      assert result.cache == %{}
    end

    test "on_error: skip removes the issue and produces an error skip entry" do
      config = config_enabled(min_score: 6, on_error: "skip")
      issues = [issue("ID-FAIL")]

      result = QualityGate.evaluate(issues, config, %{}, provider_module: ErroringProvider)

      assert result.passed == []
      assert [%{issue_id: "ID-FAIL", error: :stub_boom, reason: reason}] = result.skipped
      assert reason =~ "LLM call failed"
      # Cache is not updated on failure (so we retry next cycle)
      assert result.cache == %{}
    end

    test "missing API key behaves like an LLM failure under on_error" do
      System.delete_env("ANTHROPIC_API_KEY")
      config = config_enabled(min_score: 6, on_error: "skip")

      result = QualityGate.evaluate([issue("ID-1")], config, %{}, provider_module: StubProvider)

      assert [%{error: :missing_anthropic_api_key}] = result.skipped
      assert result.cache == %{}
    end
  end

  describe "mark_comment_posted/2" do
    test "flips comment_posted? to true for the matching cache entry" do
      cache = %{
        "ID-1" => %{
          updated_at: ~U[2026-05-05 03:00:00Z],
          score: 3,
          reason: "vague",
          passed?: false,
          comment_posted?: false,
          identifier: nil,
          title: nil,
          state: nil,
          url: nil,
          scored_at: ~U[2026-05-05 03:00:00Z]
        }
      }

      updated = QualityGate.mark_comment_posted(cache, %{issue_id: "ID-1"})
      assert Map.get(updated, "ID-1").comment_posted?
    end

    test "is a no-op when the cache has no entry for the skip" do
      assert QualityGate.mark_comment_posted(%{}, %{issue_id: "ID-MISSING"}) == %{}
    end
  end

  describe "skip_comment_body/2" do
    test "describes the score and threshold for score-based skips" do
      config = config_enabled(min_score: 6)
      entry = %{score: 3, reason: "vague description"}

      body = QualityGate.skip_comment_body(entry, config)

      assert body =~ "score 3"
      assert body =~ "threshold 6"
      assert body =~ "vague description"
      assert body =~ "edit the description"
    end

    test "explains LLM failures for error-based skips" do
      config = config_enabled(min_score: 6)
      entry = %{reason: "LLM call failed: :stub_boom"}

      body = QualityGate.skip_comment_body(entry, config)

      assert body =~ "LLM call failed"
      assert body =~ "threshold 6"
    end
  end

  describe "skipped_from_cache/1" do
    test "returns only skipped entries, sorted by most-recently scored" do
      cache = %{
        "ID-PASS" => %{
          updated_at: ~U[2026-05-05 03:00:00Z],
          score: 9,
          reason: "ok",
          passed?: true,
          comment_posted?: false,
          identifier: "RSM-PASS",
          title: "Pass",
          state: "Todo",
          url: nil,
          scored_at: ~U[2026-05-05 03:00:00Z]
        },
        "ID-OLD" => %{
          updated_at: ~U[2026-05-05 02:00:00Z],
          score: 3,
          reason: "vague",
          passed?: false,
          comment_posted?: true,
          identifier: "RSM-OLD",
          title: "Old",
          state: "Todo",
          url: nil,
          scored_at: ~U[2026-05-05 01:00:00Z]
        },
        "ID-NEW" => %{
          updated_at: ~U[2026-05-05 03:00:00Z],
          score: 4,
          reason: "broad",
          passed?: false,
          comment_posted?: false,
          identifier: "RSM-NEW",
          title: "New",
          state: "Todo",
          url: nil,
          scored_at: ~U[2026-05-05 03:30:00Z]
        }
      }

      assert [
               %{issue_id: "ID-NEW", score: 4},
               %{issue_id: "ID-OLD", score: 3}
             ] = QualityGate.skipped_from_cache(cache)
    end
  end

  describe "retain_active_issues/2" do
    test "drops cache entries whose issue ids no longer appear" do
      cache = %{
        "ID-KEEP" => %{passed?: false},
        "ID-DROP" => %{passed?: true}
      }

      kept = QualityGate.retain_active_issues(cache, [issue("ID-KEEP")])

      assert Map.has_key?(kept, "ID-KEEP")
      refute Map.has_key?(kept, "ID-DROP")
    end

    test "ignores non-issue entries in the active list" do
      cache = %{"ID-KEEP" => %{passed?: false}}

      assert QualityGate.retain_active_issues(cache, [%{not_an_issue: true}]) == %{}
    end
  end

  describe "provider_settings/1" do
    test "resolves the OpenAI api key from the environment" do
      config = config_enabled(provider: "openai", model: "gpt-5")

      assert {:ok, %{provider: "openai", model: "gpt-5", api_key: "test-openai-key"}} =
               QualityGate.provider_settings(config)
    end

    test "errors when the OpenAI api key is missing" do
      System.delete_env("OPENAI_API_KEY")
      config = config_enabled(provider: "openai", model: "gpt-5")

      assert {:error, :missing_openai_api_key} = QualityGate.provider_settings(config)
    end

    test "errors for unsupported provider strings" do
      config = %SymphonyElixir.Config.Schema.QualityGate{
        enabled: true,
        provider: "huggingface",
        model: "any",
        min_score: 6,
        on_error: "pass"
      }

      assert {:error, {:unsupported_provider, "huggingface"}} =
               QualityGate.provider_settings(config)
    end

    test "errors when the schema struct lacks a provider/model" do
      assert {:error, :missing_provider_settings} =
               QualityGate.provider_settings(%SymphonyElixir.Config.Schema.QualityGate{})
    end
  end

  describe "evaluate/4 falls back to defaults" do
    test "passes malformed issues through with a warning" do
      config = config_enabled(min_score: 6)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result = QualityGate.evaluate([%{not_a_struct: true}], config, %{}, provider_module: StubProvider)
          send(self(), {:result, result})
        end)

      assert_received {:result, %{passed: [_], skipped: []}}
      assert log =~ "QualityGate received malformed issue"
    end

    test "uses the default provider module when none is overridden" do
      config = config_enabled(min_score: 6, provider: "openai", model: "gpt-5")

      Application.put_env(:symphony_elixir, :quality_gate_openai_module, StubProvider)
      on_exit(fn -> Application.delete_env(:symphony_elixir, :quality_gate_openai_module) end)

      Process.put(:quality_gate_stub_results, %{"ID-OPENAI" => {:ok, %{score: 8, reason: "ok"}}})

      result = QualityGate.evaluate([issue("ID-OPENAI")], config, %{})

      assert [%Issue{id: "ID-OPENAI"}] = result.passed
    end
  end

  defp config_enabled(opts) do
    %QualityGateConfig{
      enabled: true,
      provider: Keyword.get(opts, :provider, "anthropic"),
      model: Keyword.get(opts, :model, "claude-haiku-4-5-20251001"),
      min_score: Keyword.get(opts, :min_score, 6),
      on_error: Keyword.get(opts, :on_error, "pass")
    }
  end

  defp issue(id, opts \\ []) do
    %Issue{
      id: id,
      identifier: Keyword.get(opts, :identifier, "RSM-#{id}"),
      title: Keyword.get(opts, :title, "Title #{id}"),
      description: Keyword.get(opts, :description, "Some description"),
      state: Keyword.get(opts, :state, "Todo"),
      url: Keyword.get(opts, :url, "https://linear.app/x/#{id}"),
      labels: Keyword.get(opts, :labels, []),
      updated_at: Keyword.get(opts, :updated_at, ~U[2026-05-05 03:00:00Z])
    }
  end
end
