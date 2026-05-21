defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Deterministic issue workpad bootstrap before the first agent turn.
  """

  alias SymphonyElixir.{AgentLabels, AgentTools, Config, Linear.Issue, Tracker}

  @in_progress_state "In Progress"
  @todo_state "todo"
  @comment_limit 100

  @type bootstrap_result :: {:ok, Issue.t()} | {:error, term()}

  @spec bootstrap(Issue.t(), Path.t()) :: bootstrap_result()
  def bootstrap(%Issue{} = issue, workspace), do: bootstrap(issue, workspace, [])

  @spec bootstrap(Issue.t(), Path.t(), keyword()) :: bootstrap_result()
  def bootstrap(%Issue{} = issue, workspace, opts) when is_binary(workspace) do
    if pr_mode?(opts) do
      {:ok, issue}
    else
      with {:ok, issue} <- ensure_in_progress(issue) do
        ensure_workpad(issue, workspace, opts)
      end
    end
  end

  @spec bootstrap_body(String.t(), Path.t()) :: String.t()
  def bootstrap_body(heading, workspace), do: bootstrap_body(heading, workspace, [])

  @spec bootstrap_body(String.t(), Path.t(), keyword()) :: String.t()
  def bootstrap_body(heading, workspace, opts) when is_binary(heading) and is_binary(workspace) do
    timestamp = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.to_iso8601()

    """
    #{heading}

    ```text
    #{environment_stamp(workspace, opts)}
    ```

    ### Plan

    - [ ] Reconcile this bootstrap workpad with the Linear issue before implementation.

    ### Acceptance Criteria

    - [ ] Derived from the Linear issue description and comments.

    ### Validation

    - [ ] targeted tests: `<pending>`

    ### Notes

    - #{timestamp} - Symphony created this bootstrap workpad before the first agent turn.

    ### Confusions
    """
  end

  defp pr_mode?(opts), do: Keyword.get(opts, :prompt_mode) in [:pr, "pr"]

  defp todo_state?(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
    |> Kernel.==(@todo_state)
  end

  defp todo_state?(_state), do: false

  defp ensure_in_progress(%Issue{id: issue_id, state: state} = issue) when is_binary(issue_id) do
    if todo_state?(state) do
      case Tracker.update_issue_state(issue_id, @in_progress_state) do
        :ok ->
          {:ok, %{issue | state: @in_progress_state}}

        {:error, reason} ->
          {:error, {:workpad_bootstrap_state_update_failed, reason}}
      end
    else
      {:ok, issue}
    end
  end

  defp ensure_in_progress(%Issue{} = issue), do: {:ok, issue}

  defp ensure_workpad(%Issue{} = issue, workspace, opts) do
    settings = Keyword.get(opts, :settings) || Config.settings!()
    heading = agent_workpad_heading(settings)

    cond do
      existing_workpad_comment?(issue.comments) ->
        {:ok, issue}

      linear_tracker?(settings) ->
        ensure_linear_workpad(issue, workspace, heading, opts)

      true ->
        create_tracker_workpad(issue, workspace, heading, opts)
    end
  end

  defp ensure_linear_workpad(issue, workspace, heading, opts) do
    context = %{issue: issue, workspace: workspace}

    with {:ok, comments} <- AgentTools.Linear.get_comments(context, @comment_limit, linear_opts(opts)),
         false <- existing_workpad_comment?(comments),
         {:ok, issue} <- create_linear_workpad(issue, workspace, heading, opts) do
      {:ok, issue}
    else
      true -> {:ok, issue}
      {:error, reason} -> {:error, {:workpad_bootstrap_comment_failed, reason}}
    end
  end

  defp create_linear_workpad(issue, workspace, heading, opts) do
    body = bootstrap_body(heading, workspace, opts)

    case AgentTools.Linear.add_comment(%{issue: issue, workspace: workspace}, body, linear_opts(opts)) do
      {:ok, _response} ->
        {:ok, put_bootstrap_comment(issue, heading, body, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_tracker_workpad(%Issue{id: issue_id} = issue, workspace, heading, opts) when is_binary(issue_id) do
    body = bootstrap_body(heading, workspace, opts)

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        {:ok, put_bootstrap_comment(issue, heading, body, opts)}

      {:error, reason} ->
        {:error, {:workpad_bootstrap_comment_failed, reason}}
    end
  end

  defp create_tracker_workpad(issue, _workspace, _heading, _opts), do: {:ok, issue}

  defp put_bootstrap_comment(%Issue{} = issue, heading, body, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    author = heading |> String.trim_leading("#") |> String.trim() |> String.replace_suffix(" Workpad", "")
    comment = %{author: author, body: body, created_at: now}

    %{issue | comments: [comment | normalized_comments(issue.comments)]}
  end

  defp normalized_comments(comments) when is_list(comments), do: comments
  defp normalized_comments(_comments), do: []

  defp existing_workpad_comment?(comments) when is_list(comments) do
    Enum.any?(comments, fn comment ->
      comment
      |> comment_body()
      |> workpad_body?()
    end)
  end

  defp existing_workpad_comment?(_comments), do: false

  defp comment_body(%{"body" => body}) when is_binary(body), do: body
  defp comment_body(%{body: body}) when is_binary(body), do: body
  defp comment_body(_comment), do: nil

  defp workpad_body?(body) when is_binary(body) do
    Enum.any?(AgentLabels.known_workpad_markers(), &String.contains?(body, &1))
  end

  defp workpad_body?(_body), do: false

  defp agent_workpad_heading(%{agent: %{kind: kind}}), do: AgentLabels.workpad_heading(kind)
  defp agent_workpad_heading(_settings), do: AgentLabels.workpad_heading(nil)

  defp linear_tracker?(%{tracker: %{kind: kind}}), do: to_string(kind) == "linear"
  defp linear_tracker?(_settings), do: false

  defp linear_opts(opts) do
    Keyword.take(opts, [:linear_client, :settings])
  end

  defp environment_stamp(workspace, opts) do
    "#{worker_host(opts)}:#{workspace_path(workspace, opts)}@#{short_sha(workspace, opts)}"
  end

  defp workspace_path(workspace, opts) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) and host != "" -> workspace
      _ -> Path.expand(workspace)
    end
  end

  defp worker_host(opts) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) and host != "" -> host
      _ -> local_hostname()
    end
  end

  defp local_hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

  defp short_sha(_workspace, opts) do
    case Keyword.fetch(opts, :short_sha) do
      {:ok, sha} when is_binary(sha) and sha != "" -> sha
      _ -> "unknown"
    end
  end
end
