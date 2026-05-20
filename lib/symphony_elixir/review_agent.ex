defmodule SymphonyElixir.ReviewAgent do
  @moduledoc """
  Runs a configured reviewer agent against the committed diff and parses its verdict.
  """

  require Logger

  alias SymphonyElixir.{Config, PromptSafety, SSH}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SelfReview.Context

  @max_diff_prompt_bytes 120_000

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
         {:ok, verdict} <- parse_response(raw_response) do
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
    with {:ok, json} <- isolate_json_object(text),
         {:ok, decoded} <- Jason.decode(json),
         {:ok, verdict} <- coerce_verdict(Map.get(decoded, "verdict")),
         {:ok, comments} <- coerce_comments(Map.get(decoded, "comments")),
         {:ok, reason} <- coerce_reason(Map.get(decoded, "reason"), verdict),
         {:ok, result} <- validate_result(%{verdict: verdict, comments: comments, reason: reason}) do
      {:ok, compact_result(result)}
    else
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:malformed_review_agent_response, {:invalid_json, reason}}}
      {:error, reason} -> {:error, {:malformed_review_agent_response, reason}}
    end
  end

  @spec approval_prompt(result()) :: String.t()
  def approval_prompt(_result) do
    """
    Reviewer agent approved the committed diff.

    Continue the normal workflow push and PR handoff now. Do not run another implementation pass before pushing unless a required local validation gate fails.
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
    git_range = "#{comparison_base}..HEAD"
    git_fun = fn args -> git(workspace, args, worker_host) end

    Context.build(issue, workspace, %Schema.SelfReview{}, git_range, opts, git_fun)
  end

  defp run_reviewer_agent(issue, workspace, settings, source, opts) do
    config = settings.review_agent
    reviewer_settings = reviewer_settings(settings, config)
    agent_module = Keyword.get(opts, :review_agent_module) || agent_module(config.kind)
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
          {:ok, result} -> {:ok, collected_response(result, message_collector)}
          {:error, reason} -> {:error, {:review_agent_failed, reason}}
        end
      after
        agent_module.stop_session(session)
      end
    end
  end

  defp reviewer_settings(%Schema{} = settings, %Schema.ReviewAgent{} = config) do
    %{settings | agent: %{settings.agent | kind: config.kind, command: config.command}}
  end

  defp agent_module("codex"), do: SymphonyElixir.Codex.AppServer
  defp agent_module("claude"), do: SymphonyElixir.ClaudeCode.AppServer

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

  defp collected_response(result, collector) do
    messages = drain_collected_messages(collector, [])

    [
      response_text(result),
      Enum.map_join(messages, "\n", &message_text/1)
    ]
    |> Enum.join("\n")
    |> String.trim()
  end

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
  defp message_text(%{payload: %{"result" => text}}) when is_binary(text), do: text
  defp message_text(%{payload: %{result: text}}) when is_binary(text), do: text
  defp message_text(_message), do: ""

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
      {start, _len} -> scan_object(text, start, start, 0, false, false)
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
    do: :binary.part(text, start, index - start + 1)

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
