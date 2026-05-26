defmodule SymphonyElixir.PlaybookTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Playbook
  alias SymphonyElixir.Playbook.FileSystem

  @expected_names ~w(
    ci_triage
    dependency_guardrail
    escape_hatches
    out_of_scope_backlog
    pr_feedback_sweep
    reproduce_and_blast_radius
    workpad_bootstrap
    workpad_template
  )

  test "names/0 lists the embedded playbook partials, sorted" do
    assert Playbook.names() == @expected_names
  end

  test "every partial is non-empty, parses as Solid, and declares a matching name header" do
    for name <- Playbook.names() do
      assert {:ok, body} = Playbook.fetch(name)
      assert byte_size(body) > 0
      assert {:ok, _template} = Solid.parse(body)
      assert body =~ "name: #{name}\n"
    end
  end

  test "fetch/1 returns :error for an unknown partial" do
    assert Playbook.fetch("does_not_exist") == :error
  end

  test "FileSystem serves known partials and errors on unknown names" do
    assert {:ok, body} = FileSystem.read_template_file("pr_feedback_sweep", nil)
    assert body =~ "PR feedback sweep protocol"

    assert {:error, %Solid.FileSystem.Error{reason: reason}} =
             FileSystem.read_template_file("nope", nil)

    assert reason =~ "unknown playbook partial `nope`"
  end
end
