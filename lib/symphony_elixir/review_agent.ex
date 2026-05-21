defmodule SymphonyElixir.ReviewAgent do
  @moduledoc """
  Runs a configured reviewer agent against the committed diff and parses its verdict.
  """

  require Logger

  alias SymphonyElixir.{Config, PromptSafety, SSH}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ReviewAgent.Context

  @max_diff_prompt_bytes 120_000
  @agent_message_methods [
    "item/agentMessage/delta",
    "codex/event/agent_message_delta",
    "codex/event/agent_message_content_delta"
  ]

  @type verdict :: :approve | :request_changes | :block
  @type result :: %{
          required(:verdict) => verdict(),
          required(:comments) => [String.t()],
          optional(:reason) => String.t(),
          optional(:source) => map()
        }

  @spec enabled?(Schema.ReviewAgent.t() | nil) :: boolean()
  def enabled?(%Schema.ReviewAgent{enabled: true}), do: true
  def enabled?(_config), do: false

  @spec evaluate(Issue.t(), Path.t(), Schema.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def evaluate(%Issue{} = issue, workspace, %Schema{} = settings, opts \\ []) when is_binary(workspace) do
    config = settings.review_agent

    with true <- enabled?(config),
         {:ok, source} <- source_material(issue, workspace, settings, opts),
         {:ok, raw_response} <- run_reviewer_agent(issue, workspace, settings, source, opts),
         {:ok, verdict} <- pick_review_response(raw_response) do
      {:ok, Map.put(verdict, :source, source)}
    else
      false -> {:ok, %{verdict: :approve, comments: [], reason: "review_agent disabled"}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse_response(String.t() | nil) :: {:ok, result()} | {:error, term()}
  def parse_response(nil), do: {:error, {:malformed_review_agent_response, :empty_response}}
  def parse_response(""), do: {:error, {:malformed_review_agent_response, :empty_response}}

  def parse_response(text) when is_binary(text) do
    with :ok <- reject_runtime_error_response(text),
         {:ok, json} <- isolate_json_object(text),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, verdict} <- coerce_verdict(Map.get(decoded, "verdict")),
         {:ok, comments} <- coerce_comments(Map.get(decoded, "comments")),
         {:ok, reason} <- coerce_reason(Map.get(decoded, "reason"), verdict),
         {:ok, result} <- validate_result(%{verdict: verdict, comments: comments, reason: reason}) do
      {:ok, compact_result(result)}
    else
      {:error, {:review_agent_runtime_error, _raw} = reason} -> {:error, reason}
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:malformed_review_agent_response, {:invalid_json, reason}}}
      {:error, reason} -> {:error, {:malformed_review_agent_response, reason}}
    end
  end

  @spec approval_prompt(result()) :: String.t()
  def approval_prompt(_result) do
    """
    Reviewer agent approved the committed diff.

    Continue the normal workflow push and PR handoff now. Use the validation evidence already collected for the reviewed diff. Do not stop at the reviewer-agent gate again unless code changes after this approval.

    Use the scoped `github_get_pull_request`, `github_push_branch`, and `github_create_pull_request` tools for PR handoff. Avoid raw `gh` or `git push` from shell commands because unattended runtimes may not have direct GitHub or SSH credential access.
    """
  end

  @spec request_changes_prompt(result()) :: String.t()
  def request_changes_prompt(%{comments: comments}) do
    body =
      comments
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {comment, index} -> "#{index}. #{comment}" end)

    """
    Reviewer agent requested changes.

    Address the review comments below in one additional implementation pass. Keep the same workspace and workpad, then stop before push again so Symphony can rerun reviewer approval.

    #{body}
    """
  end

  @spec block_reason(result()) :: String.t()
  def block_reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  def block_reason(%{comments: [comment | _]}) when is_binary(comment), do: comment
  def block_reason(_result), do: "review_agent blocked the run"

  defp source_material(issue, workspace, _settings, opts) do
    worker_host = Keyword.get(opts, :worker_host)
    comparison_base = comparison_base(workspace, opts, worker_host)
    range_base = merge_base(workspace, comparison_base, worker_host)
    git_range = "#{range_base}..HEAD"
    git_fun = fn args -> git(workspace, args, worker_host) end

    Context.build(issue, workspace, git_range, opts, git_fun)
  end

  defp run_reviewer_agent(issue, workspace, settings, source, opts) do
    config = settings.review_agent

    with {:ok, agent_module} <- resolve_agent_module(opts, config) do
      reviewer_settings = reviewer_settings(settings, config)
      prompt = reviewer_prompt(issue, source, opts)
      message_collector = Keyword.get(opts, :review_agent_message_collector, self())
      on_message = reviewer_on_message(message_collector, Keyword.get(opts, :on_reviewer_message))

      with {:ok, session} <-
             agent_module.start_session(workspace,
               worker_host: Keyword.get(opts, :worker_host),
               settings: reviewer_settings,
               issue: issue,
               repo_key: Keyword.get(opts, :repo_key),
               run_id: Keyword.get(opts, :run_id),
               tool_scope: :read_only,
               linear_comment_registry: Keyword.get(opts, :linear_comment_registry)
             ) do
        try do
          case agent_module.run_turn(session, prompt, issue,
                 on_message: on_message,
                 settings: reviewer_settings,
                 repo_key: Keyword.get(opts, :repo_key),
                 run_id: Keyword.get(opts, :run_id),
                 tool_scope: :read_only,
                 linear_comment_registry: Keyword.get(opts, :linear_comment_registry)
               ) do
            {:ok, result} -> {:ok, response_payload(result, message_collector)}
            {:error, reason} -> {:error, {:review_agent_failed, reason}}
          end
        after
          agent_module.stop_session(session)
        end
      end
    end
  end

  defp reviewer_settings(%Schema{} = settings, %Schema.ReviewAgent{} = config) do
    %{settings | agent: %{settings.agent | kind: config.kind, command: config.command}}
  end

  defp resolve_agent_module(opts, %Schema.ReviewAgent{} = config) do
    case Keyword.get(opts, :review_agent_module) do
      nil -> agent_module(config.kind)
      module when is_atom(module) -> {:ok, module}
    end
  end

  defp agent_module("codex"), do: {:ok, SymphonyElixir.Codex.AppServer}
  defp agent_module("claude"), do: {:ok, SymphonyElixir.ClaudeCode.AppServer}
  defp agent_module(other), do: {:error, {:unsupported_review_agent_kind, other}}

  defp reviewer_prompt(issue, source, opts) do
    workflow_prompt =
      opts
      |> Keyword.get(:repo_key)
      |> Config.workflow_prompt()

    """
    You are the reviewer agent in an executor + reviewer Symphony run.

    Review the executor's committed diff for this Linear issue. You may inspect files and use read-only scoped Linear/GitHub tools, but you must not modify files, write Linear/GitHub data, push, or open a PR.

    Issue:
    #{present_issue(issue)}

    Workflow review criteria:
    #{workflow_prompt}

    Diff context:
    #{truncate(source.diff, @max_diff_prompt_bytes)}

    Return ONLY one JSON object in this shape:
    {
      "verdict": "approve" | "request_changes" | "block",
      "comments": ["<required for request_changes; concise actionable comments>"],
      "reason": "<required for block>"
    }
    """
  end

  defp present_issue(%Issue{} = issue) do
    """
    Identifier: #{issue.identifier}
    Title: #{PromptSafety.linear_issue_title(issue.title)}
    Description:
    #{PromptSafety.linear_issue_body(issue.description)}
    """
  end

  defp reviewer_on_message(collector, forward) do
    fn message ->
      collect_message(collector, message)
      if is_function(forward, 1), do: forward.(message)
      :ok
    end
  end

  defp collect_message(collector, message) when is_pid(collector) do
    send(collector, {:review_agent_message, self(), message})
  end

  defp collect_message(_collector, _message), do: :ok

  defp response_payload(result, collector) do
    primary = result |> response_text() |> String.trim()
    messages = drain_collected_messages(collector, [])
    message_output = messages |> Enum.map_join("", &message_text/1) |> String.trim()

    combined =
      [primary, message_output]
      |> Enum.join("\n")
      |> String.trim()

    %{primary: primary, messages: message_output, combined: combined}
  end

  defp pick_review_response(%{primary: primary, messages: messages, combined: combined}) do
    [primary, messages, combined]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == ""))
    |> parse_first_review_response(nil)
  end

  defp pick_review_response(%{primary: primary, combined: combined}) do
    pick_review_response(%{primary: primary, messages: "", combined: combined})
  end

  defp parse_first_review_response([], nil), do: parse_response("")
  defp parse_first_review_response([], fallback), do: fallback

  defp parse_first_review_response([text | rest], fallback) do
    case parse_response(text) do
      {:ok, _result} = ok -> ok
      {:error, reason} -> parse_first_review_response(rest, preferred_parse_error(fallback, {:error, reason}))
    end
  end

  defp preferred_parse_error(nil, error), do: error
  defp preferred_parse_error({:error, {:review_agent_runtime_error, _raw}} = fallback, _error), do: fallback
  defp preferred_parse_error(_fallback, {:error, {:review_agent_runtime_error, _raw}} = error), do: error
  defp preferred_parse_error(fallback, _error), do: fallback

  defp drain_collected_messages(collector, acc) when is_pid(collector) do
    receive do
      {:review_agent_message, _pid, message} -> drain_collected_messages(collector, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_collected_messages(_collector, _acc), do: []

  defp response_text(result) when is_map(result) do
    Enum.find_value([:result, "result", :text, "text", :output, "output"], fn key ->
      case Map.get(result, key) do
        value when is_binary(value) -> value
        _value -> nil
      end
    end) || ""
  end

  defp response_text(value) when is_binary(value), do: value
  defp response_text(_value), do: ""

  defp message_text({:agent_text, text}) when is_binary(text), do: text

  defp message_text(%{event: :agent_text, payload: %{params: %{msg: %{content: text}}}}) when is_binary(text), do: text
  defp message_text(%{event: :agent_text, payload: %{"params" => %{"msg" => %{"content" => text}}}}) when is_binary(text), do: text
  defp message_text(%{payload: payload}) when is_map(payload), do: payload_text(payload)
  defp message_text(%{"payload" => payload}) when is_map(payload), do: payload_text(payload)
  defp message_text(message) when is_map(message), do: payload_text(message)
  defp message_text(_message), do: ""

  defp payload_text(%{"method" => method, "params" => params}) when method in @agent_message_methods and is_map(params),
    do: agent_message_params_text(params)

  defp payload_text(%{"result" => text}) when is_binary(text), do: text
  defp payload_text(_payload), do: ""

  defp agent_message_params_text(%{"delta" => text}) when is_binary(text), do: text
  defp agent_message_params_text(%{"msg" => msg}) when is_map(msg), do: agent_message_msg_text(msg)
  defp agent_message_params_text(_params), do: ""

  defp agent_message_msg_text(%{"content" => text}) when is_binary(text), do: text
  defp agent_message_msg_text(%{"payload" => %{"delta" => text}}) when is_binary(text), do: text
  defp agent_message_msg_text(_msg), do: ""

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
        output |> String.trim() |> blank_fallback("origin/main")

      {:error, reason} ->
        Logger.info("ReviewAgent origin/HEAD unresolved, falling back to origin/main reason=#{inspect(reason)}")
        "origin/main"
    end
  end

  defp merge_base(workspace, comparison_base, worker_host) do
    case git(workspace, ["merge-base", comparison_base, "HEAD"], worker_host) do
      {:ok, output} ->
        output |> String.trim() |> blank_fallback(comparison_base)

      {:error, reason} ->
        Logger.info("ReviewAgent merge-base unresolved, falling back to #{comparison_base} reason=#{inspect(reason)}")

        comparison_base
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

  defp reject_runtime_error_response(text) do
    text
    |> String.trim()
    |> runtime_error_response()
  end

  defp runtime_error_response("{:error," <> _rest = text), do: {:error, {:review_agent_runtime_error, text}}
  defp runtime_error_response(_text), do: :ok

  defp isolate_json_object(text) do
    text
    |> String.replace(~r/```(?:json)?\s*/i, "")
    |> String.replace("```", "")
    |> String.trim()
    |> case do
      "" -> {:error, :empty_response}
      cleaned -> select_review_json_object(cleaned)
    end
  end

  defp select_review_json_object(text) do
    candidates = extract_objects(text)

    cond do
      candidates == [] ->
        {:error, :no_json_object}

      candidate = Enum.find(candidates, &review_json_object?/1) ->
        {:ok, candidate}

      candidate = Enum.find(candidates, &decodable_json_object?/1) ->
        {:ok, candidate}

      true ->
        {:ok, List.first(candidates)}
    end
  end

  defp review_json_object?(candidate) do
    case Jason.decode(candidate) do
      {:ok, %{"verdict" => _verdict}} -> true
      _other -> false
    end
  end

  defp decodable_json_object?(candidate) do
    match?({:ok, _decoded}, Jason.decode(candidate))
  end

  defp extract_objects(text), do: extract_objects(text, 0, [])

  defp extract_objects(text, offset, acc) when offset >= byte_size(text), do: Enum.reverse(acc)

  defp extract_objects(text, offset, acc) do
    remaining = byte_size(text) - offset

    case text |> binary_part(offset, remaining) |> :binary.match("{") do
      :nomatch ->
        Enum.reverse(acc)

      {relative_start, _len} ->
        start = offset + relative_start

        case scan_object(text, start, start, 0, false, false) do
          {candidate, end_index} -> extract_objects(text, end_index + 1, [candidate | acc])
          nil -> extract_objects(text, start + 1, acc)
        end
    end
  end

  defp scan_object(text, _start, index, _depth, _in_string?, _escape?) when index >= byte_size(text), do: nil

  defp scan_object(text, start, index, depth, in_string?, escape?) do
    text
    |> :binary.at(index)
    |> scan_object_byte(text, start, index, depth, in_string?, escape?)
  end

  defp scan_object_byte(?\\, text, start, index, depth, true, escape?),
    do: scan_object(text, start, index + 1, depth, true, !escape?)

  defp scan_object_byte(?", text, start, index, depth, true, true),
    do: scan_object(text, start, index + 1, depth, true, false)

  defp scan_object_byte(?", text, start, index, depth, true, false),
    do: scan_object(text, start, index + 1, depth, false, false)

  defp scan_object_byte(?", text, start, index, depth, false, _escape?),
    do: scan_object(text, start, index + 1, depth, true, false)

  defp scan_object_byte(?{, text, start, index, depth, false, _escape?),
    do: scan_object(text, start, index + 1, depth + 1, false, false)

  defp scan_object_byte(?}, text, start, index, 1, false, _escape?),
    do: {:binary.part(text, start, index - start + 1), index}

  defp scan_object_byte(?}, text, start, index, depth, false, _escape?),
    do: scan_object(text, start, index + 1, depth - 1, false, false)

  defp scan_object_byte(_byte, text, start, index, depth, in_string?, _escape?),
    do: scan_object(text, start, index + 1, depth, in_string?, false)

  defp coerce_verdict(verdict) when verdict in ["approve", "request_changes", "block"] do
    {:ok, String.to_existing_atom(verdict)}
  end

  defp coerce_verdict(_verdict), do: {:error, :invalid_verdict}

  defp coerce_comments(nil), do: {:ok, []}

  defp coerce_comments(comments) when is_list(comments) do
    {:ok,
     comments
     |> Enum.filter(&is_binary/1)
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))}
  end

  defp coerce_comments(_comments), do: {:error, :invalid_comments}

  defp coerce_reason(reason, :block) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :missing_block_reason}
      trimmed -> {:ok, trimmed}
    end
  end

  defp coerce_reason(_reason, :block), do: {:error, :missing_block_reason}
  defp coerce_reason(reason, _verdict) when is_binary(reason), do: {:ok, String.trim(reason)}
  defp coerce_reason(_reason, _verdict), do: {:ok, nil}

  defp validate_result(%{verdict: :request_changes, comments: []}), do: {:error, :missing_request_changes_comments}
  defp validate_result(result), do: {:ok, result}

  defp compact_result(%{reason: nil} = result), do: Map.delete(result, :reason)
  defp compact_result(result), do: result

  defp truncate(text, max_bytes) when is_binary(text) and byte_size(text) > max_bytes do
    binary_part(text, 0, max_bytes) <> "\n[... truncated by Symphony review_agent ...]"
  end

  defp truncate(text, _max_bytes), do: text

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
