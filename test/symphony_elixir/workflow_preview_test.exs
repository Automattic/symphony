defmodule SymphonyElixir.WorkflowPreviewTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.WorkflowPreview

  defp write!(contents) do
    path = Path.join(System.tmp_dir!(), "workflow_preview_#{System.unique_integer([:positive])}.md")
    File.write!(path, contents)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "renders the base-issue prompt with managed context, expanded partials, and sample data" do
    path =
      write!("""
      ---
      prompts: {}
      ---
      You are working on `{{ issue.identifier }}`

      {% render "default_posture" %}
      """)

    assert {:ok, prompt} = WorkflowPreview.render(file: path, agent_kind: "codex")
    assert prompt =~ "Symphony runtime context:"
    assert prompt =~ "You are working on `ABC-123`"
    refute prompt =~ "{% render"
  end

  test "returns a friendly error for an unknown render partial" do
    path =
      write!("""
      ---
      prompts: {}
      ---
      {% render "not_a_real_partial" %}
      """)

    assert {:error, message} = WorkflowPreview.render(file: path)
    assert message =~ "not_a_real_partial"
  end

  test "returns a friendly error when the file is missing" do
    assert {:error, message} = WorkflowPreview.render(file: "/no/such/WORKFLOW.md")
    assert message =~ "WORKFLOW.md"
  end
end
