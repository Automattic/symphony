defmodule SymphonyElixir.Learnings.Store do
  @moduledoc """
  Durable, read-mostly store for run-derived learnings.
  """

  alias SymphonyElixir.{Config, RunStore}

  @default_max_total_per_repo 500

  @typedoc """
  A persisted learning entry.

  `:repo_key` is the durable RunStore partition key and controls storage,
  pruning, and default listing. `:repo` is source metadata from the evidence
  record, kept as a display/filter facet when the source repository slug is
  useful to readers. Writers must provide `:repo_key`; `:repo` may differ when
  the evidence source is more specific than the supervised repository
  partition.
  """
  @type record :: %{
          required(:id) => String.t(),
          required(:repo_key) => String.t(),
          required(:repo) => String.t(),
          required(:rule) => String.t(),
          required(:tags) => [String.t()],
          required(:evidence_quote) => String.t(),
          required(:evidence_issue_identifier) => String.t() | nil,
          optional(:evidence_issue_url) => String.t() | nil,
          required(:evidence_pr_number) => non_neg_integer() | nil,
          required(:evidence_run_id) => String.t() | nil,
          required(:created_at) => DateTime.t()
        }

  @spec put_many([record()], keyword()) :: :ok | {:error, term()}
  def put_many(records, opts \\ []) when is_list(records) do
    max_total_per_repo = Keyword.get(opts, :max_total_per_repo, @default_max_total_per_repo)
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = Keyword.get(opts, :repo_key) || Config.repo_key!()

    records
    |> Enum.map(&Map.put_new(&1, :repo_key, repo_key))
    |> run_store.put_learnings(max_total_per_repo)
  end

  @spec list(keyword()) :: [record()] | {:error, term()}
  def list(opts \\ []) when is_list(opts) do
    run_store = Keyword.get(opts, :run_store, RunStore)
    repo_key = Keyword.get(opts, :repo_key) || Config.repo_key!()

    run_store.list_learnings(repo_key, Keyword.drop(opts, [:run_store]))
  end
end
