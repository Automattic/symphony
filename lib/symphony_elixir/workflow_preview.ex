defmodule SymphonyElixir.WorkflowPreview do
  @moduledoc """
  Renders the assembled base-issue prompt for a `WORKFLOW.md` using deterministic
  synthetic sample data, so authors can preview exactly what the agent would
  receive without Linear access, network, or a running orchestrator.

  Reuses `SymphonyElixir.PromptBuilder.build_prompt/2` (the single source of prompt
  assembly) via its `:workflow` seam, so the preview never drifts from runtime.
  """

  alias SymphonyElixir.{Linear.Issue, PromptBuilder, Workflow}

  @default_file "WORKFLOW.md"
  @default_agent_kind "codex"

  @type render_opts :: [file: String.t(), agent_kind: String.t()]

  @doc """
  Renders the base-issue prompt for the workflow at `:file` (default `WORKFLOW.md`).

  Returns `{:ok, prompt}` or `{:error, human_readable_message}`.
  """
  @spec render(render_opts()) :: {:ok, String.t()} | {:error, String.t()}
  def render(opts \\ []) do
    file = Keyword.get(opts, :file, @default_file)
    agent_kind = Keyword.get(opts, :agent_kind, @default_agent_kind)

    case Workflow.load(file) do
      {:ok, workflow} ->
        render_workflow(workflow, agent_kind)

      {:error, reason} ->
        {:error, "Could not read workflow file `#{file}`: #{inspect(reason)}"}
    end
  end

  @doc "Deterministic synthetic issue used for previews."
  @spec sample_issue() :: Issue.t()
  def sample_issue do
    %Issue{
      id: "issue_sample_0001",
      identifier: "ABC-123",
      title: "Sample: improve the export pipeline",
      description: "As a user I want faster exports.\n\nAcceptance criteria:\n- Export under 2s.",
      priority: 2,
      state: "In Progress",
      branch_name: "abc-123-improve-export-pipeline",
      url: "https://linear.app/your-org/issue/ABC-123",
      repo_key: "your-repo",
      labels: ["enhancement"]
    }
  end

  defp render_workflow(workflow, agent_kind) do
    prompt =
      PromptBuilder.build_prompt(sample_issue(),
        workflow: workflow,
        prompt_mode: :issue,
        agent_kind: agent_kind
      )

    {:ok, prompt}
  rescue
    error -> {:error, Exception.message(error)}
  end
end
