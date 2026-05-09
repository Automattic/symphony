defmodule SymphonyElixir.Learnings.Reflection do
  @moduledoc """
  Captures structured run-end learnings from a merged PR.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Learnings.Store
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.{QualityGate, RunStore}

  @max_tokens 1_024
  @default_transcript_event_limit 20
  @max_field_chars 8_000
  @tag_pattern ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @system_prompt """
  You produce durable, repo-specific learnings for future autonomous coding runs.

  Return ONLY strict JSON with this shape:
  {
    "learnings": [
      {
        "rule": "<one short imperative sentence, specific to this repo>",
        "tags": ["<2-5 short kebab-case tags>"],
        "evidence_quote": "<verbatim or near-verbatim reviewer comment, failure, or decision>"
      }
    ]
  }

  Rules:
  - Return 0 to 3 learnings.
  - Use an empty array when there is no clear, reusable, repo-specific lesson.
  - Prefer reviewer preferences, repo-specific gotchas, repeated failure patterns, or rejected approaches.
  - Do not write generic software advice.
  - Every learning must include a non-empty evidence_quote from the source material.
  """

  @type source :: %{
          required(:issue_identifier) => String.t() | nil,
          required(:issue_url) => String.t() | nil,
          required(:issue_title) => String.t(),
          required(:issue_description) => String.t(),
          required(:issue_comments) => [map()],
          required(:pr_url) => String.t(),
          required(:pr_number) => non_neg_integer() | nil,
          required(:pr_title) => String.t(),
          required(:pr_description) => String.t(),
          required(:pr_comments) => [map()],
          required(:repo) => String.t(),
          required(:run_id) => String.t() | nil,
          required(:transcript_events) => [term()]
        }

  @spec capture(map(), Schema.Learnings.t() | nil, keyword()) ::
          {:ok, non_neg_integer()} | {:discarded, term()} | {:error, term()}
  def capture(_source, %Schema.Learnings{enabled: false}, _opts), do: {:ok, 0}
  def capture(_source, nil, _opts), do: {:ok, 0}

  def capture(%{} = source, %Schema.Learnings{enabled: true} = config, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, material} <- source_material(source, opts),
         {:ok, raw_response} <- invoke_provider(material, config, opts),
         {:ok, parsed_entries} <- parse_response(raw_response, config.max_per_run),
         records = learning_records(parsed_entries, material, now, Keyword.get(opts, :repo_key)),
         :ok <-
           Store.put_many(records,
             repo_key: Keyword.get(opts, :repo_key),
             max_total_per_repo: config.max_total_per_repo,
             run_store: Keyword.get(opts, :run_store, RunStore)
           ) do
      Logger.info("Learning reflection captured issue=#{material.issue_identifier || "unknown"} pr=#{material.pr_number || "unknown"} count=#{length(records)}")

      {:ok, length(records)}
    else
      {:error, {:malformed_response, reason}} ->
        Logger.warning("Learning reflection malformed LLM output; discarded reason=#{inspect(reason)}")
        {:discarded, reason}

      {:error, reason} ->
        Logger.warning("Learning reflection failed reason=#{inspect(reason)}")
        {:error, reason}
    end
  end

  def capture(_source, _config, _opts), do: {:error, :invalid_learning_source}

  @spec parse_response(String.t() | nil, non_neg_integer()) :: {:ok, [map()]} | {:error, {:malformed_response, term()}}
  def parse_response(nil, _max_per_run), do: {:error, {:malformed_response, :empty_response}}

  def parse_response(text, max_per_run) when is_binary(text) and is_integer(max_per_run) and max_per_run >= 0 do
    with {:ok, decoded} <- decode_json(text),
         {:ok, entries} <- response_entries(decoded),
         {:ok, normalized} <- normalize_entries(entries) do
      {:ok, Enum.take(normalized, max_per_run)}
    else
      {:error, reason} -> {:error, {:malformed_response, reason}}
    end
  end

  def parse_response(_text, _max_per_run), do: {:error, {:malformed_response, :invalid_response}}

  defp source_material(%{} = source, opts) do
    record = Map.get(source, :record, %{})
    activity = Map.get(source, :activity, %{})
    issue = Map.get(source, :issue)
    pr_url = string_field(activity, :pr_url) || string_field(record, :pr_url)

    issue_identifier =
      present_optional(issue_field(issue, :identifier)) ||
        present_optional(string_field(record, :issue_identifier))

    issue_url = present_optional(issue_field(issue, :url)) || present_optional(string_field(record, :issue_url))

    with {:ok, repo, pr_number} <- pr_coordinates(pr_url) do
      {:ok,
       %{
         issue_identifier: issue_identifier,
         issue_url: issue_url,
         issue_title: present(issue_field(issue, :title) || string_field(record, :issue_title)),
         issue_description: present(issue_field(issue, :description)),
         issue_comments: issue_comments(issue),
         pr_url: pr_url,
         pr_number: integer_field(activity, :pr_number) || pr_number,
         pr_title: present(string_field(activity, :pr_title)),
         pr_description: present(string_field(activity, :pr_description)),
         pr_comments: Map.get(activity, :comments, []),
         repo: repo,
         run_id: string_field(record, :run_id),
         transcript_events: transcript_events(record, Keyword.get(opts, :transcript_event_limit, @default_transcript_event_limit))
       }}
    end
  end

  defp invoke_provider(source, %Schema.Learnings{} = config, opts) do
    with {:ok, settings} <- provider_settings(config) do
      provider = Keyword.get(opts, :provider_module) || QualityGate.provider_module(settings.provider)
      request = %{system: @system_prompt, user: user_prompt(source), max_tokens: @max_tokens}

      if function_exported?(provider, :review, 2) do
        provider.review(request, Map.put(settings, :max_tokens, @max_tokens))
      else
        {:error, {:provider_missing_review_callback, provider}}
      end
    end
  end

  defp provider_settings(%Schema.Learnings{provider: provider, model: model}) do
    QualityGate.provider_settings(%Schema.QualityGate{provider: provider, model: model})
  end

  defp user_prompt(source) do
    """
    Repository:
    #{source.repo}

    Linear issue:
    #{blank_fallback(source.issue_identifier)}

    Issue title:
    #{blank_fallback(source.issue_title)}

    Issue description:
    #{blank_fallback(source.issue_description)}

    Recent Linear comments:
    #{format_comments(source.issue_comments)}

    Pull request:
    #{source.pr_url}

    Pull request title:
    #{blank_fallback(source.pr_title)}

    Pull request description:
    #{blank_fallback(source.pr_description)}

    Pull request comments and reviews:
    #{format_comments(source.pr_comments)}

    Recent transcript events:
    #{format_transcript_events(source.transcript_events)}
    """
  end

  defp decode_json(text) do
    text
    |> strip_code_fences()
    |> Jason.decode()
    |> case do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp strip_code_fences(text) do
    text
    |> String.replace(~r/```(?:json)?\s*/i, "")
    |> String.replace("```", "")
    |> String.trim()
  end

  defp response_entries(%{"learnings" => entries}) when is_list(entries), do: {:ok, entries}
  defp response_entries(entries) when is_list(entries), do: {:ok, entries}
  defp response_entries(%{"rule" => _rule} = entry), do: {:ok, [entry]}
  defp response_entries(_decoded), do: {:error, :invalid_learning_response_shape}

  defp normalize_entries(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_entry(%{"rule" => rule, "tags" => tags, "evidence_quote" => evidence_quote}) do
    with {:ok, rule} <- non_empty_string(rule, :invalid_rule),
         {:ok, evidence_quote} <- non_empty_string(evidence_quote, :invalid_evidence_quote),
         {:ok, tags} <- normalize_tags(tags) do
      {:ok, %{rule: rule, tags: tags, evidence_quote: evidence_quote}}
    end
  end

  defp normalize_entry(_entry), do: {:error, :invalid_learning_entry}

  defp non_empty_string(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      trimmed -> {:ok, trimmed}
    end
  end

  defp non_empty_string(_value, error), do: {:error, error}

  defp normalize_tags(tags) when is_list(tags) do
    normalized =
      tags
      |> Enum.map(&normalize_tag/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if length(normalized) in 2..5 do
      {:ok, normalized}
    else
      {:error, :invalid_tags}
    end
  end

  defp normalize_tags(_tags), do: {:error, :invalid_tags}

  defp normalize_tag(tag) when is_binary(tag) do
    trimmed = String.trim(tag)

    if trimmed == String.downcase(trimmed) and Regex.match?(@tag_pattern, trimmed) do
      trimmed
    end
  end

  defp normalize_tag(_tag), do: nil

  defp learning_records(entries, source, now, repo_key) do
    Enum.map(entries, fn entry ->
      Map.merge(entry, %{
        id: new_id(),
        repo_key: repo_key || Config.repo_key!(),
        repo: source.repo,
        evidence_issue_identifier: source.issue_identifier,
        evidence_issue_url: source.issue_url,
        evidence_pr_number: source.pr_number,
        evidence_run_id: source.run_id,
        created_at: now
      })
    end)
  end

  defp new_id do
    "lrn_" <> (:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false))
  end

  defp pr_coordinates(pr_url) when is_binary(pr_url) do
    uri = URI.parse(pr_url)
    path_parts = uri.path |> to_string() |> String.split("/", trim: true)

    case {uri.host, path_parts} do
      {host, [owner, repo, "pull", number | _rest]} when is_binary(host) ->
        case Integer.parse(number) do
          {pr_number, ""} -> {:ok, "#{host}/#{owner}/#{repo}", pr_number}
          _ -> {:error, :invalid_pr_number}
        end

      _ ->
        {:error, :invalid_pr_url}
    end
  end

  defp pr_coordinates(_pr_url), do: {:error, :invalid_pr_url}

  defp issue_field(%Issue{} = issue, field), do: Map.get(issue, field)
  defp issue_field(_issue, _field), do: nil

  defp issue_comments(%Issue{comments: comments}) when is_list(comments), do: comments
  defp issue_comments(_issue), do: []

  defp transcript_events(record, limit) when is_map(record) and is_integer(limit) and limit > 0 do
    record
    |> string_field(:transcript_path)
    |> transcript_file_events()
    |> Enum.take(-limit)
  end

  defp transcript_events(_record, _limit), do: []

  defp transcript_file_events(path) when is_binary(path) and path != "" do
    with true <- File.regular?(path),
         {:ok, contents} <- File.read(path) do
      contents
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&decode_transcript_line/1)
    else
      _ -> []
    end
  rescue
    _exception -> []
  end

  defp transcript_file_events(_path), do: []

  defp decode_transcript_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> line
    end
  end

  defp format_comments(comments) when is_list(comments) and comments != [] do
    comments
    |> Enum.take(-20)
    |> Enum.map_join("\n\n", fn comment ->
      author = string_field(comment, :author) || "unknown"
      body = string_field(comment, :body) || ""
      url = string_field(comment, :url)

      ["[#{author}]", truncate(body), url]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")
    end)
    |> blank_fallback()
  end

  defp format_comments(_comments), do: "(none)"

  defp format_transcript_events(events) when is_list(events) and events != [] do
    events
    |> Enum.map_join("\n", fn event -> "- " <> truncate(event_summary(event), 600) end)
    |> blank_fallback()
  end

  defp format_transcript_events(_events), do: "(none)"

  defp event_summary(event) when is_binary(event), do: event
  defp event_summary(event), do: inspect(event, limit: 20, printable_limit: 600)

  defp truncate(value, max_chars \\ @max_field_chars)

  defp truncate(value, max_chars) when is_binary(value) and is_integer(max_chars) and max_chars >= 0 do
    if String.length(value) > max_chars do
      String.slice(value, 0, max_chars) <> "\n[truncated]"
    else
      value
    end
  end

  defp truncate(value, max_chars), do: value |> inspect() |> truncate(max_chars)

  defp blank_fallback(value, fallback \\ "(none)")

  defp blank_fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp blank_fallback(_value, fallback), do: fallback

  defp present(value) when is_binary(value), do: value
  defp present(nil), do: ""
  defp present(value), do: to_string(value)

  defp present_optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_optional(nil), do: nil
  defp present_optional(value), do: value |> to_string() |> present_optional()

  defp string_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp string_field(_map, _key), do: nil

  defp integer_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> value |> Integer.parse() |> parse_integer()
      _value -> nil
    end
  end

  defp integer_field(_map, _key), do: nil

  defp parse_integer({value, ""}), do: value
  defp parse_integer(_value), do: nil
end
