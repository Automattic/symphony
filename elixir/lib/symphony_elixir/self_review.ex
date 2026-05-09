defmodule SymphonyElixir.SelfReview do
  @moduledoc """
  Conservative pre-push LLM review for acceptance-criteria alignment.

  The gate is intentionally narrow and fail-open: only concrete blocking
  findings in the allowed categories can request changes, and any provider,
  git, or parser failure approves the push path.
  """

  require Logger

  alias SymphonyElixir.{Config.Schema, PromptSafety, QualityGate, SSH}
  alias SymphonyElixir.Linear.Issue

  @allowed_categories %{
    "acceptance_criteria" => :acceptance_criteria,
    "commit_message" => :commit_message,
    "scope_creep" => :scope_creep
  }
  @max_tokens 2_048

  @system_prompt """
  You are a conservative pre-push self-review gate for an autonomous coding agent.

  Check only these blocking questions:
  1. Acceptance-criteria alignment: does the diff deliver what the issue asks for, and only that?
  2. Commit-message honesty: do the commit subject and body accurately describe the diff without overclaiming?
  3. Scope creep: does the diff include work unrelated to the issue?

  Allowed finding categories are exactly:
  - acceptance_criteria
  - commit_message
  - scope_creep

  Explicitly disallowed:
  - style opinions
  - design opinions
  - subjective architecture preferences
  - test-coverage opinions unless the issue explicitly requires that exact test and the diff omits it
  - speculative risks without a quoted line from the diff or commit material

  Bias strongly toward approve. Return zero findings unless one of the three allowed categories is concretely violated.

  Reply with ONLY this JSON shape:
  {
    "verdict": "approve" | "request_changes",
    "findings": [
      {
        "severity": "blocking",
        "category": "acceptance_criteria" | "commit_message" | "scope_creep",
        "description": "<one sentence>",
        "evidence": "<quoted line from diff or commit, optional>"
      }
    ]
  }
  """

  @type verdict :: :approve | :request_changes
  @type finding_category :: :acceptance_criteria | :commit_message | :scope_creep
  @type fail_open_category ::
          :disabled | :parse_error | :git_unavailable | :provider_unavailable | :self_review_unavailable

  @type finding :: %{
          required(:severity) => :blocking,
          required(:category) => finding_category(),
          required(:description) => String.t(),
          optional(:evidence) => String.t()
        }

  @type source_material :: %{
          required(:issue_title) => String.t(),
          required(:issue_description) => String.t(),
          required(:acceptance_criteria) => String.t(),
          required(:linear_input_warnings) => [String.t()],
          required(:changed_paths) => [String.t()],
          required(:commit_messages) => String.t(),
          required(:diff) => String.t(),
          required(:diff_line_count) => non_neg_integer(),
          required(:diff_truncated?) => boolean()
        }

  @type result :: %{
          required(:verdict) => verdict(),
          required(:findings) => [finding()],
          optional(:source) => source_material(),
          optional(:fail_open_reason) => term(),
          optional(:fail_open_category) => fail_open_category()
        }

  @spec evaluate(Issue.t(), Path.t(), Schema.SelfReview.t() | nil) :: result()
  def evaluate(issue, workspace, config), do: evaluate(issue, workspace, config, [])

  @spec evaluate(Issue.t(), Path.t(), Schema.SelfReview.t() | nil, keyword()) :: result()
  def evaluate(_issue, _workspace, %Schema.SelfReview{enabled: false}, _opts), do: approve_result(:disabled)
  def evaluate(_issue, _workspace, nil, _opts), do: approve_result(:disabled)

  def evaluate(%Issue{} = issue, workspace, %Schema.SelfReview{enabled: true} = config, opts)
      when is_binary(workspace) do
    with {:ok, source} <- source_material(issue, workspace, config, opts),
         {:ok, raw_response} <- invoke_provider(source, config, opts),
         {:ok, result} <- parse_response(raw_response) do
      result
      |> Map.put(:source, source)
      |> tap(fn parsed -> log_result(issue, parsed, source) end)
    else
      {:error, {:malformed_response, reason} = fail_open_reason} ->
        Logger.warning("SelfReview malformed LLM output; failing open issue=#{issue.identifier || issue.id} reason=#{inspect(reason)}")
        approve_result(fail_open_reason)

      {:error, reason} ->
        Logger.warning("SelfReview failed open issue=#{issue.identifier || issue.id} reason=#{inspect(reason)}")
        approve_result(reason)
    end
  end

  def evaluate(_issue, _workspace, _config, _opts), do: approve_result(:invalid_input)

  @spec parse_response(String.t() | nil) :: {:ok, result()} | {:error, term()}
  def parse_response(nil), do: {:error, {:malformed_response, :empty_response}}
  def parse_response(""), do: {:error, {:malformed_response, :empty_response}}

  def parse_response(text) when is_binary(text) do
    with {:ok, json} <- isolate_json_object(text),
         {:ok, decoded} <- decode_json(json),
         {:ok, _verdict} <- coerce_verdict(Map.get(decoded, "verdict")),
         {:ok, findings} <- coerce_findings(Map.get(decoded, "findings")) do
      {:ok, result_from_findings(findings)}
    else
      {:error, reason} -> {:error, {:malformed_response, reason}}
    end
  end

  @spec request_changes?(result()) :: boolean()
  def request_changes?(%{verdict: :request_changes}), do: true
  def request_changes?(_result), do: false

  @spec fail_open?(result()) :: boolean()
  def fail_open?(%{fail_open_category: category}) when category not in [nil, :disabled], do: true
  def fail_open?(_result), do: false

  @spec approval_prompt(result()) :: String.t()
  def approval_prompt(_result) do
    """
    Pre-push self-review approved the committed diff.

    Continue the normal workflow push and PR handoff now. Do not add a "Known limitations from self-review" section to the PR description.
    """
  end

  @spec fail_open_prompt(result()) :: String.t()
  def fail_open_prompt(result) do
    """
    Pre-push self-review did not complete, but the gate fails open by design.

    Push regardless now and append this exact section to the PR description so reviewers can see what happened:

    #{fail_open_known_limitations_section(result)}
    """
  end

  @spec request_changes_prompt(result()) :: String.t()
  def request_changes_prompt(%{findings: findings}) do
    """
    Pre-push self-review requested changes.

    Address the blocking findings below in one additional implementation pass. After that pass, Symphony will run one final non-blocking self-review and you must push regardless.

    #{format_findings(findings)}
    """
  end

  @spec push_prompt(result()) :: String.t()
  def push_prompt(%{} = result) do
    if fail_open?(result) do
      """
      Final self-review did not complete, but the gate fails open by design.

      Push regardless now and append this exact section to the PR description so reviewers can see what happened:

      #{fail_open_known_limitations_section(result)}
      """
    else
      push_prompt_for_findings(Map.get(result, :findings, []))
    end
  end

  defp push_prompt_for_findings([]) do
    """
    Final self-review found no remaining blocking findings.

    Push regardless now and complete the normal PR handoff. Do not add a "Known limitations from self-review" section to the PR description.
    """
  end

  defp push_prompt_for_findings(findings) do
    """
    Final self-review still reports blocking findings. Push regardless now.

    Append this exact section to the PR description so reviewers can see what the self-review flagged:

    #{known_limitations_section(findings)}
    """
  end

  @spec known_limitations_section([finding()]) :: String.t()
  def known_limitations_section(findings) when is_list(findings) do
    body =
      findings
      |> Enum.map_join("\n", fn finding ->
        evidence =
          case Map.get(finding, :evidence) do
            evidence when is_binary(evidence) and evidence != "" -> " Evidence: `#{evidence}`"
            _ -> ""
          end

        "- #{format_category(finding.category)}: #{finding.description}#{evidence}"
      end)

    """
    ## Known limitations from self-review

    #{body}
    """
    |> String.trim()
  end

  @spec fail_open_known_limitations_section(result()) :: String.t()
  def fail_open_known_limitations_section(result) do
    category =
      result
      |> Map.get(:fail_open_category, :self_review_unavailable)
      |> to_string()

    """
    ## Known limitations from self-review

    - Self-review did not run: #{category}.
    """
    |> String.trim()
  end

  defp source_material(issue, workspace, config, opts) do
    worker_host = Keyword.get(opts, :worker_host)

    with {:ok, diff} <- git(workspace, ["diff", "origin/main..HEAD"], worker_host),
         {:ok, changed_paths_output} <- git(workspace, ["diff", "--name-only", "origin/main..HEAD"], worker_host),
         {:ok, commit_messages} <- git(workspace, ["log", "--reverse", "--format=%s%n%b%x1e", "origin/main..HEAD"], worker_host) do
      changed_paths = split_lines(changed_paths_output)
      {review_diff, diff_line_count, truncated?} = truncate_diff(diff, changed_paths, config.diff_max_lines, issue)
      raw_acceptance_criteria = acceptance_criteria(issue.description)

      {:ok,
       %{
         issue_title: present_linear(issue.title, &PromptSafety.linear_issue_title/1),
         issue_description: present_linear(issue.description, &PromptSafety.linear_issue_body/1),
         acceptance_criteria: present_linear(raw_acceptance_criteria, &PromptSafety.linear_issue_acceptance_criteria/1),
         linear_input_warnings: linear_input_warnings(issue, raw_acceptance_criteria),
         changed_paths: changed_paths,
         commit_messages: String.trim(commit_messages),
         diff: review_diff,
         diff_line_count: diff_line_count,
         diff_truncated?: truncated?
       }}
    end
  end

  defp invoke_provider(source, %Schema.SelfReview{} = config, opts) do
    with {:ok, settings} <- provider_settings(config) do
      provider = Keyword.get(opts, :provider_module) || QualityGate.provider_module(settings.provider)
      request = %{system: @system_prompt, user: user_prompt(source), max_tokens: @max_tokens}
      settings = Map.put(settings, :max_tokens, @max_tokens)

      if Code.ensure_loaded?(provider) and function_exported?(provider, :review, 2) do
        provider.review(request, settings)
      else
        {:error, {:provider_missing_review_callback, provider}}
      end
    end
  end

  defp provider_settings(%Schema.SelfReview{provider: provider, model: model}) do
    QualityGate.provider_settings(%Schema.QualityGate{provider: provider, model: model})
  end

  defp user_prompt(source) do
    """
    Issue title:
    #{source.issue_title}

    Issue description:
    #{source.issue_description}

    Acceptance criteria:
    #{blank_fallback(source.acceptance_criteria)}

    #{PromptSafety.warning_section(Map.get(source, :linear_input_warnings, []))}

    Changed file paths:
    #{format_paths(source.changed_paths)}

    Commit subjects and bodies:
    #{blank_fallback(source.commit_messages)}

    Git diff origin/main..HEAD:
    #{blank_fallback(source.diff)}
    """
  end

  defp truncate_diff(diff, changed_paths, max_lines, issue) do
    line_count = count_lines(diff)

    if line_count > max_lines do
      Logger.warning("SelfReview diff truncated issue=#{issue.identifier || issue.id} lines=#{line_count} limit=#{max_lines}")

      lines = String.split(diff, "\n", trim: false)
      omitted = line_count - max_lines

      tail_summary =
        [
          "",
          "[Diff truncated: showing first #{max_lines} of #{line_count} lines; omitted #{omitted} line(s).]",
          "[Changed files: #{format_paths(changed_paths)}]"
        ]
        |> Enum.join("\n")

      {Enum.take(lines, max_lines) |> Enum.join("\n") |> Kernel.<>(tail_summary), line_count, true}
    else
      {diff, line_count, false}
    end
  end

  defp git(workspace, args, nil) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  end

  defp git(workspace, args, worker_host) when is_binary(worker_host) do
    command =
      (["git", "-C", workspace] ++ args)
      |> Enum.map_join(" ", &shell_escape/1)

    case SSH.run(worker_host, command, stderr_to_stdout: true) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, {:git_failed, worker_host, args, status, output}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp isolate_json_object(text) do
    text
    |> String.replace(~r/```(?:json)?\s*/i, "")
    |> String.replace("```", "")
    |> String.trim()
    |> case do
      "" -> {:error, :empty_response}
      cleaned -> cleaned |> extract_object() |> then(&if(is_nil(&1), do: {:error, :no_json_object}, else: {:ok, &1}))
    end
  end

  defp extract_object(text) do
    case :binary.match(text, "{") do
      :nomatch -> nil
      {start, _len} -> scan_object(text, start, start, 0, false, nil)
    end
  end

  defp scan_object(text, _start, index, _depth, _in_string?, _escape?) when index >= byte_size(text), do: nil

  defp scan_object(text, start, index, depth, in_string?, escape?) do
    text
    |> :binary.part(index, 1)
    |> scan_step(text, start, index, depth, in_string?, escape?)
  end

  defp scan_step("\\", text, start, index, depth, true, escape?),
    do: scan_object(text, start, index + 1, depth, true, !escape?)

  defp scan_step("\"", text, start, index, depth, true, true),
    do: scan_object(text, start, index + 1, depth, true, false)

  defp scan_step("\"", text, start, index, depth, true, false),
    do: scan_object(text, start, index + 1, depth, false, false)

  defp scan_step("\"", text, start, index, depth, false, _escape?),
    do: scan_object(text, start, index + 1, depth, true, false)

  defp scan_step("{", text, start, index, depth, false, _escape?),
    do: scan_object(text, start, index + 1, depth + 1, false, false)

  defp scan_step("}", text, start, index, depth, false, _escape?) do
    new_depth = depth - 1

    if new_depth == 0 do
      :binary.part(text, start, index - start + 1)
    else
      scan_object(text, start, index + 1, new_depth, false, false)
    end
  end

  defp scan_step(_byte, text, start, index, depth, in_string?, _escape?),
    do: scan_object(text, start, index + 1, depth, in_string?, false)

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp coerce_verdict(verdict) when verdict in ["approve", "request_changes"], do: {:ok, verdict}
  defp coerce_verdict(_verdict), do: {:error, :invalid_verdict}

  defp coerce_findings(findings) when is_list(findings) do
    {:ok, Enum.flat_map(findings, &normalize_finding/1)}
  end

  defp coerce_findings(_findings), do: {:error, :invalid_findings}

  defp normalize_finding(%{"severity" => "blocking", "category" => category, "description" => description} = finding)
       when is_binary(description) do
    description = String.trim(description)

    with %{^category => normalized_category} <- @allowed_categories,
         false <- description == "" do
      [
        %{
          severity: :blocking,
          category: normalized_category,
          description: description
        }
        |> maybe_put_evidence(Map.get(finding, "evidence"))
      ]
    else
      _ -> []
    end
  end

  defp normalize_finding(_finding), do: []

  defp maybe_put_evidence(finding, evidence) when is_binary(evidence) do
    case String.trim(evidence) do
      "" -> finding
      trimmed -> Map.put(finding, :evidence, trimmed)
    end
  end

  defp maybe_put_evidence(finding, _evidence), do: finding

  defp log_result(issue, %{verdict: :request_changes, findings: findings}, _source) do
    Logger.info("SelfReview requested changes issue=#{issue.identifier || issue.id} findings=#{length(findings)}")
  end

  defp log_result(issue, %{verdict: :approve}, %{diff_truncated?: truncated?}) do
    suffix = if truncated?, do: " truncated=true", else: ""
    Logger.info("SelfReview approved issue=#{issue.identifier || issue.id}#{suffix}")
  end

  defp result_from_findings([]), do: %{verdict: :approve, findings: []}
  defp result_from_findings([_ | _] = findings), do: %{verdict: :request_changes, findings: findings}

  defp approve_result(reason) do
    %{
      verdict: :approve,
      findings: [],
      fail_open_reason: reason,
      fail_open_category: fail_open_category(reason)
    }
  end

  defp fail_open_category(:disabled), do: :disabled
  defp fail_open_category({:malformed_response, _reason}), do: :parse_error
  defp fail_open_category({:git_failed, _args, _status, _output}), do: :git_unavailable
  defp fail_open_category({:git_failed, _worker_host, _args, _status, _output}), do: :git_unavailable
  defp fail_open_category(:ssh_not_found), do: :git_unavailable
  defp fail_open_category(:missing_anthropic_api_key), do: :provider_unavailable
  defp fail_open_category(:missing_openai_api_key), do: :provider_unavailable
  defp fail_open_category({:provider_http_status, _status, _body}), do: :provider_unavailable
  defp fail_open_category({:provider_request_failed, _reason}), do: :provider_unavailable
  defp fail_open_category({:provider_missing_review_callback, _provider}), do: :provider_unavailable
  defp fail_open_category({:unsupported_provider, _provider}), do: :provider_unavailable
  defp fail_open_category(_reason), do: :self_review_unavailable

  defp acceptance_criteria(description) when is_binary(description) do
    case Regex.run(~r/^##\s+Acceptance criteria\s*(.*?)(?=^##\s+|\z)/ims, description, capture: :all_but_first) do
      [criteria] -> String.trim(criteria)
      _ -> ""
    end
  end

  defp acceptance_criteria(_description), do: ""

  defp linear_input_warnings(issue, acceptance_criteria) do
    [
      {"issue.title", issue.title},
      {"issue.description", issue.description},
      {"issue.acceptance_criteria", acceptance_criteria}
    ]
    |> PromptSafety.warning_fields()
  end

  defp count_lines(""), do: 0
  defp count_lines(text) when is_binary(text), do: length(String.split(text, "\n", trim: false))

  defp split_lines(text) when is_binary(text), do: text |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

  defp format_paths([]), do: "(none)"
  defp format_paths(paths), do: Enum.join(paths, "\n")

  defp format_findings(findings) do
    findings
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {finding, index} ->
      evidence =
        case Map.get(finding, :evidence) do
          evidence when is_binary(evidence) and evidence != "" -> "\n   Evidence: #{evidence}"
          _ -> ""
        end

      "#{index}. [#{format_category(finding.category)}] #{finding.description}#{evidence}"
    end)
  end

  defp format_category(category) when is_atom(category), do: Atom.to_string(category)
  defp format_category(category), do: to_string(category)

  defp blank_fallback(value, fallback \\ "(none)")

  defp blank_fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      _ -> value
    end
  end

  defp present_linear(value, _renderer) when value in [nil, ""], do: ""

  defp present_linear(value, renderer) when is_binary(value), do: renderer.(value)

  defp present_linear(value, renderer), do: value |> to_string() |> renderer.()

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
