defmodule SymphonyElixir.SelfReviewConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  describe "self_review config" do
    test "defaults to disabled when section is absent" do
      assert {:ok, %Schema{self_review: review}} = Config.settings()
      refute review.enabled
      assert review.provider == "anthropic"
      assert review.model == "claude-haiku-4-5-20251001"
      refute Map.has_key?(review, :diff_max_lines)
      refute Map.has_key?(review, :max_rounds)
    end

    test "accepts an enabled section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        self_review: %{
          enabled: true,
          provider: "openai",
          model: "gpt-5.1-mini"
        }
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{self_review: review}} = Config.settings()
      assert review.enabled
      assert review.provider == "openai"
      assert review.model == "gpt-5.1-mini"
    end

    test "ignores legacy diff_max_lines and max_rounds values" do
      write_workflow_file!(Workflow.workflow_file_path(),
        self_review: %{
          enabled: true,
          provider: "openai",
          model: "gpt-5.1-mini"
        }
      )

      symphony_file = Workflow.symphony_file_path()
      without_legacy = File.read!(symphony_file)
      assert {:ok, %Schema{self_review: expected}} = Config.settings()

      with_legacy =
        String.replace(
          without_legacy,
          "  model: gpt-5.1-mini\n",
          "  model: gpt-5.1-mini\n  diff_max_lines: 600\n  max_rounds: 1\n"
        )

      File.write!(symphony_file, with_legacy)
      WorkflowStore.force_reload()

      assert :ok = Config.validate!()
      assert {:ok, %Schema{self_review: actual}} = Config.settings()
      assert actual == expected
    end

    test "accepts an explicitly disabled section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        self_review: %{enabled: false}
      )

      assert {:ok, %Schema{self_review: review}} = Config.settings()
      refute review.enabled
    end

    test "rejects unsupported provider values" do
      write_workflow_file!(Workflow.workflow_file_path(),
        self_review: %{enabled: true, provider: "huggingface", model: "x"}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "self_review"
      assert message =~ "provider"
      assert message =~ "anthropic"
      assert message =~ "openai"
    end
  end

  describe "review_agent config" do
    test "defaults to disabled when section is absent" do
      assert {:ok, %Schema{review_agent: review_agent}} = Config.settings()
      refute review_agent.enabled
      assert review_agent.kind == nil
      assert review_agent.command == nil
      assert review_agent.max_iterations == 1
    end

    test "accepts an enabled section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{
          enabled: true,
          kind: "codex",
          command: "codex app-server",
          max_iterations: 2
        }
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{review_agent: review_agent}} = Config.settings()
      assert review_agent.enabled
      assert review_agent.kind == "codex"
      assert review_agent.command == "codex app-server"
      assert review_agent.max_iterations == 2
    end

    test "rejects enabled config without kind and command" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "review_agent"
      assert message =~ "kind"
      assert message =~ "command"
    end

    test "rejects unsupported kind and invalid max_iterations" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{
          enabled: true,
          kind: "other",
          command: "other app-server",
          max_iterations: 0
        }
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "review_agent"
      assert message =~ "kind"
      assert message =~ "max_iterations"
    end
  end
end
