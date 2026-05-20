defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{AgentLabels, Config, PromptSafety, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    raw_reviewer_comments = normalize_reviewer_comments(Keyword.get(opts, :reviewer_comments, []))
    reviewer_comments = sanitize_reviewer_comments(raw_reviewer_comments)
    raw_ci_failure = Keyword.get(opts, :ci_failure)
    ci_failure = normalize_ci_failure(raw_ci_failure)
    linear_input_warnings = linear_input_warnings(issue, raw_reviewer_comments, raw_ci_failure)
    {repo_key, workflow_source} = repo_context_for_prompt(issue, opts)
    agent_context = agent_context_for_prompt(opts, workflow_source)

    template =
      workflow_for_prompt(workflow_source)
      |> prompt_template!()
      |> default_prompt(workflow_source)
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "agent" => to_solid_value(agent_context),
        "repo_key" => repo_key,
        "issue" => issue |> prompt_issue_map(repo_key) |> to_solid_map(),
        "reviewer_comments" => to_solid_value(reviewer_comments),
        "ci_failure" => to_solid_value(ci_failure)
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> append_extra_prompt(Keyword.get(opts, :extra_prompt) || Keyword.get(opts, :prompt_context))
    |> append_reviewer_comments(reviewer_comments)
    |> append_ci_failure(ci_failure)
    |> append_review_agent_instructions(Keyword.get(opts, :settings))
    |> append_linear_input_warnings(linear_input_warnings)
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: prompt

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp prompt_issue_map(%_{} = issue, repo_key) do
    issue
    |> Map.from_struct()
    |> sanitize_issue_map(repo_key)
  end

  defp prompt_issue_map(issue, repo_key) when is_map(issue), do: sanitize_issue_map(issue, repo_key)

  defp sanitize_issue_map(issue, repo_key) when is_map(issue) do
    issue
    |> update_string_field(:title, &PromptSafety.linear_issue_title/1)
    |> update_string_field(:description, &PromptSafety.linear_issue_body/1)
    |> update_list_field(:comments, &sanitize_issue_comments/1)
    |> update_list_field(:linked_issues, &sanitize_linked_issues/1)
    |> put_repo_key(repo_key)
  end

  defp sanitize_issue_comments(comments) when is_list(comments) do
    Enum.map(comments, &sanitize_issue_comment/1)
  end

  defp sanitize_issue_comment(comment) when is_map(comment) do
    update_string_field(comment, :body, &PromptSafety.linear_issue_comment_body/1)
  end

  defp sanitize_issue_comment(comment), do: comment

  defp sanitize_linked_issues(linked_issues) when is_list(linked_issues) do
    Enum.map(linked_issues, &sanitize_linked_issue/1)
  end

  defp sanitize_linked_issue(linked_issue) when is_map(linked_issue) do
    linked_issue
    |> update_string_field(:title, &PromptSafety.linear_issue_title/1)
    |> update_string_field(:state, &PromptSafety.linear_issue_state/1)
  end

  defp sanitize_linked_issue(linked_issue), do: linked_issue

  defp sanitize_reviewer_comments(comments) when is_list(comments) do
    Enum.map(comments, fn comment ->
      update_string_field(comment, :body, &PromptSafety.linear_reviewer_comment_body/1)
    end)
  end

  defp linear_input_warnings(issue, reviewer_comments, ci_failure) do
    issue
    |> issue_warning_sources()
    |> Kernel.++(reviewer_comment_warning_sources(reviewer_comments))
    |> Kernel.++(ci_failure_warning_sources(ci_failure))
    |> PromptSafety.warning_fields()
  end

  defp issue_warning_sources(%_{} = issue), do: issue |> Map.from_struct() |> issue_warning_sources()

  defp issue_warning_sources(issue) when is_map(issue) do
    [
      {"issue.title", get_field(issue, :title)},
      {"issue.description", get_field(issue, :description)}
    ] ++
      issue_comment_warning_sources(get_field(issue, :comments)) ++
      linked_issue_warning_sources(get_field(issue, :linked_issues))
  end

  defp issue_comment_warning_sources(comments) when is_list(comments) do
    comments
    |> Enum.with_index(1)
    |> Enum.map(fn {comment, index} -> {"issue.comments[#{index}].body", get_field(comment, :body)} end)
  end

  defp issue_comment_warning_sources(_comments), do: []

  defp linked_issue_warning_sources(linked_issues) when is_list(linked_issues) do
    linked_issues
    |> Enum.with_index(1)
    |> Enum.map(fn {linked_issue, index} -> {"issue.linked_issues[#{index}].title", get_field(linked_issue, :title)} end)
  end

  defp linked_issue_warning_sources(_linked_issues), do: []

  defp reviewer_comment_warning_sources(comments) when is_list(comments) do
    comments
    |> Enum.with_index(1)
    |> Enum.map(fn {comment, index} -> {"reviewer_comments[#{index}].body", get_field(comment, :body)} end)
  end

  defp ci_failure_warning_sources(ci_failure) when is_map(ci_failure) do
    [{"ci_failure.log_excerpt", get_field(ci_failure, :log_excerpt)}]
  end

  defp ci_failure_warning_sources(_ci_failure), do: []

  defp default_prompt(prompt, workflow_source) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      fallback_prompt(workflow_source)
    else
      prompt
    end
  end

  defp workflow_for_prompt({:repo, repo_key}), do: Config.workflow_for_repo(repo_key)
  defp workflow_for_prompt(:current), do: Workflow.current()

  defp fallback_prompt({:repo, repo_key}), do: Config.workflow_prompt(repo_key)
  defp fallback_prompt(:current), do: Config.workflow_prompt()

  defp agent_context_for_prompt(opts, workflow_source) do
    agent_kind = agent_kind_from_opts(opts) || agent_kind_from_workflow_source(workflow_source)

    AgentLabels.prompt_context(agent_kind)
  end

  defp agent_kind_from_opts(opts) do
    present_string(Keyword.get(opts, :agent_kind)) ||
      agent_kind_from_settings(Keyword.get(opts, :settings))
  end

  defp agent_kind_from_workflow_source({:repo, repo_key}) do
    case Config.settings_for_repo(repo_key) do
      {:ok, settings} -> agent_kind_from_settings(settings)
      {:error, _reason} -> nil
    end
  end

  defp agent_kind_from_workflow_source(:current) do
    case Config.settings() do
      {:ok, settings} -> agent_kind_from_settings(settings)
      {:error, _reason} -> nil
    end
  end

  defp agent_kind_from_settings(%{agent: %{kind: kind}}), do: present_string(kind)
  defp agent_kind_from_settings(_settings), do: nil

  defp append_extra_prompt(prompt, extra_prompt) when is_binary(extra_prompt) do
    case String.trim(extra_prompt) do
      "" -> prompt
      trimmed -> prompt <> "\n\n" <> trimmed
    end
  end

  defp append_extra_prompt(prompt, _extra_prompt), do: prompt

  defp repo_context_for_prompt(issue, opts) do
    explicit_repo_key = present_string(Keyword.get(opts, :repo_key))
    issue_repo_key = repo_key_from_issue(issue)
    default_repo_key = default_repo_key()

    cond do
      explicit_repo_key ->
        {explicit_repo_key, {:repo, explicit_repo_key}}

      issue_repo_key ->
        {issue_repo_key, {:repo, issue_repo_key}}

      default_repo_key ->
        {default_repo_key, :current}

      true ->
        {nil, :current}
    end
  end

  defp repo_key_from_issue(%_{} = issue), do: issue |> Map.from_struct() |> repo_key_from_issue()
  defp repo_key_from_issue(%{repo_key: repo_key}), do: present_string(repo_key)
  defp repo_key_from_issue(%{"repo_key" => repo_key}), do: present_string(repo_key)
  defp repo_key_from_issue(_issue), do: nil

  defp put_repo_key(issue, nil), do: issue
  defp put_repo_key(issue, repo_key) when is_map(issue), do: Map.put(issue, :repo_key, repo_key)

  defp default_repo_key, do: Config.repo_key_or_nil()

  defp append_reviewer_comments(prompt, []), do: prompt

  defp append_reviewer_comments(prompt, comments) when is_list(comments) do
    prompt <> "\n\n" <> reviewer_comments_section(comments)
  end

  defp append_ci_failure(prompt, nil), do: prompt

  defp append_ci_failure(prompt, ci_failure) when is_map(ci_failure) do
    prompt <> "\n\n" <> ci_failure_section(ci_failure)
  end

  defp append_review_agent_instructions(prompt, %{review_agent: %{enabled: true}}) do
    prompt <>
      """

      Review-agent gate:

      - After implementation, validation, commit, and committed-diff review are complete, stop before `git push`.
      - Do not push, open a PR, or move the issue to review until Symphony injects the reviewer-agent verdict.
      - If the reviewer requests changes, address those comments in the same workspace and stop before push again.
      - If the reviewer approves, follow the injected continuation prompt and complete the normal push/PR handoff.
      """
  end

  defp append_review_agent_instructions(prompt, _settings), do: prompt

  defp append_linear_input_warnings(prompt, []), do: prompt

  defp append_linear_input_warnings(prompt, warnings) when is_list(warnings) do
    prompt <> "\n\n" <> PromptSafety.warning_section(warnings)
  end

  defp ci_failure_section(ci_failure) do
    failed_checks =
      ci_failure
      |> Map.get(:failed_checks, [])
      |> Enum.map_join(", ", fn %{name: name} -> name end)

    [
      "CI failure:",
      "",
      "Failed checks: #{blank_fallback(failed_checks, "unknown")}",
      "Commit SHA: #{blank_fallback(Map.get(ci_failure, :commit_sha), "unknown")}",
      "",
      "Failed log excerpt:",
      "BEGIN UNTRUSTED CI LOG",
      blank_fallback(Map.get(ci_failure, :log_excerpt), "No failed log output was available."),
      "END UNTRUSTED CI LOG"
    ]
    |> Enum.join("\n")
  end

  defp reviewer_comments_section(comments) do
    entries =
      comments
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {comment, index} ->
        [
          "#{index}. #{comment_header(comment)}",
          Map.fetch!(comment, :body)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
      end)

    "Unaddressed reviewer comments:\n\n" <> entries
  end

  defp comment_header(comment) when is_map(comment) do
    [
      comment_author(comment),
      comment_kind(comment),
      comment_location(comment),
      comment_url(comment)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp comment_author(%{author: author}) when is_binary(author) and author != "", do: "#{author}:"
  defp comment_author(_comment), do: "Reviewer:"

  defp comment_kind(%{kind: kind}) when is_binary(kind) and kind != "", do: "[#{kind}]"
  defp comment_kind(_comment), do: nil

  defp comment_location(%{path: path, line: line}) when is_binary(path) and is_integer(line), do: "#{path}:#{line}"
  defp comment_location(%{path: path}) when is_binary(path), do: path
  defp comment_location(_comment), do: nil

  defp comment_url(%{url: url}) when is_binary(url) and url != "", do: url
  defp comment_url(_comment), do: nil

  defp normalize_reviewer_comments(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_reviewer_comment/1)
    |> Enum.reject(&(String.trim(Map.get(&1, :body, "")) == ""))
  end

  defp normalize_reviewer_comments(_comments), do: []

  defp normalize_reviewer_comment(comment) when is_map(comment) do
    %{
      id: string_field(comment, :id),
      kind: string_field(comment, :kind),
      author: string_field(comment, :author),
      body: string_field(comment, :body) || "",
      url: string_field(comment, :url),
      path: string_field(comment, :path),
      line: integer_field(comment, :line),
      created_at: Map.get(comment, :created_at) || Map.get(comment, "created_at"),
      updated_at: Map.get(comment, :updated_at) || Map.get(comment, "updated_at")
    }
  end

  defp normalize_reviewer_comment(_comment), do: %{body: ""}

  defp normalize_ci_failure(ci_failure) when is_map(ci_failure) do
    failed_checks =
      ci_failure
      |> Map.get(:failed_checks, Map.get(ci_failure, "failed_checks", []))
      |> normalize_ci_checks()

    log_excerpt = string_field(ci_failure, :log_excerpt) || ""
    commit_sha = string_field(ci_failure, :commit_sha)

    if failed_checks == [] and String.trim(log_excerpt) == "" and is_nil(commit_sha) do
      nil
    else
      %{
        failed_checks: failed_checks,
        commit_sha: commit_sha,
        log_excerpt: PromptSafety.ci_failure_log_excerpt(log_excerpt)
      }
    end
  end

  defp normalize_ci_failure(_ci_failure), do: nil

  defp normalize_ci_checks(checks) when is_list(checks) do
    checks
    |> Enum.map(&normalize_ci_check/1)
    |> Enum.reject(fn %{name: name} -> name == "" end)
  end

  defp normalize_ci_checks(_checks), do: []

  defp normalize_ci_check(check) when is_map(check) do
    %{
      name: string_field(check, :name) || "",
      conclusion: string_field(check, :conclusion),
      run_id: string_field(check, :run_id)
    }
  end

  defp normalize_ci_check(check) when is_binary(check), do: %{name: check}
  defp normalize_ci_check(_check), do: %{name: ""}

  defp blank_fallback(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp blank_fallback(_value, fallback), do: fallback

  defp string_field(map, key) when is_map(map) and is_atom(key) do
    case get_field(map, key) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp integer_field(map, key) when is_map(map) and is_atom(key) do
    case get_field(map, key) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_value), do: nil

  defp update_string_field(map, key, fun) when is_map(map) and is_atom(key) do
    update_field(map, key, fn
      value when is_binary(value) -> fun.(value)
      value -> value
    end)
  end

  defp update_list_field(map, key, fun) when is_map(map) and is_atom(key) do
    update_field(map, key, fn
      value when is_list(value) -> fun.(value)
      value -> value
    end)
  end

  defp update_field(map, key, fun) when is_map(map) and is_atom(key) do
    string_key = to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.update!(map, key, fun)
      Map.has_key?(map, string_key) -> Map.update!(map, string_key, fun)
      true -> map
    end
  end

  defp get_field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp get_field(_map, _key), do: nil
end
