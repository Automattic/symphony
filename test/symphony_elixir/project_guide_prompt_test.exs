defmodule SymphonyElixir.ProjectGuidePromptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProjectGuidePrompt

  defmodule NoAppendProjectGuides do
  end

  defmodule RaisingProjectGuides do
    def append_to_prompt(_prompt, _workspace, _settings, _runner) do
      raise "guide failure"
    end
  end

  test "continues without guides when the guide injector is unavailable" do
    settings = Config.settings!()
    prompt = "Prompt with secret-token-value"

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, ^prompt} =
                 ProjectGuidePrompt.append_to_prompt(
                   prompt,
                   "/tmp/workspace",
                   settings,
                   :codex,
                   SymphonyElixir.MissingProjectGuides
                 )

        assert {:ok, ^prompt} =
                 ProjectGuidePrompt.append_to_prompt(prompt, "/tmp/workspace", settings, :claude, NoAppendProjectGuides)
      end)

    assert log =~ "Project guide injection unavailable"
    assert log =~ "continuing without project guides"
    refute log =~ "secret-token-value"
  end

  test "returns compact errors from unexpected guide injector failures" do
    settings = Config.settings!()

    assert {:error, {:project_guides_failed, RuntimeError}} =
             ProjectGuidePrompt.append_to_prompt(
               "Prompt with secret-token-value",
               "/tmp/workspace",
               settings,
               :codex,
               RaisingProjectGuides
             )
  end
end
