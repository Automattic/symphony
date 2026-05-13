defmodule SymphonyElixir.AgentTools.Linear do
  @moduledoc """
  Narrow Linear operations exposed to agent prompts.

  The current issue id is supplied by Symphony session context. Callers cannot
  pass an issue id through tool arguments.
  """

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Linear.{Client, Issue}
  alias SymphonyElixir.PathSafety

  @comment_limit_default 50
  @comment_limit_max 100
  @title_max_length 120
  @related_issue_first 50

  @uuid_pattern ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  @current_issue_query """
  query SymphonyAgentCurrentIssue($id: String!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      priority
      state { id name type }
      team { id key name }
      project { id name }
      branchName
      url
      assignee { id name }
      createdAt
      updatedAt
    }
  }
  """

  @subissues_query """
  query SymphonyAgentSubissues($id: String!, $first: Int!) {
    issue(id: $id) {
      children(first: $first) {
        nodes {
          id
          identifier
          title
          state { id name type }
          url
        }
      }
    }
  }
  """

  @parent_issue_query """
  query SymphonyAgentParentIssue($id: String!) {
    issue(id: $id) {
      parent {
        id
        identifier
        title
        state { id name type }
        url
      }
    }
  }
  """

  @comments_query """
  query SymphonyAgentIssueComments($id: String!, $limit: Int!) {
    issue(id: $id) {
      comments(last: $limit, orderBy: createdAt) {
        nodes {
          id
          body
          createdAt
          updatedAt
          user { id name }
        }
      }
    }
  }
  """

  @related_issues_query """
  query SymphonyAgentRelatedIssues($id: String!, $first: Int!) {
    issue(id: $id) {
      relations(first: $first) {
        nodes {
          type
          relatedIssue {
            id
            identifier
            title
          }
        }
      }
      inverseRelations(first: $first) {
        nodes {
          type
          issue {
            id
            identifier
            title
          }
        }
      }
    }
  }
  """

  @team_states_query """
  query SymphonyAgentIssueTeamStates($id: String!) {
    issue(id: $id) {
      team {
        states {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @viewer_query """
  query SymphonyAgentViewer {
    viewer {
      id
    }
  }
  """

  @update_issue_state_mutation """
  mutation SymphonyAgentUpdateIssueState($id: String!, $stateId: String!) {
    issueUpdate(id: $id, input: { stateId: $stateId }) {
      success
      issue {
        id
        identifier
        state { id name type }
      }
    }
  }
  """

  @set_assignee_mutation """
  mutation SymphonyAgentSetIssueAssignee($id: String!, $assigneeId: String) {
    issueUpdate(id: $id, input: { assigneeId: $assigneeId }) {
      success
      issue {
        id
        identifier
        assignee { id name }
      }
    }
  }
  """

  @add_comment_mutation """
  mutation SymphonyAgentAddComment($issueId: String!, $body: String!) {
    commentCreate(input: { issueId: $issueId, body: $body }) {
      success
      comment {
        id
        body
        url
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyAgentUpdateComment($id: String!, $body: String!) {
    commentUpdate(id: $id, input: { body: $body }) {
      success
      comment {
        id
        body
        url
      }
    }
  }
  """

  @delete_comment_mutation """
  mutation SymphonyAgentDeleteComment($id: String!) {
    commentDelete(id: $id) {
      success
    }
  }
  """

  @attach_url_mutation """
  mutation SymphonyAgentAttachURL($issueId: String!, $url: String!, $title: String) {
    attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
      success
      attachment {
        id
        title
        url
      }
    }
  }
  """

  @file_upload_mutation """
  mutation SymphonyAgentFileUpload($filename: String!, $contentType: String!, $size: Int!, $makePublic: Boolean) {
    fileUpload(filename: $filename, contentType: $contentType, size: $size, makePublic: $makePublic) {
      success
      uploadFile {
        uploadUrl
        assetUrl
        headers {
          key
          value
        }
      }
    }
  }
  """

  @attachment_create_mutation """
  mutation SymphonyAgentAttachFile($issueId: String!, $url: String!, $title: String) {
    attachmentCreate(input: { issueId: $issueId, url: $url, title: $title }) {
      success
      attachment {
        id
        title
        url
      }
    }
  }
  """

  @type context :: %{
          optional(:issue) => Issue.t() | map(),
          optional(:issue_id) => String.t(),
          optional(:workspace) => Path.t(),
          optional(:comment_registry) => pid() | nil,
          optional(:command_security) => map()
        }

  @spec get_current_issue(context(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_current_issue(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@current_issue_query, %{id: issue_id}, opts) do
      fetch_path(body, ["data", "issue"], :issue_not_found)
    end
  end

  @spec get_subissues(context(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_subissues(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@subissues_query, %{id: issue_id, first: @related_issue_first}, opts) do
      fetch_path(body, ["data", "issue", "children", "nodes"], [])
    end
  end

  @spec get_parent_issue(context(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def get_parent_issue(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@parent_issue_query, %{id: issue_id}, opts) do
      {:ok, get_in(body, ["data", "issue", "parent"])}
    end
  end

  @spec get_comments(context(), integer() | nil, keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_comments(context, limit \\ @comment_limit_default, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, normalized_limit} <- normalize_limit(limit),
         {:ok, body} <- graphql(@comments_query, %{id: issue_id, limit: normalized_limit}, opts),
         {:ok, nodes} <- fetch_path(body, ["data", "issue", "comments", "nodes"], []) do
      {:ok, Enum.reverse(nodes)}
    end
  end

  @spec get_related_issues(context(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_related_issues(context, opts \\ []) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, body} <- graphql(@related_issues_query, %{id: issue_id, first: @related_issue_first}, opts),
         {:ok, issue} <- fetch_path(body, ["data", "issue"], :issue_not_found) do
      {:ok, related_issues(issue)}
    end
  end

  @spec update_state(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_state(context, state_name_or_id), do: update_state(context, state_name_or_id, [])

  @spec update_state(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_state(context, state_name_or_id, opts) when is_binary(state_name_or_id) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, state_id} <- resolve_state_id(issue_id, state_name_or_id, opts),
         {:ok, response} <- graphql(@update_issue_state_mutation, %{id: issue_id, stateId: state_id}, opts) do
      check_mutation_success(response, "issueUpdate")
    end
  end

  def update_state(_context, _state_name_or_id, _opts), do: {:error, :invalid_state}

  @spec set_assignee(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_assignee(context, assignee), do: set_assignee(context, assignee, [])

  @spec set_assignee(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def set_assignee(context, assignee, opts) when is_binary(assignee) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, assignee_id} <- resolve_assignee(assignee, opts),
         {:ok, response} <- graphql(@set_assignee_mutation, %{id: issue_id, assigneeId: assignee_id}, opts) do
      check_mutation_success(response, "issueUpdate")
    end
  end

  def set_assignee(_context, _assignee, _opts), do: {:error, :invalid_assignee}

  @spec add_comment(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def add_comment(context, body), do: add_comment(context, body, [])

  @spec add_comment(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_comment(context, body, opts) when is_binary(body) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, response} <- graphql(@add_comment_mutation, %{issueId: issue_id, body: body}, opts),
         {:ok, response} <- check_mutation_success(response, "commentCreate") do
      comment_id = get_in(response, ["data", "commentCreate", "comment", "id"])
      CommentRegistry.record(Map.get(context, :comment_registry), comment_id)
      {:ok, response}
    end
  end

  def add_comment(_context, _body, _opts), do: {:error, :invalid_comment_body}

  @spec update_comment(context(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_comment(context, comment_id, body), do: update_comment(context, comment_id, body, [])

  @spec update_comment(context(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_comment(context, comment_id, body, opts) when is_binary(comment_id) and is_binary(body) do
    with :ok <- verify_comment_owner(context, comment_id),
         {:ok, response} <- graphql(@update_comment_mutation, %{id: comment_id, body: body}, opts) do
      check_mutation_success(response, "commentUpdate")
    end
  end

  def update_comment(_context, _comment_id, _body, _opts), do: {:error, :invalid_comment}

  @spec delete_comment(context(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete_comment(context, comment_id), do: delete_comment(context, comment_id, [])

  @spec delete_comment(context(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_comment(context, comment_id, opts) when is_binary(comment_id) do
    with :ok <- verify_comment_owner(context, comment_id),
         {:ok, response} <- graphql(@delete_comment_mutation, %{id: comment_id}, opts),
         {:ok, response} <- check_mutation_success(response, "commentDelete") do
      CommentRegistry.remove(Map.get(context, :comment_registry), comment_id)
      {:ok, response}
    end
  end

  def delete_comment(_context, _comment_id, _opts), do: {:error, :invalid_comment}

  @spec attach_url(context(), String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def attach_url(context, url, title), do: attach_url(context, url, title, [])

  @spec attach_url(context(), String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def attach_url(context, url, title, opts) when is_binary(url) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, normalized_url} <- validate_url(url),
         {:ok, normalized_title} <- normalize_title(title),
         {:ok, response} <-
           graphql(@attach_url_mutation, %{issueId: issue_id, url: normalized_url, title: normalized_title}, opts) do
      check_mutation_success(response, "attachmentLinkURL")
    end
  end

  def attach_url(_context, _url, _title, _opts), do: {:error, :invalid_url}

  @spec attach_file(context(), Path.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def attach_file(context, local_path, title), do: attach_file(context, local_path, title, [])

  @spec attach_file(context(), Path.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def attach_file(context, local_path, title, opts) when is_binary(local_path) do
    with {:ok, issue_id} <- current_issue_id(context),
         {:ok, workspace} <- workspace(context),
         {:ok, path} <- validate_workspace_file(local_path, workspace),
         {:ok, normalized_title} <- normalize_title(title),
         {:ok, upload} <- request_file_upload(path, opts),
         :ok <- put_upload(path, upload, opts),
         {:ok, asset_url} <- upload_asset_url(upload),
         {:ok, response} <-
           graphql(
             @attachment_create_mutation,
             %{issueId: issue_id, url: asset_url, title: normalized_title || Path.basename(path)},
             opts
           ) do
      check_mutation_success(response, "attachmentCreate")
    end
  end

  def attach_file(_context, _local_path, _title, _opts), do: {:error, :invalid_local_path}

  defp resolve_state_id(issue_id, state_name_or_id, opts) do
    normalized = String.trim(state_name_or_id)

    cond do
      normalized == "" ->
        {:error, :invalid_state}

      Regex.match?(@uuid_pattern, normalized) ->
        {:ok, normalized}

      true ->
        lookup_state_id_by_name(issue_id, normalized, opts)
    end
  end

  defp lookup_state_id_by_name(issue_id, name, opts) do
    with {:ok, body} <- graphql(@team_states_query, %{id: issue_id}, opts),
         {:ok, states} <- fetch_path(body, ["data", "issue", "team", "states", "nodes"], []) do
      case Enum.find(states, &state_name_matches?(&1, name)) do
        %{"id" => state_id} ->
          {:ok, state_id}

        _ ->
          available = states |> Enum.map(& &1["name"]) |> Enum.reject(&is_nil/1)
          {:error, {:state_not_found, available}}
      end
    end
  end

  defp state_name_matches?(state, name) do
    String.downcase(to_string(state["name"])) == String.downcase(name)
  end

  defp resolve_assignee(assignee, opts) do
    case String.trim(assignee) do
      "self" ->
        with {:ok, body} <- graphql(@viewer_query, %{}, opts) do
          fetch_path(body, ["data", "viewer", "id"], :viewer_not_found)
        end

      ":self" ->
        resolve_assignee("self", opts)

      "unassign" ->
        {:ok, nil}

      ":unassign" ->
        {:ok, nil}

      "" ->
        {:error, :invalid_assignee}

      user_id ->
        {:ok, user_id}
    end
  end

  defp request_file_upload(path, opts) do
    with {:ok, %File.Stat{size: size}} <- file_stat(path),
         {:ok, body} <-
           graphql(
             @file_upload_mutation,
             %{filename: Path.basename(path), contentType: content_type(path), size: size, makePublic: true},
             opts
           ),
         {:ok, upload_file} <- fetch_path(body, ["data", "fileUpload", "uploadFile"], :upload_not_available) do
      case get_in(body, ["data", "fileUpload", "success"]) do
        false -> {:error, {:linear_mutation_failed, "fileUpload", body}}
        _ -> {:ok, upload_file}
      end
    end
  end

  defp put_upload(path, %{"uploadUrl" => upload_url} = upload, opts) when is_binary(upload_url) do
    upload_client = Keyword.get(opts, :upload_client, &Req.put/2)

    headers =
      upload
      |> Map.get("headers", [])
      |> Enum.map(fn %{"key" => key, "value" => value} -> {key, value} end)

    with {:ok, contents} <- file_read(path) do
      case upload_client.(upload_url, headers: headers, body: contents) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        {:ok, %{status: status, body: body}} -> {:error, {:file_upload_status, status, body}}
        {:error, reason} -> {:error, {:file_upload_failed, reason}}
      end
    end
  end

  defp put_upload(_path, _upload, _opts), do: {:error, :upload_url_missing}

  defp file_stat(path) do
    case File.stat(path) do
      {:ok, %File.Stat{} = stat} -> {:ok, stat}
      {:error, reason} -> {:error, {:file_stat_failed, reason}}
    end
  end

  defp file_read(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:file_read_failed, reason}}
    end
  end

  defp upload_asset_url(%{"assetUrl" => asset_url}) when is_binary(asset_url) and asset_url != "", do: {:ok, asset_url}
  defp upload_asset_url(_upload), do: {:error, :asset_url_missing}

  defp content_type(path), do: MIME.from_path(path)

  defp related_issues(issue) do
    relations =
      issue
      |> Map.get("relations", %{})
      |> Map.get("nodes", [])
      |> Enum.flat_map(&related_issue_from_relation(&1, "relation"))

    inverse_relations =
      issue
      |> Map.get("inverseRelations", %{})
      |> Map.get("nodes", [])
      |> Enum.flat_map(&related_issue_from_relation(&1, "inverse_relation"))

    relations ++ inverse_relations
  end

  defp related_issue_from_relation(%{"type" => type} = relation, direction) do
    if block_relation?(type) do
      issue = Map.get(relation, "relatedIssue") || Map.get(relation, "issue")

      case issue do
        %{} ->
          [
            %{
              "relation" => direction,
              "type" => type,
              "id" => issue["id"],
              "identifier" => issue["identifier"],
              "title" => issue["title"]
            }
          ]

        _ ->
          []
      end
    else
      []
    end
  end

  defp related_issue_from_relation(_relation, _direction), do: []

  defp block_relation?(type) when is_binary(type) do
    type
    |> String.downcase()
    |> String.contains?("block")
  end

  defp block_relation?(_type), do: false

  defp verify_comment_owner(context, comment_id) do
    if CommentRegistry.owned?(Map.get(context, :comment_registry), comment_id) do
      :ok
    else
      {:error, :comment_not_owned_by_run}
    end
  end

  defp normalize_limit(nil), do: {:ok, @comment_limit_default}

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 do
    {:ok, min(limit, @comment_limit_max)}
  end

  defp normalize_limit(_limit), do: {:error, :invalid_limit}

  defp validate_url(url) do
    trimmed = String.trim(url)
    uri = URI.parse(trimmed)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      {:ok, trimmed}
    else
      {:error, :invalid_url}
    end
  end

  defp normalize_title(nil), do: {:ok, nil}

  defp normalize_title(title) when is_binary(title) do
    trimmed = String.trim(title)

    cond do
      trimmed == "" -> {:ok, nil}
      String.length(trimmed) <= @title_max_length -> {:ok, trimmed}
      true -> {:error, :title_too_long}
    end
  end

  defp normalize_title(_title), do: {:error, :invalid_title}

  defp validate_workspace_file(local_path, workspace) do
    expanded_path = Path.expand(local_path, workspace)

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_path} <- PathSafety.canonicalize(expanded_path),
         :ok <- ensure_inside_workspace(canonical_path, canonical_workspace),
         :ok <- ensure_regular_file(canonical_path) do
      {:ok, canonical_path}
    end
  end

  defp ensure_inside_workspace(path, workspace) do
    workspace_prefix = workspace <> "/"

    if path == workspace or String.starts_with?(path, workspace_prefix) do
      :ok
    else
      {:error, :path_outside_workspace}
    end
  end

  defp ensure_regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, {:file_stat_failed, reason}}
    end
  end

  defp current_issue_id(%{issue_id: issue_id}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp current_issue_id(%{issue: %Issue{id: issue_id}}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp current_issue_id(%{issue: %{id: issue_id}}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp current_issue_id(%{issue: %{"id" => issue_id}}) when is_binary(issue_id) and issue_id != "", do: {:ok, issue_id}
  defp current_issue_id(_context), do: {:error, :missing_current_issue}

  defp workspace(%{workspace: workspace}) when is_binary(workspace) and workspace != "", do: {:ok, workspace}
  defp workspace(_context), do: {:error, :missing_workspace}

  defp graphql(query, variables, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, body} <- linear_client.(query, variables, []) do
      case body do
        %{"errors" => errors} when is_list(errors) and errors != [] -> {:error, {:linear_graphql_errors, errors}}
        %{errors: errors} when is_list(errors) and errors != [] -> {:error, {:linear_graphql_errors, errors}}
        body -> {:ok, body}
      end
    end
  end

  defp check_mutation_success(response, field) do
    case get_in(response, ["data", field, "success"]) do
      false -> {:error, {:linear_mutation_failed, field, response}}
      _ -> {:ok, response}
    end
  end

  defp fetch_path(body, path, default_or_error) do
    case get_in(body, path) do
      nil when is_list(default_or_error) -> {:ok, default_or_error}
      nil -> {:error, default_or_error}
      value -> {:ok, value}
    end
  end
end
