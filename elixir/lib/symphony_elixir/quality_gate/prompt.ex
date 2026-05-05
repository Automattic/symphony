defmodule SymphonyElixir.QualityGate.Prompt do
  @moduledoc """
  Builds the user prompt sent to LLM providers for issue scoping.

  The prompt asks the model to evaluate the issue across clarity, scope,
  ambiguity markers, and sandbox dependency, and to reply with a strict JSON
  payload of the form `{"score": <1-10>, "reason": "<one-sentence>"}`.
  """

  alias SymphonyElixir.Linear.Issue

  @system_instructions """
  You evaluate Linear issues for autonomous code-agent readiness.

  Score each issue from 1 (poor candidate) to 10 (excellent candidate) based on:
    - Clarity: well-defined problem and acceptance criteria
    - Scope: bounded surface area for a single PR
    - Ambiguity markers: words like "maybe", "investigate", "explore", open-ended questions
    - Sandbox dependency: needs production credentials, manual UI testing, real browsers, deploys

  Reply with ONLY a single JSON object:
    {"score": <integer 1-10>, "reason": "<one short sentence>"}

  Do not include any extra prose, code fences, or commentary.
  """

  @spec system_instructions() :: String.t()
  def system_instructions, do: @system_instructions

  @spec user_prompt(Issue.t()) :: String.t()
  def user_prompt(%Issue{} = issue) do
    """
    Identifier: #{present(issue.identifier)}
    Title: #{present(issue.title)}
    Labels: #{format_labels(issue.labels)}
    State: #{present(issue.state)}

    Description:
    #{present(issue.description, "(no description)")}
    """
  end

  defp present(value, fallback \\ "(unknown)")
  defp present(nil, fallback), do: fallback
  defp present("", fallback), do: fallback
  defp present(value, _fallback) when is_binary(value), do: value
  defp present(value, _fallback), do: to_string(value)

  defp format_labels([]), do: "(none)"
  defp format_labels(labels) when is_list(labels), do: Enum.join(labels, ", ")
  defp format_labels(_labels), do: "(none)"
end
