defmodule SymphonyElixir.AgentLabelsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentLabels

  test "normalizes blank and non-string kinds to generic labels" do
    assert AgentLabels.normalize_kind("   ") == nil
    assert AgentLabels.normalize_kind(%{}) == nil
    assert AgentLabels.display_name("   ") == "Agent"
    assert AgentLabels.workpad_heading(%{}) == "## Agent Workpad"
  end
end
