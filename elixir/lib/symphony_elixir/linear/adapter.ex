defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, Issue}

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @add_label_mutation """
  mutation SymphonyAddIssueLabel($issueId: String!, $labelIds: [String!]!) {
    issueUpdate(id: $issueId, input: {addedLabelIds: $labelIds}) {
      success
    }
  }
  """

  @remove_label_mutation """
  mutation SymphonyRemoveIssueLabel($issueId: String!, $labelIds: [String!]!) {
    issueUpdate(id: $issueId, input: {removedLabelIds: $labelIds}) {
      success
    }
  }
  """

  @issue_label_lookup_query """
  query SymphonyResolveIssueLabel($issueId: String!, $labelName: String!) {
    issue(id: $issueId) {
      team {
        id
      }
      labels {
        nodes {
          id
          name
        }
      }
    }
    issueLabels(filter: {name: {eq: $labelName}}, first: 20) {
      nodes {
        id
        name
        team {
          id
        }
      }
    }
  }
  """

  @create_issue_label_mutation """
  mutation SymphonyCreateIssueLabel($name: String!, $teamId: String!) {
    issueLabelCreate(input: {name: $name, teamId: $teamId}) {
      success
      issueLabel {
        id
      }
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec enrich_issue(Issue.t()) :: {:ok, Issue.t()} | {:error, term()}
  def enrich_issue(issue), do: client_module().fetch_issue_enrichment(issue)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec add_label(String.t(), String.t()) :: :ok | {:error, term()}
  def add_label(issue_id, label_name) when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, label_id} <- resolve_or_create_label_id(issue_id, label_name),
         {:ok, response} <-
           client_module().graphql(@add_label_mutation, %{issueId: issue_id, labelIds: [label_id]}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :label_add_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_add_failed}
    end
  end

  def add_label(_issue_id, _label_name), do: {:error, :invalid_label}

  @spec remove_label(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_label(issue_id, label_name) when is_binary(issue_id) and is_binary(label_name) do
    with {:ok, label_id} <- resolve_existing_issue_label_id(issue_id, label_name),
         {:ok, response} <-
           client_module().graphql(@remove_label_mutation, %{issueId: issue_id, labelIds: [label_id]}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      :missing -> :ok
      false -> {:error, :label_remove_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_remove_failed}
    end
  end

  def remove_label(_issue_id, _label_name), do: {:error, :invalid_label}

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp resolve_or_create_label_id(issue_id, label_name) do
    normalized_name = normalize_label_name(label_name)

    with :ok <- validate_label_name(normalized_name),
         {:ok, lookup} <- fetch_label_lookup(issue_id, normalized_name) do
      case existing_label_id(lookup, normalized_name) || candidate_label_id(lookup, normalized_name) do
        label_id when is_binary(label_id) ->
          {:ok, label_id}

        nil ->
          create_label(lookup, normalized_name)
      end
    end
  end

  defp resolve_existing_issue_label_id(issue_id, label_name) do
    normalized_name = normalize_label_name(label_name)

    with :ok <- validate_label_name(normalized_name),
         {:ok, lookup} <- fetch_label_lookup(issue_id, normalized_name) do
      case existing_label_id(lookup, normalized_name) do
        label_id when is_binary(label_id) -> {:ok, label_id}
        nil -> :missing
      end
    end
  end

  defp fetch_label_lookup(issue_id, label_name) do
    case client_module().graphql(@issue_label_lookup_query, %{issueId: issue_id, labelName: label_name}) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_label(lookup, label_name) do
    with team_id when is_binary(team_id) <- get_in(lookup, ["data", "issue", "team", "id"]),
         {:ok, response} <-
           client_module().graphql(@create_issue_label_mutation, %{name: label_name, teamId: team_id}),
         true <- get_in(response, ["data", "issueLabelCreate", "success"]) == true,
         label_id when is_binary(label_id) <- get_in(response, ["data", "issueLabelCreate", "issueLabel", "id"]) do
      {:ok, label_id}
    else
      false -> {:error, :label_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :label_create_failed}
    end
  end

  defp existing_label_id(lookup, label_name) do
    lookup
    |> get_in(["data", "issue", "labels", "nodes"])
    |> find_label_id(label_name)
  end

  defp candidate_label_id(lookup, label_name) do
    team_id = get_in(lookup, ["data", "issue", "team", "id"])

    lookup
    |> get_in(["data", "issueLabels", "nodes"])
    |> case do
      labels when is_list(labels) -> labels
      _labels -> []
    end
    |> Enum.find_value(fn
      %{"id" => id, "name" => name, "team" => %{"id" => ^team_id}} when is_binary(id) ->
        if normalize_label_name(name) == label_name, do: id

      _label ->
        nil
    end)
  end

  defp find_label_id(labels, label_name) when is_list(labels) do
    Enum.find_value(labels, fn
      %{"id" => id, "name" => name} when is_binary(id) ->
        if normalize_label_name(name) == label_name, do: id

      _label ->
        nil
    end)
  end

  defp find_label_id(_labels, _label_name), do: nil

  defp normalize_label_name(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label_name(_value), do: ""

  defp validate_label_name(""), do: {:error, :invalid_label}
  defp validate_label_name(_label_name), do: :ok
end
