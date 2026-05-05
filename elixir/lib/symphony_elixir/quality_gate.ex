defmodule SymphonyElixir.QualityGate do
  @moduledoc """
  Issue-scoping quality gate. Runs between `Tracker.fetch_candidate_issues/0`
  and the orchestrator's dispatch loop, asking an LLM to score each candidate
  for agent-readiness on a 1–10 scale.

  Issues that score below the configured `min_score` are filtered out and
  surfaced to the orchestrator as `skip_entry/0` records, so the dashboard
  can render them and the caller can post a Linear comment explaining why
  the issue was not queued.

  ### Caching

  Scores are cached in-memory keyed by `{issue.id, issue.updated_at}`. The
  cache value also remembers whether a Linear comment has already been
  posted for the current `updated_at`, so subsequent poll cycles do not
  re-evaluate or re-comment unchanged issues. Editing the issue description
  bumps `updated_at` in Linear, which invalidates the cache and lets the
  gate re-score and (if still below threshold) post a fresh comment.

  ### Errors

  When the LLM call fails, the cache is *not* updated (so the call is
  retried next poll), and behavior follows `on_error`:

    * `"pass"` (default) — the issue is allowed through; a warning is logged.
    * `"skip"` — the issue is skipped for the cycle; a warning is logged.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @anthropic_provider "anthropic"
  @openai_provider "openai"

  @type cache :: %{optional(String.t()) => cache_entry()}
  @type cache_entry :: %{
          required(:updated_at) => DateTime.t() | nil,
          required(:score) => integer() | nil,
          required(:reason) => String.t() | nil,
          required(:passed?) => boolean(),
          required(:comment_posted?) => boolean(),
          required(:identifier) => String.t() | nil,
          required(:title) => String.t() | nil,
          required(:state) => String.t() | nil,
          required(:url) => String.t() | nil,
          required(:scored_at) => DateTime.t()
        }

  @type scored_skip :: %{
          required(:kind) => :scored,
          required(:issue) => Issue.t(),
          required(:issue_id) => String.t(),
          required(:identifier) => String.t() | nil,
          required(:url) => String.t() | nil,
          required(:updated_at) => DateTime.t() | nil,
          required(:reason) => String.t(),
          required(:score) => integer(),
          required(:comment_posted?) => boolean()
        }

  @type error_skip :: %{
          required(:kind) => :error,
          required(:issue) => Issue.t(),
          required(:issue_id) => String.t(),
          required(:identifier) => String.t() | nil,
          required(:url) => String.t() | nil,
          required(:updated_at) => DateTime.t() | nil,
          required(:reason) => String.t(),
          required(:error) => term(),
          required(:comment_posted?) => boolean()
        }

  @type skip_entry :: scored_skip() | error_skip()

  @type result :: %{passed: [Issue.t()], skipped: [skip_entry()], cache: cache()}

  @doc """
  Filter `issues` through the quality gate. Returns:

      %{passed: [Issue.t()], skipped: [skip_entry()], cache: cache()}

  When the gate is disabled (`config.enabled == false`), every issue passes
  unchanged and the cache is returned untouched.

  Options:

    * `:now` — `%DateTime{}` used to stamp newly-scored cache entries;
      defaults to `DateTime.utc_now/0`.
    * `:provider_module` — override the provider implementation. Used by
      tests to inject a stub.
  """
  def evaluate(issues, config, cache \\ %{}, opts \\ [])

  @spec evaluate([Issue.t()], Schema.QualityGate.t() | nil, cache(), keyword()) :: result()
  def evaluate(issues, %Schema.QualityGate{enabled: true} = config, cache, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    provider_override = Keyword.get(opts, :provider_module)

    {passed_rev, skipped_rev, new_cache} =
      Enum.reduce(issues, {[], [], cache}, fn issue, {passed, skipped, cache_acc} ->
        case evaluate_issue(issue, config, cache_acc, now, provider_override) do
          {:pass, cache_next} ->
            {[issue | passed], skipped, cache_next}

          {:skip, entry, cache_next} ->
            {passed, [entry | skipped], cache_next}
        end
      end)

    %{passed: Enum.reverse(passed_rev), skipped: Enum.reverse(skipped_rev), cache: new_cache}
  end

  def evaluate(issues, _config, cache, _opts) do
    %{passed: issues, skipped: [], cache: cache}
  end

  @doc """
  Drop cache entries for issues that no longer appear in `issues`. This keeps
  the skipped section bounded as Linear filters change (e.g., issues moved
  to terminal state, reassigned).
  """
  @spec retain_active_issues(cache(), [Issue.t()]) :: cache()
  def retain_active_issues(cache, issues) when is_map(cache) and is_list(issues) do
    active_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: id} when is_binary(id) -> [id]
        _ -> []
      end)
      |> MapSet.new()

    cache
    |> Enum.filter(fn {issue_id, _entry} -> MapSet.member?(active_ids, issue_id) end)
    |> Map.new()
  end

  @doc """
  List cached entries currently classified as skipped, formatted for the
  dashboard's Skipped section. Sorted by most-recently scored first.
  """
  @spec skipped_from_cache(cache()) :: [map()]
  def skipped_from_cache(cache) when is_map(cache) do
    cache
    |> Enum.flat_map(fn
      {issue_id, %{passed?: false} = entry} ->
        [
          %{
            kind: :scored,
            issue_id: issue_id,
            identifier: entry.identifier,
            title: entry.title,
            state: entry.state,
            url: entry.url,
            score: entry.score,
            reason: entry.reason,
            scored_at: entry.scored_at
          }
        ]

      _ ->
        []
    end)
    |> Enum.sort_by(& &1.scored_at, {:desc, DateTime})
  end

  @doc """
  Mark a skip entry as having had its Linear comment posted in `cache`.

  Used by the orchestrator after it successfully creates the comment, so
  subsequent poll cycles see `comment_posted?: true` for the same
  `updated_at` and do not double-post.
  """
  @spec mark_comment_posted(cache(), skip_entry()) :: cache()
  def mark_comment_posted(cache, %{issue_id: issue_id}) when is_binary(issue_id) do
    case Map.fetch(cache, issue_id) do
      {:ok, entry} -> Map.put(cache, issue_id, %{entry | comment_posted?: true})
      :error -> cache
    end
  end

  @doc """
  Resolve provider credentials and runtime settings for `config`. Reads the
  API key from the environment so secrets stay out of `WORKFLOW.md`.
  """
  @spec provider_settings(Schema.QualityGate.t()) ::
          {:ok, SymphonyElixir.QualityGate.Provider.settings()} | {:error, term()}
  def provider_settings(%Schema.QualityGate{provider: provider, model: model})
      when is_binary(provider) and is_binary(model) do
    case api_key_for(provider) do
      {:ok, api_key} -> {:ok, %{provider: provider, model: model, api_key: api_key}}
      {:error, reason} -> {:error, reason}
    end
  end

  def provider_settings(_config), do: {:error, :missing_provider_settings}

  @doc """
  Format the body of the Linear comment posted when an issue is skipped.
  """
  @spec skip_comment_body(skip_entry(), Schema.QualityGate.t()) :: String.t()
  def skip_comment_body(%{kind: :scored, score: score, reason: reason}, %Schema.QualityGate{min_score: min_score})
      when is_integer(score) do
    """
    Symphony quality gate: skipped (score #{score} < threshold #{min_score}).

    Reason: #{reason}

    To re-queue this issue, edit the description with clearer acceptance
    criteria, tighter scope, or fewer ambiguous markers (e.g. "investigate",
    "explore"). Symphony will silently re-evaluate it on the next poll.
    """
  end

  def skip_comment_body(%{kind: :error, reason: reason}, %Schema.QualityGate{min_score: min_score}) do
    """
    Symphony quality gate: skipped (LLM call failed; threshold #{min_score}).

    Reason: #{reason}

    To re-queue this issue, edit the description and Symphony will retry
    scoring on the next poll.
    """
  end

  defp evaluate_issue(%Issue{id: issue_id, updated_at: updated_at} = issue, config, cache, now, provider_override)
       when is_binary(issue_id) do
    case Map.get(cache, issue_id) do
      %{updated_at: ^updated_at, passed?: true} ->
        {:pass, cache}

      %{updated_at: ^updated_at, passed?: false} = entry ->
        {:skip, build_skip_entry(issue, entry), cache}

      _stale_or_missing ->
        score_and_record(issue, config, cache, now, provider_override)
    end
  end

  defp evaluate_issue(issue, _config, cache, _now, _provider_override) do
    Logger.warning("QualityGate received malformed issue=#{inspect(issue)}; passing through")
    {:pass, cache}
  end

  defp score_and_record(%Issue{} = issue, config, cache, now, provider_override) do
    case provider_settings(config) do
      {:ok, settings} ->
        provider = provider_override || provider_module(settings.provider)
        invoke_provider(issue, config, cache, provider, settings, now)

      {:error, reason} ->
        handle_provider_error(issue, config, cache, reason)
    end
  end

  defp invoke_provider(issue, config, cache, provider_module, settings, now) do
    case provider_module.score(issue, settings) do
      {:ok, %{score: score, reason: reason}} when score >= config.min_score ->
        Logger.info("QualityGate passed issue=#{issue.identifier || issue.id} score=#{score} threshold=#{config.min_score}")

        cache_next = put_cache(cache, issue, score, reason, true, now)
        {:pass, cache_next}

      {:ok, %{score: score, reason: reason}} ->
        Logger.info("QualityGate skipped issue=#{issue.identifier || issue.id} score=#{score} threshold=#{config.min_score} reason=#{inspect(reason)}")

        cache_next = put_cache(cache, issue, score, reason, false, now)
        entry = build_skip_entry(issue, Map.get(cache_next, issue.id))
        {:skip, entry, cache_next}

      {:error, reason} ->
        handle_provider_error(issue, config, cache, reason)
    end
  end

  defp handle_provider_error(%Issue{} = issue, %Schema.QualityGate{on_error: "skip"}, cache, reason) do
    Logger.warning("QualityGate LLM call failed; on_error=skip issue=#{issue.identifier || issue.id} reason=#{inspect(reason)}")

    {:skip, build_error_skip_entry(issue, reason), cache}
  end

  defp handle_provider_error(%Issue{} = issue, _config, cache, reason) do
    Logger.warning("QualityGate LLM call failed; on_error=pass issue=#{issue.identifier || issue.id} reason=#{inspect(reason)}")

    {:pass, cache}
  end

  defp put_cache(cache, %Issue{} = issue, score, reason, passed?, now) do
    Map.put(cache, issue.id, %{
      updated_at: issue.updated_at,
      score: score,
      reason: reason,
      passed?: passed?,
      comment_posted?: false,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      url: issue.url,
      scored_at: now
    })
  end

  defp build_skip_entry(%Issue{} = issue, %{score: score, reason: reason} = entry) do
    %{
      kind: :scored,
      issue: issue,
      issue_id: issue.id,
      identifier: issue.identifier,
      url: issue.url,
      updated_at: issue.updated_at,
      score: score,
      reason: reason,
      comment_posted?: Map.get(entry, :comment_posted?, false)
    }
  end

  defp build_error_skip_entry(%Issue{} = issue, error) do
    %{
      kind: :error,
      issue: issue,
      issue_id: issue.id,
      identifier: issue.identifier,
      url: issue.url,
      updated_at: issue.updated_at,
      reason: "LLM call failed: #{inspect(error)}",
      error: error,
      comment_posted?: false
    }
  end

  defp api_key_for(@anthropic_provider) do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_anthropic_api_key}
    end
  end

  defp api_key_for(@openai_provider) do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, :missing_openai_api_key}
    end
  end

  defp api_key_for(provider), do: {:error, {:unsupported_provider, provider}}

  defp provider_module(@anthropic_provider),
    do: Application.get_env(:symphony_elixir, :quality_gate_anthropic_module, SymphonyElixir.QualityGate.Anthropic)

  defp provider_module(@openai_provider),
    do: Application.get_env(:symphony_elixir, :quality_gate_openai_module, SymphonyElixir.QualityGate.OpenAI)
end
