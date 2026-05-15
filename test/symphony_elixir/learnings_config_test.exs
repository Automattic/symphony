defmodule SymphonyElixir.LearningsConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  describe "learnings config" do
    test "defaults to disabled when section is absent" do
      assert {:ok, %Schema{learnings: learnings}} = Config.settings()
      refute learnings.enabled
      assert learnings.provider == "anthropic"
      assert learnings.model == "claude-haiku-4-5-20251001"
      assert learnings.max_total_per_repo == 500
      assert learnings.max_per_run == 3
    end

    test "accepts an enabled section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        learnings: %{
          enabled: true,
          provider: "openai",
          model: "gpt-5.1-mini",
          max_total_per_repo: 25,
          max_per_run: 2
        }
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{learnings: learnings}} = Config.settings()
      assert learnings.enabled
      assert learnings.provider == "openai"
      assert learnings.model == "gpt-5.1-mini"
      assert learnings.max_total_per_repo == 25
      assert learnings.max_per_run == 2
    end

    test "accepts an explicitly disabled section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        learnings: %{enabled: false}
      )

      assert {:ok, %Schema{learnings: learnings}} = Config.settings()
      refute learnings.enabled
    end

    test "rejects unsupported provider values" do
      write_workflow_file!(Workflow.workflow_file_path(),
        learnings: %{enabled: true, provider: "local", model: "x"}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "learnings"
      assert message =~ "provider"
      assert message =~ "anthropic"
      assert message =~ "openai"
    end

    test "rejects max_per_run above phase-one limit" do
      write_workflow_file!(Workflow.workflow_file_path(),
        learnings: %{enabled: true, max_per_run: 4}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "learnings"
      assert message =~ "max_per_run"
    end
  end
end
