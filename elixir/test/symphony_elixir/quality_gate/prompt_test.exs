defmodule SymphonyElixir.QualityGate.PromptTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QualityGate.Prompt

  describe "system_instructions/0" do
    test "describes the rubric and required output shape" do
      instructions = Prompt.system_instructions()

      assert instructions =~ "1 (poor candidate) to 10"
      assert instructions =~ "Clarity"
      assert instructions =~ "Sandbox dependency"
      assert instructions =~ ~s({"score":)
    end
  end

  describe "user_prompt/1" do
    test "renders all issue fields when populated" do
      issue = %Issue{
        id: "ID-1",
        identifier: "RSM-100",
        title: "Add quality gate",
        description: "Filter issues before queuing.",
        labels: ["backend", "rsm"],
        state: "Todo",
        url: "https://example.org/RSM-100",
        updated_at: ~U[2026-05-05 03:00:00Z]
      }

      prompt = Prompt.user_prompt(issue)

      assert prompt =~ "RSM-100"
      assert prompt =~ "Add quality gate"
      assert prompt =~ "Filter issues before queuing"
      assert prompt =~ "backend, rsm"
      assert prompt =~ "Todo"
    end

    test "uses friendly placeholders for missing fields" do
      issue = %Issue{
        id: "ID-EMPTY",
        identifier: nil,
        title: "",
        description: nil,
        labels: [],
        state: nil,
        url: nil
      }

      prompt = Prompt.user_prompt(issue)

      assert prompt =~ "(unknown)"
      assert prompt =~ "(no description)"
      assert prompt =~ "(none)"
    end

    test "stringifies non-binary fields like atoms or integers" do
      issue = %Issue{
        id: "ID-N",
        identifier: 42,
        title: "ok",
        description: "desc",
        labels: [],
        state: :todo,
        url: nil
      }

      prompt = Prompt.user_prompt(issue)

      assert prompt =~ "Identifier: 42"
      assert prompt =~ "State: todo"
    end

    test "tolerates a non-list labels value" do
      issue = %Issue{
        id: "ID-X",
        identifier: "RSM-X",
        title: "X",
        description: "X",
        labels: nil,
        state: "Todo",
        url: nil
      }

      assert Prompt.user_prompt(issue) =~ "(none)"
    end
  end
end
