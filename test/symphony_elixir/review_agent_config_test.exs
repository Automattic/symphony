defmodule SymphonyElixir.ReviewAgentConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Schema, SystemSchema}

  describe "removed self_review config" do
    test "workflow config rejects self_review and points to pre_push_review" do
      File.write!(Workflow.workflow_file_path(), """
      ---
      self_review:
        enabled: true
        provider: openai
        model: gpt-5.1-mini
      ---
      Test prompt
      """)

      WorkflowStore.force_reload()

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "self_review"
      assert message =~ "pre_push_review"
    end

    test "system config rejects self_review and points to pre_push_review" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{
                 "self_review" => %{"enabled" => true},
                 "repositories" => [
                   %{"key" => "default", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}
                 ]
               })

      assert message =~ "self_review"
      assert message =~ "pre_push_review"
    end
  end

  describe "review_agent config" do
    test "defaults to disabled when section is absent" do
      assert {:ok, %Schema{} = settings} = Config.settings()
      refute Map.has_key?(settings, :self_review)
      refute settings.review_agent.enabled
      assert settings.review_agent.kind == nil
      assert settings.review_agent.command == nil
      assert settings.review_agent.max_iterations == 1
      assert settings.review_agent.run_on == "always"
    end

    test "accepts an enabled section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{
          enabled: true,
          kind: "codex",
          command: "codex app-server",
          max_iterations: 2,
          run_on: "first_push"
        }
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{review_agent: review_agent}} = Config.settings()
      assert review_agent.enabled
      assert review_agent.kind == "codex"
      assert review_agent.command == "codex app-server"
      assert review_agent.max_iterations == 2
      assert review_agent.run_on == "first_push"
    end

    test "rejects enabled config without kind and command" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "pre_push_review"
      assert message =~ "runtime"
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
      assert message =~ "pre_push_review"
      assert message =~ "runtime"
      assert message =~ "max_iterations"
    end

    test "rejects unsupported run_on" do
      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{
          enabled: true,
          kind: "codex",
          command: "codex app-server",
          run_on: "follow_ups"
        }
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "pre_push_review"
      assert message =~ "run_on"
    end

    test "system config normalizes pre_push_review run_on" do
      assert {:ok, %SystemSchema{review_agent: review_agent}} =
               SystemSchema.parse(%{
                 "pre_push_review" => %{
                   "enabled" => true,
                   "runtime" => "codex",
                   "command" => "codex app-server",
                   "run_on" => "first_push"
                 },
                 "repositories" => [
                   %{"key" => "default", "workflow" => "WORKFLOW.md", "route" => %{"team" => "Test"}}
                 ]
               })

      assert review_agent.run_on == "first_push"
    end
  end
end
