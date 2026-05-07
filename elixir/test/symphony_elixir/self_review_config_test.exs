defmodule SymphonyElixir.SelfReviewConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  describe "self_review config" do
    test "defaults to disabled when section is absent" do
      assert {:ok, %Schema{self_review: review}} = Config.settings()
      refute review.enabled
      assert review.provider == "anthropic"
      assert review.model == "claude-haiku-4-5-20251001"
      assert review.diff_max_lines == 600
      assert review.max_rounds == 1
    end

    test "accepts an enabled section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        self_review: %{
          enabled: true,
          provider: "openai",
          model: "gpt-5.1-mini",
          diff_max_lines: 250,
          max_rounds: 1
        }
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{self_review: review}} = Config.settings()
      assert review.enabled
      assert review.provider == "openai"
      assert review.model == "gpt-5.1-mini"
      assert review.diff_max_lines == 250
      assert review.max_rounds == 1
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

    test "rejects max_rounds above the v1 limit" do
      write_workflow_file!(Workflow.workflow_file_path(),
        self_review: %{enabled: true, max_rounds: 2}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "self_review"
      assert message =~ "max_rounds"
      assert message =~ "only supports 1"
    end
  end
end
