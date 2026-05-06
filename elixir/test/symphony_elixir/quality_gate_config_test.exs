defmodule SymphonyElixir.QualityGateConfigTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema

  describe "quality_gate config" do
    test "defaults to disabled when section is absent" do
      assert {:ok, %Schema{quality_gate: gate}} = Config.settings()
      refute gate.enabled
      assert gate.min_score == 6
      assert gate.on_error == "pass"
    end

    test "accepts a fully populated section" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true,
          provider: "anthropic",
          model: "claude-haiku-4-5-20251001",
          min_score: 7,
          on_error: "skip"
        }
      )

      assert :ok = Config.validate!()
      assert {:ok, %Schema{quality_gate: gate}} = Config.settings()
      assert gate.enabled
      assert gate.provider == "anthropic"
      assert gate.model == "claude-haiku-4-5-20251001"
      assert gate.min_score == 7
      assert gate.on_error == "skip"
    end

    test "errors when enabled but provider is missing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true,
          model: "claude-haiku-4-5-20251001"
        }
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "quality_gate"
      assert message =~ "provider"
    end

    test "errors when enabled but model is missing" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true,
          provider: "openai"
        }
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "quality_gate"
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

    test "rejects out-of-range min_score" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{
          enabled: true,
          provider: "anthropic",
          model: "x",
          min_score: 0
        }
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.settings()
      assert message =~ "min_score"
    end

    test "allows enabled: false without requiring provider/model" do
      write_workflow_file!(Workflow.workflow_file_path(),
        quality_gate: %{enabled: false}
      )

      assert {:ok, %Schema{quality_gate: gate}} = Config.settings()
      refute gate.enabled
    end
  end
end
