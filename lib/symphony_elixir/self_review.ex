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
  alias SymphonyElixir.SelfReview.Context

  @allowed_categories %{
    "acceptance_criteria" => :acceptance_criteria,
    "commit_message" => :commit_message,
    "scope_creep" => :scope_creep
  }
  @allowed_advisory_categories %{
    "missing_context" => :missing_context,
    "test_evidence_gap" => :test_evidence_gap,
    "docs_sync_risk" => :docs_sync_risk,
    "blast_radius_risk" => :blast_radius_risk,
    "review_coverage_low" => :review_coverage_low
  }
  @max_tokens 2_048

  @system_prompt """
  You are a conservative pre-push self-review gate for an autonomous coding agent.

  Check only these blocking questions:
  1. Acceptance-criteria alignment: does the diff deliver what the issue asks for, and only that?
  2. Commit-message honesty: do the commit subject and body accurately describe the diff without overclaiming?
  3. Scope creep: does the diff include work unrelated to the issue?

  For each acceptance criterion, map it to concrete evidence from the structured context pack.
  If evidence is missing or context coverage is low, report that as an advisory note, not a blocking finding,
  unless the missing item directly violates one of the three blocking questions above.

  Allowed finding categories are exactly:
  - acceptance_criteria
  - commit_message
  - scope_creep

  Allowed advisory note categories are exactly:
  - missing_context
  - test_evidence_gap
  - docs_sync_risk
  - blast_radius_risk
  - review_coverage_low

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
    ],
    "acceptance_matrix": [
      {
        "criterion": "<acceptance criterion>",
        "evidence": ["<file/test/validation evidence>"],
        "missing_evidence": false
      }
    ],
    "advisory_notes": [
      {
        "category": "missing_context" | "test_evidence_gap" | "docs_sync_risk" | "blast_radius_risk" | "review_coverage_low",
        "description": "<one sentence>",
        "evidence": "<quoted coverage or validation context, optional>"
      }
    ]
  }
  """

  @type verdict :: :approve | :request_changes
  @type finding_category :: :acceptance_criteria | :commit_message | :scope_creep
  @type advisory_category ::
          :missing_context | :test_evidence_gap | :docs_sync_risk | :blast_radius_risk | :review_coverage_low
  @type fail_open_category ::
          :disabled | :parse_error | :git_unavailable | :provider_unavailable | :self_review_unavailable

  @type finding :: %{
          required(:severity) => :blocking,
          required(:category) => finding_category(),
          required(:description) => String.t(),
          optional(:evidence) => String.t()
        }

  @type advisory_note :: %{
          required(:category) => advisory_category(),
          required(:description) => String.t(),
          optional(:evidence) => String.t()
        }

  @type source_material :: %{
          required(:issue_title) => String.t(),
          required(:issue_description) => String.t(),
          required(:acceptance_criteria) => String.t(),
          required(:acceptance_criteria_items) => [String.t()],
          required(:linear_input_warnings) => [String.t()],
          required(:changed_paths) => [String.t()],
          required(:changed_file_inventory) => [map()],
          required(:commit_messages) => String.t(),
          required(:git_range) => String.t(),
          required(:diff) => String.t(),
          required(:diff_line_count) => non_neg_integer(),
          required(:diff_truncated?) => boolean(),
          required(:review_coverage) => map(),
          required(:context_pack) => map()
        }

  @type result :: %{
          required(:verdict) => verdict(),
          required(:findings) => [finding()],
          optional(:advisory_notes) => [advisory_note()],
          optional(:acceptance_matrix) => [map()],
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
         {:ok, findings} <- coerce_findings(Map.get(decoded, "findings")),
         {:ok, acceptance_matrix} <- coerce_acceptance_matrix(Map.get(decoded, "acceptance_matrix")),
         {:ok, advisory_notes} <- coerce_advisory_notes(Map.get(decoded, "advisory_notes")) do
      {:ok, result_from_findings(findings)}
      |> then(fn {:ok, result} ->
        {:ok,
         result
         |> Map.put(:acceptance_matrix, acceptance_matrix)
         |> Map.put(:advisory_notes, advisory_notes)}
      end)
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
  def approval_prompt(result) do
    """
    Pre-push self-review approved the committed diff.

    Continue the normal workflow push and PR handoff now. Do not add a "Known limitations from self-review" section to the PR description.
    #{advisory_prompt_instruction(result)}
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
      push_prompt_for_result(Map.put_new(result, :findings, []))
    end
  end

  defp push_prompt_for_result(%{findings: []} = result) do
    """
    Final self-review found no remaining blocking findings.

    Push regardless now and complete the normal PR handoff. Do not add a "Known limitations from self-review" section to the PR description.
    #{advisory_prompt_instruction(result)}
    """
  end

  defp push_prompt_for_result(%{findings: findings} = result) do
    """
    Final self-review still reports blocking findings. Push regardless now.

    Append this exact section to the PR description so reviewers can see what the self-review flagged:

    #{known_limitations_section(findings)}
    #{advisory_prompt_instruction(result)}
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

  @spec advisory_notes_section([advisory_note()]) :: String.t()
  def advisory_notes_section(notes) when is_list(notes) do
    body =
      notes
      |> Enum.map_join("\n", fn note ->
        evidence =
          case Map.get(note, :evidence) do
            evidence when is_binary(evidence) and evidence != "" -> " Evidence: `#{evidence}`"
            _ -> ""
          end

        "- #{format_category(note.category)}: #{note.description}#{evidence}"
      end)

    """
    ## Self-review advisory notes

    #{body}
    """
    |> String.trim()
  end

  defp source_material(issue, workspace, config, opts) do
    worker_host = Keyword.get(opts, :worker_host)
    comparison_base = comparison_base(workspace, opts, worker_host)
    git_range = "#{comparison_base}..HEAD"
    git_fun = fn args -> git(workspace, args, worker_host) end

    Context.build(issue, workspace, config, git_range, opts, git_fun)
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

    Commit subjects and bodies:
    #{blank_fallback(source.commit_messages)}

    Git diff #{source.git_range}:
    Structured context pack:
    #{blank_fallback(source.diff)}

    Reviewer task:
    - Fill the acceptance matrix from concrete file, test, validation, reviewer, or CI evidence.
    - Flag missing evidence in `acceptance_matrix` and, when useful, in `advisory_notes`.
    - Only use `findings` for blocking issues in the three allowed categories.
    """
  end

  defp comparison_base(workspace, opts, worker_host) do
    case configured_comparison_base(Keyword.get(opts, :base_branch)) do
      nil -> origin_head_comparison_base(workspace, worker_host)
      base -> base
    end
  end

  defp configured_comparison_base(base_branch) when is_binary(base_branch) do
    case String.trim(base_branch) do
      "" -> nil
      "origin/" <> branch -> normalize_branch_ref(branch)
      "refs/heads/" <> branch -> normalize_branch_ref(branch)
      branch -> normalize_branch_ref(branch)
    end
  end

  defp configured_comparison_base(_base_branch), do: nil

  defp normalize_branch_ref(branch) do
    case String.trim(branch) do
      "" -> nil
      trimmed -> "origin/#{trimmed}"
    end
  end

  defp origin_head_comparison_base(workspace, worker_host) do
    case git(workspace, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], worker_host) do
      {:ok, output} ->
        output
        |> String.trim()
        |> blank_fallback("origin/main")

      {:error, reason} ->
        Logger.info("SelfReview origin/HEAD unresolved, falling back to origin/main reason=#{inspect(reason)}")
        "origin/main"
    end
  end

  defp git(workspace, args, nil) do
    case SymphonyElixir.Workspace.safe_git(["-C", workspace | args]) do
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

  defp coerce_advisory_notes(nil), do: {:ok, []}

  defp coerce_advisory_notes(notes) when is_list(notes) do
    {:ok, Enum.flat_map(notes, &normalize_advisory_note/1)}
  end

  defp coerce_advisory_notes(_notes), do: {:error, :invalid_advisory_notes}

  defp coerce_acceptance_matrix(nil), do: {:ok, []}

  defp coerce_acceptance_matrix(matrix) when is_list(matrix) do
    {:ok, Enum.flat_map(matrix, &normalize_acceptance_matrix_item/1)}
  end

  defp coerce_acceptance_matrix(_matrix), do: {:error, :invalid_acceptance_matrix}

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

  defp normalize_advisory_note(%{"category" => category, "description" => description} = note)
       when is_binary(description) do
    description = String.trim(description)

    with %{^category => normalized_category} <- @allowed_advisory_categories,
         false <- description == "" do
      [
        %{
          category: normalized_category,
          description: description
        }
        |> maybe_put_evidence(Map.get(note, "evidence"))
      ]
    else
      _ -> []
    end
  end

  defp normalize_advisory_note(_note), do: []

  defp normalize_acceptance_matrix_item(%{"criterion" => criterion} = item) when is_binary(criterion) do
    criterion = String.trim(criterion)

    if criterion == "" do
      []
    else
      [
        %{
          criterion: criterion,
          evidence: string_list(Map.get(item, "evidence")),
          missing_evidence: Map.get(item, "missing_evidence") == true
        }
      ]
    end
  end

  defp normalize_acceptance_matrix_item(_item), do: []

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

  defp advisory_prompt_instruction(%{advisory_notes: notes}) when is_list(notes) and notes != [] do
    """

    Append this exact non-blocking advisory section to the PR description:

    #{advisory_notes_section(notes)}
    """
  end

  defp advisory_prompt_instruction(_result), do: ""

  defp string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp string_list(_values), do: []

  defp blank_fallback(value, fallback \\ "(none)")

  defp blank_fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      _ -> value
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
