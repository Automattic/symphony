defmodule SymphonyElixir.ReviewAgentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ReviewAgent

  defmodule StreamingCodexReviewer do
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(_session, _prompt, _issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)

      [
        ~s({"ver),
        ~s(dict":"request_changes",),
        ~s("comments":["Handle remote guides."]})
      ]
      |> Enum.each(fn delta ->
        on_message.(%{
          event: :notification,
          payload: %{
            "method" => "item/agentMessage/delta",
            "params" => %{"delta" => delta}
          },
          raw: Jason.encode!(%{"method" => "item/agentMessage/delta", "params" => %{"delta" => delta}})
        })
      end)

      {:ok, %{input_tokens: 1, output_tokens: 1}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule RuntimeTupleReviewer do
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(_session, _prompt, _issue, _opts) do
      {:ok, %{result: "{:error, {:turn_failed, reason}}"}}
    end

    def stop_session(_session), do: :ok
  end

  defmodule RuntimeTupleWithStreamingReviewer do
    def start_session(workspace, opts), do: {:ok, %{workspace: workspace, opts: opts}}

    def run_turn(_session, _prompt, _issue, opts) do
      on_message = Keyword.fetch!(opts, :on_message)

      on_message.(%{
        event: :notification,
        payload: %{
          "method" => "item/agentMessage/delta",
          "params" => %{"delta" => ~s({"verdict":"approve","comments":[]})}
        }
      })

      {:ok, %{result: "{:error, {:turn_failed, reason}}"}}
    end

    def stop_session(_session), do: :ok
  end

  describe "parse_response/1" do
    test "accepts approved verdict JSON inside surrounding text" do
      assert {:ok, %{verdict: :approve, comments: []}} =
               ReviewAgent.parse_response("""
               Review complete.
               ```json
               {"verdict":"approve","comments":[]}
               ```
               """)
    end

    test "accepts request_changes with actionable comments" do
      assert {:ok, %{verdict: :request_changes, comments: ["Add coverage."]}} =
               ReviewAgent.parse_response(~s({"verdict":"request_changes","comments":["Add coverage."]}))
    end

    test "requires comments for request_changes" do
      assert {:error, {:malformed_review_agent_response, :missing_request_changes_comments}} =
               ReviewAgent.parse_response(~s({"verdict":"request_changes","comments":[]}))
    end

    test "requires a reason for block" do
      assert {:error, {:malformed_review_agent_response, :missing_block_reason}} =
               ReviewAgent.parse_response(~s({"verdict":"block","comments":[]}))
    end

    test "classifies an Elixir error tuple as reviewer runtime failure" do
      assert {:error, {:review_agent_runtime_error, "{:error, {:turn_failed, reason}}"}} =
               ReviewAgent.parse_response("{:error, {:turn_failed, reason}}")
    end

    test "skips non-JSON brace groups before reviewer verdict JSON" do
      assert {:ok, %{verdict: :approve, comments: []}} =
               ReviewAgent.parse_response("""
               finalize returns `{:ok, session}` and failed turns return
               `{:error, {:turn_failed, reason}}`.
               {"verdict":"approve","comments":[],"reason":""}
               """)
    end
  end

  test "evaluate parses Codex reviewer verdicts from streamed agent-message deltas" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-agent-streaming-codex-#{System.unique_integer([:positive])}"
      )

    try do
      repo = git_repo!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      issue = %Issue{
        id: "issue-review-streaming",
        identifier: "MT-STREAM",
        title: "Stream review verdict",
        description: "Review result is only available through item/agentMessage/delta chunks",
        state: "In Progress"
      }

      assert {:ok, %{verdict: :request_changes, comments: ["Handle remote guides."]}} =
               ReviewAgent.evaluate(issue, repo, Config.settings!(), review_agent_module: StreamingCodexReviewer)
    after
      File.rm_rf(test_root)
    end
  end

  test "evaluate prefers streamed reviewer verdict over invalid primary result text" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-agent-streaming-primary-error-#{System.unique_integer([:positive])}"
      )

    try do
      repo = git_repo!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      issue = %Issue{
        id: "issue-review-streaming-primary-error",
        identifier: "MT-STREAM-PRIMARY",
        title: "Stream review verdict despite primary error",
        description: "Review result is available through streamed deltas",
        state: "In Progress"
      }

      assert {:ok, %{verdict: :approve, comments: []}} =
               ReviewAgent.evaluate(
                 issue,
                 repo,
                 Config.settings!(),
                 review_agent_module: RuntimeTupleWithStreamingReviewer
               )
    after
      File.rm_rf(test_root)
    end
  end

  test "evaluate surfaces reviewer runtime tuple when no verdict text is available" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-review-agent-runtime-tuple-#{System.unique_integer([:positive])}"
      )

    try do
      repo = git_repo!(test_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        review_agent: %{enabled: true, kind: "codex", command: "codex app-server"}
      )

      issue = %Issue{
        id: "issue-review-runtime-tuple",
        identifier: "MT-RUNTIME-TUPLE",
        title: "Review runtime tuple",
        description: "Review result is a runtime error tuple",
        state: "In Progress"
      }

      assert {:error, {:review_agent_runtime_error, "{:error, {:turn_failed, reason}}"}} =
               ReviewAgent.evaluate(issue, repo, Config.settings!(), review_agent_module: RuntimeTupleReviewer)
    after
      File.rm_rf(test_root)
    end
  end

  defp git_repo!(test_root) do
    repo = Path.join(test_root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "# review stream\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
    repo
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
