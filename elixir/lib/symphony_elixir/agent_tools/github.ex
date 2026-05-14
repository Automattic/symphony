defmodule SymphonyElixir.AgentTools.GitHub do
  @moduledoc """
  Narrow GitHub operations exposed to agent prompts.

  Repository, branch, and pull request scope are derived from the Symphony
  session context. Callers cannot pass repo, remote, head, or refspec values
  through tool arguments.
  """

  alias SymphonyElixir.GitHub.PullRequest

  @pr_view_fields "number,state,title,body,url,headRefName,baseRefName"

  @type context :: %{
          optional(:issue) => map() | nil,
          optional(:issue_id) => String.t() | nil,
          optional(:comment_registry) => pid() | nil,
          optional(:command_security) => map(),
          optional(:workspace) => Path.t()
        }

  @spec get_pull_request(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_pull_request(context, opts \\ []) do
    view_current_pull_request(context, opts)
  end

  @spec create_pull_request(context(), term(), term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_pull_request(context, title, body, draft \\ false, opts \\ []) do
    with {:ok, title} <- require_string(title, :invalid_title),
         {:ok, body} <- require_string(body, :invalid_body),
         {:ok, draft?} <- normalize_draft(draft),
         {:ok, origin_repo} <- origin_repo(context),
         {:ok, branch} <- current_branch(context, opts),
         {:ok, output} <-
           PullRequest.run_gh(
             ["pr", "create", "--repo", origin_repo, "--head", branch, "--title", title, "--body", body] ++
               draft_args(draft?),
             github_opts(context, opts)
           ) do
      {:ok, %{"url" => String.trim(output), "repo" => origin_repo, "head" => branch, "draft" => draft?}}
    end
  end

  @spec update_pull_request_body(context(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_pull_request_body(context, body, opts \\ []) do
    with {:ok, body} <- require_string(body, :invalid_body),
         {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, _output} <- PullRequest.run_gh(["pr", "edit", pr_url, "--body", body], github_opts(context, opts)) do
      {:ok, %{"url" => pr_url}}
    end
  end

  @spec add_pr_comment(context(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_pr_comment(context, body, opts \\ []) do
    with {:ok, body} <- require_string(body, :invalid_body),
         {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, _output} <- PullRequest.run_gh(["pr", "comment", pr_url, "--body", body], github_opts(context, opts)) do
      {:ok, %{"url" => pr_url}}
    end
  end

  @spec push_branch(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def push_branch(context, opts \\ []) do
    with {:ok, workspace} <- workspace(context),
         {:ok, branch} <- current_branch(context, opts),
         :ok <- verify_current_origin(context, workspace, opts),
         {:ok, output} <- run_git(["push", "origin", branch], workspace, opts) do
      {:ok, %{"remote" => "origin", "branch" => branch, "output" => String.trim(output)}}
    end
  end

  @spec get_pr_checks(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_pr_checks(context, opts \\ []) do
    with {:ok, pr_url} <- current_pull_request_url(context, opts) do
      PullRequest.fetch_ci_status(pr_url, github_opts(context, opts))
    end
  end

  defp current_pull_request_url(context, opts) do
    with {:ok, pr} <- view_current_pull_request(context, opts) do
      case Map.get(pr, "url") do
        url when is_binary(url) and url != "" -> {:ok, url}
        _missing -> {:error, :missing_pull_request_url}
      end
    end
  end

  defp view_current_pull_request(context, opts) do
    with {:ok, origin_repo} <- origin_repo(context),
         {:ok, branch} <- current_branch(context, opts),
         {:ok, output} <-
           PullRequest.run_gh(
             ["pr", "view", branch, "--repo", origin_repo, "--json", @pr_view_fields],
             github_opts(context, opts)
           ),
         {:ok, pr} when is_map(pr) <- Jason.decode(output) do
      {:ok, pr}
    else
      {:ok, _decoded} -> {:error, :invalid_pull_request_payload}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_pull_request_payload, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp origin_repo(context) do
    command_security = command_security(context)
    repo = Map.get(command_security, :origin_gh_repo) || Map.get(command_security, :origin_repo)

    case repo do
      repo when is_binary(repo) and repo != "" -> {:ok, repo}
      _missing -> {:error, :missing_github_origin_repo}
    end
  end

  defp current_branch(context, opts) do
    with {:ok, workspace} <- workspace(context),
         {:ok, output} <- run_git(["branch", "--show-current"], workspace, opts) do
      case String.trim(output) do
        "" -> {:error, :missing_current_branch}
        "HEAD" -> {:error, :detached_head}
        branch -> {:ok, branch}
      end
    end
  end

  defp workspace(context) do
    workspace = Map.get(context, :workspace) || Map.get(command_security(context), :workspace)

    cond do
      is_binary(workspace) and File.dir?(workspace) -> {:ok, workspace}
      is_binary(workspace) -> {:error, :workspace_not_found}
      true -> {:error, :missing_workspace}
    end
  end

  defp command_security(context) when is_map(context), do: Map.get(context, :command_security) || %{}
  defp command_security(_context), do: %{}

  defp verify_current_origin(context, workspace, opts) do
    expected_origin_url = Map.get(command_security(context), :origin_url)

    with expected when is_binary(expected) and expected != "" <- expected_origin_url,
         {:ok, current_origin_url} <- current_origin_url(workspace, opts),
         true <- normalize_git_url(current_origin_url) == normalize_git_url(expected) do
      :ok
    else
      _reason -> {:error, :origin_url_mismatch}
    end
  end

  defp current_origin_url(workspace, opts) do
    with {:ok, output} <- run_git(["remote", "get-url", "origin"], workspace, opts),
         origin_url when is_binary(origin_url) <- output |> String.trim() |> blank_to_nil() do
      {:ok, origin_url}
    else
      _reason -> {:error, :origin_url_unavailable}
    end
  end

  defp normalize_git_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.downcase()
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      present -> present
    end
  end

  defp require_string(value, _reason) when is_binary(value), do: {:ok, value}
  defp require_string(_value, reason), do: {:error, reason}

  defp normalize_draft(value) when is_boolean(value), do: {:ok, value}
  defp normalize_draft(nil), do: {:ok, false}
  defp normalize_draft(_value), do: {:error, :invalid_draft}

  defp draft_args(true), do: ["--draft"]
  defp draft_args(false), do: []

  defp github_opts(context, opts) do
    opts
    |> Keyword.put_new(:cwd, Map.get(context, :workspace))
  end

  defp run_git(args, workspace, opts) do
    cmd_opts = [stderr_to_stdout: true, cd: workspace]

    case git_runner(opts).(args, cmd_opts) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git_failed, args, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:git_unavailable, Exception.message(error)}}
  end

  defp git_runner(opts) do
    case Keyword.get(opts, :git_runner) do
      runner when is_function(runner, 2) -> runner
      _ -> &System.cmd("git", &1, &2)
    end
  end
end
