defmodule SymphonyElixir.ReviewAgentConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.{Schema, SystemSchema}

  describe "removed self_review config" do
    test "workflow config rejects self_review and points to review_agent" do
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
      assert message =~ "review_agent"
    end

    test "system config rejects self_review and points to review_agent" do
      assert {:error, {:invalid_symphony_config, message}} =
               SystemSchema.parse(%{
                 "self_review" => %{"enabled" => true},
                 "repos" => [%{"name" => "default", "workflow" => "WORKFLOW.md", "team" => "Test"}]
               })

      assert message =~ "self_review"
      assert message =~ "review_agent"
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
