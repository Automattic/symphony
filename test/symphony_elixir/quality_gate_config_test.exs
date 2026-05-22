defmodule SymphonyElixir.QualityGateConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  describe "issue_gate config" do
    test "defaults to disabled when section is absent" do
      assert {:ok, %Schema{quality_gate: gate}} = Config.settings()
      refute gate.enabled
      assert gate.provider == "anthropic"
      assert gate.model == "claude-haiku-4-5-20251001"
      assert gate.min_score == 6
      assert gate.on_error == "pass"
    end

    test "accepts a fully populated section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true,
          provider: "anthropic",
          model: "claude-haiku-4-5-20251001",
          pass_threshold: 7,
          clarification_floor: 4,
          max_clarification_rounds: 3,
          on_error: "skip"
        }
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{quality_gate: gate}} = Config.settings()
      assert gate.enabled
      assert gate.provider == "anthropic"
      assert gate.model == "claude-haiku-4-5-20251001"
      assert gate.pass_threshold == 7
      assert gate.min_score == 6
      assert gate.clarification_floor == 4
      assert gate.max_clarification_rounds == 3
      assert gate.on_error == "skip"
    end

    test "uses provider and model defaults when enabled section omits them" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true
        }
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{quality_gate: gate}} = Config.settings()
      assert gate.enabled
      assert gate.provider == "anthropic"
      assert gate.model == "claude-haiku-4-5-20251001"
    end

    test "errors when enabled section sets provider but omits model" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true,
          provider: "openai"
        }
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "issue_gate"
      assert message =~ "model"
    end

    test "rejects unsupported provider values" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{enabled: true, provider: "huggingface", model: "x"}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "provider"
      assert message =~ "anthropic"
      assert message =~ "openai"
    end

    test "rejects unsupported on_error values" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true,
          provider: "anthropic",
          model: "x",
          on_error: "explode"
        }
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "on_error"
      assert message =~ "pass"
      assert message =~ "skip"
    end

    test "rejects out-of-range pass_threshold" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true,
          provider: "anthropic",
          model: "x",
          pass_threshold: 11
        }
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "pass_threshold"
    end

    test "rejects clarification_floor at or above the effective pass threshold" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true,
          provider: "anthropic",
          model: "x",
          pass_threshold: 6,
          clarification_floor: 6
        }
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "clarification_floor"
      assert message =~ "pass_threshold"
    end

    test "allows enabled: false without requiring provider/model" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{enabled: false}
      )

      assert {:ok, %Schema{quality_gate: gate}} = Config.settings()
      refute gate.enabled
    end

    test "allows disabled provider override without requiring model" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{enabled: false, provider: "openai"}
      )

      assert {:ok, %Schema{quality_gate: gate}} = Config.settings()
      refute gate.enabled
      assert gate.provider == "openai"
    end
  end
end
