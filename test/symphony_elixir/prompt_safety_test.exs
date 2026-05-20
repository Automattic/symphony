defmodule SymphonyElixir.PromptSafetyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PromptSafety

  test "wraps acceptance criteria in a dedicated Linear boundary" do
    assert PromptSafety.linear_issue_acceptance_criteria("Ship <feature>") ==
             """
             <linear_issue_acceptance_criteria>
             Ship &lt;feature&gt;
             </linear_issue_acceptance_criteria>\
             """
  end
end
