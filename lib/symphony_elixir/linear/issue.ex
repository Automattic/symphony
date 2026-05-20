defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Normalized Linear issue representation used by the orchestrator.
  """

  defstruct [
    :id,
    :identifier,
    :title,
    :description,
    :priority,
    :state,
    :team,
    :project,
    :branch_name,
    :url,
    :pull_request_url,
    :assignee_id,
    :repo_key,
    :run_kind,
    :intent,
    :pr_context,
    :workspace_branch,
    :workspace_base_ref,
    pr_urls: [],
    blocked_by: [],
    comments: [],
    linked_issues: [],
    conflict_repo_keys: [],
    labels: [],
    assigned_to_worker: true,
    created_at: nil,
    updated_at: nil
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          identifier: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t() | nil,
          team: %{key: String.t() | nil, name: String.t() | nil} | nil,
          project: %{id: String.t() | nil, name: String.t() | nil} | nil,
          branch_name: String.t() | nil,
          url: String.t() | nil,
          pull_request_url: String.t() | nil,
          assignee_id: String.t() | nil,
          repo_key: String.t() | nil,
          run_kind: atom() | String.t() | nil,
          intent: String.t() | nil,
          pr_context: map() | nil,
          workspace_branch: String.t() | nil,
          workspace_base_ref: String.t() | nil,
          pr_urls: [String.t()],
          comments: [%{author: String.t(), body: String.t(), created_at: DateTime.t() | nil}],
          linked_issues: [
            %{relation: String.t(), identifier: String.t(), title: String.t() | nil, state: String.t() | nil}
          ],
          conflict_repo_keys: [String.t()],
          labels: [String.t()],
          assigned_to_worker: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec label_names(t()) :: [String.t()]
  def label_names(%__MODULE__{labels: labels}) do
    labels
  end
end
