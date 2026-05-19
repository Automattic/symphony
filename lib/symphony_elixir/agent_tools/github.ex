defmodule SymphonyElixir.AgentTools.GitHub do
  @moduledoc """
  Narrow GitHub operations exposed to agent prompts.

  Repository, branch, and pull request scope are derived from the Symphony
  session context. Callers cannot pass repo, remote, head, or refspec values
  through tool arguments.
  """

  alias SymphonyElixir.AgentTools.SecretScanner
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHub.PullRequest
  alias SymphonyElixir.Workspace

  @pr_view_fields "number,state,title,body,url,headRefName,baseRefName"
  @default_failed_run_log_max_bytes 65_536
  @failed_conclusions MapSet.new(["ACTION_REQUIRED", "CANCELLED", "FAILURE", "STARTUP_FAILURE", "TIMED_OUT"])

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
         :ok <-
           SecretScanner.reject_fields_if_secret_pattern(
             [body: body, title: title],
             context,
             "github_create_pull_request",
             opts
           ),
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
         :ok <- SecretScanner.reject_fields_if_secret_pattern([body: body], context, "github_update_pull_request_body", opts),
         {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, _output} <- PullRequest.run_gh(["pr", "edit", pr_url, "--body", body], github_opts(context, opts)) do
      {:ok, %{"url" => pr_url}}
    end
  end

  @spec add_pr_comment(context(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_pr_comment(context, body, opts \\ []) do
    with {:ok, body} <- require_string(body, :invalid_body),
         :ok <- SecretScanner.reject_fields_if_secret_pattern([body: body], context, "github_add_pr_comment", opts),
         {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, _output} <- PullRequest.run_gh(["pr", "comment", pr_url, "--body", body], github_opts(context, opts)) do
      {:ok, %{"url" => pr_url}}
    end
  end

  @spec push_branch(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def push_branch(context, opts \\ []) do
    if ssh_worker?(context) do
      {:error, {:unsupported_for_ssh_worker, :github_push_branch}}
    else
      with {:ok, workspace} <- workspace(context),
           {:ok, branch} <- current_branch(context, opts),
           :ok <- verify_current_origin(context, workspace, opts),
           {:ok, output} <- run_git(["push", "origin", branch], workspace, opts) do
        {:ok, %{"remote" => "origin", "branch" => branch, "output" => String.trim(output)}}
      end
    end
  end

  @spec get_pr_checks(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_pr_checks(context, opts \\ []) do
    with {:ok, pr_url} <- current_pull_request_url(context, opts) do
      PullRequest.fetch_ci_status(pr_url, github_opts(context, opts))
    end
  end

  @spec list_pr_comments(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_pr_comments(context, opts \\ []) do
    with {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, comments} <- PullRequest.fetch_pr_comments(pr_url, github_opts(context, opts)) do
      {:ok, %{"pr_url" => pr_url, "comments" => comments}}
    end
  end

  @spec list_pr_review_comments(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_pr_review_comments(context, opts \\ []) do
    with {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, comments} <- PullRequest.fetch_pr_review_comments(pr_url, github_opts(context, opts)) do
      {:ok, %{"pr_url" => pr_url, "comments" => comments}}
    end
  end

  @spec list_pr_reviews(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_pr_reviews(context, opts \\ []) do
    with {:ok, pr_url} <- current_pull_request_url(context, opts),
         {:ok, reviews} <- PullRequest.fetch_pr_reviews(pr_url, github_opts(context, opts)) do
      {:ok, %{"pr_url" => pr_url, "reviews" => reviews}}
    end
  end

  @spec get_failed_run_log(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_failed_run_log(context, opts \\ []) do
    with {:ok, status} <- get_pr_checks(context, opts),
         {:ok, check} <- latest_failed_check(Map.get(status, :checks, [])),
         {:ok, run_id} <- check_run_id(check),
         {:ok, log} <- PullRequest.fetch_failed_log(run_id, github_opts(context, opts)),
         {:ok, max_bytes} <- failed_run_log_max_bytes(opts) do
      {excerpt, truncated?} = clamp_log(log, max_bytes)

      {:ok,
       %{
         "pr_url" => Map.get(status, :pr_url),
         "check" => check,
         "run_id" => run_id,
         "log" => excerpt,
         "truncated" => truncated?,
         "max_bytes" => max_bytes
       }}
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
    case captured_current_branch(context) do
      {:ok, branch} ->
        {:ok, branch}

      {:error, _reason} = error ->
        error

      :missing ->
        current_branch_from_workspace(context, opts)
    end
  end

  defp captured_current_branch(context) do
    case command_security(context) |> Map.get(:current_branch) do
      branch when is_binary(branch) ->
        normalize_branch(branch)

      _missing ->
        :missing
    end
  end

  defp current_branch_from_workspace(context, opts) do
    with {:ok, workspace} <- workspace(context),
         {:ok, output} <- run_git(["branch", "--show-current"], workspace, opts) do
      normalize_branch(output)
    end
  end

  defp normalize_branch(branch) when is_binary(branch) do
    case String.trim(branch) do
      "" -> {:error, :missing_current_branch}
      "HEAD" -> {:error, :detached_head}
      branch -> {:ok, branch}
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

  defp ssh_worker?(context) do
    case Map.get(command_security(context), :worker_host) do
      worker_host when is_binary(worker_host) and worker_host != "" -> true
      _worker_host -> false
    end
  end

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

  defp latest_failed_check(checks) when is_list(checks) do
    checks
    |> Enum.filter(&failed_check?/1)
    |> Enum.find(&present?(Map.get(&1, :run_id) || Map.get(&1, "run_id")))
    |> case do
      nil -> {:error, :no_failed_github_actions_run}
      check -> {:ok, check}
    end
  end

  defp latest_failed_check(_checks), do: {:error, :no_failed_github_actions_run}

  defp failed_check?(check) when is_map(check) do
    conclusion = Map.get(check, :conclusion) || Map.get(check, "conclusion")
    MapSet.member?(@failed_conclusions, normalize_status_value(conclusion))
  end

  defp failed_check?(_check), do: false

  defp check_run_id(check) when is_map(check) do
    case Map.get(check, :run_id) || Map.get(check, "run_id") do
      run_id when is_binary(run_id) and run_id != "" -> {:ok, run_id}
      run_id when is_integer(run_id) -> {:ok, Integer.to_string(run_id)}
      _missing -> {:error, :no_failed_github_actions_run}
    end
  end

  defp check_run_id(_check), do: {:error, :no_failed_github_actions_run}

  defp normalize_status_value(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp normalize_status_value(_value), do: nil

  defp failed_run_log_max_bytes(opts) do
    case Keyword.get(opts, :failed_run_log_max_bytes) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      nil ->
        {:ok, settings_failed_run_log_max_bytes(opts)}

      _invalid ->
        {:error, :invalid_failed_run_log_max_bytes}
    end
  end

  defp settings_failed_run_log_max_bytes(opts) do
    case Keyword.get(opts, :settings) do
      %Schema{} = settings -> settings.github.failed_run_log_max_bytes
      _settings -> config_failed_run_log_max_bytes()
    end
  end

  defp config_failed_run_log_max_bytes do
    Config.settings!().github.failed_run_log_max_bytes
  rescue
    _error -> @default_failed_run_log_max_bytes
  end

  defp clamp_log(log, max_bytes) when is_binary(log) and byte_size(log) > max_bytes do
    {take_valid_prefix(log, max_bytes), true}
  end

  defp clamp_log(log, _max_bytes) when is_binary(log), do: {log, false}
  defp clamp_log(_log, _max_bytes), do: {"", false}

  defp take_valid_prefix(_log, max_bytes) when max_bytes <= 0, do: ""

  defp take_valid_prefix(log, max_bytes) do
    prefix = binary_part(log, 0, min(byte_size(log), max_bytes))

    if String.valid?(prefix) do
      prefix
    else
      take_valid_prefix(log, max_bytes - 1)
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_integer(value), do: true
  defp present?(_value), do: false

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
      _ -> &Workspace.safe_git/2
    end
  end
end
