defmodule SymphonyElixir.SelfReviewTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureLog

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.SelfReview

  defmodule StubProvider do
    def review(request, _settings) do
      recipient = Application.fetch_env!(:symphony_elixir, :self_review_test_recipient)
      send(recipient, {:self_review_request, request})

      {:ok, Application.fetch_env!(:symphony_elixir, :self_review_test_response)}
    end
  end

  defmodule RaisingProvider do
    def review(_request, _settings), do: raise("self review provider should not be called")
  end

  defmodule NoReviewProvider do
  end

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test-anthropic-key")
    Application.put_env(:symphony_elixir, :self_review_test_recipient, self())

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      Application.delete_env(:symphony_elixir, :self_review_test_recipient)
      Application.delete_env(:symphony_elixir, :self_review_test_response)
    end)

    :ok
  end

  test "approves an aligned diff and sends the required source material" do
    repo = changed_repo!("feature.txt", "aligned implementation\n")
    Application.put_env(:symphony_elixir, :self_review_test_response, ~s({"verdict":"approve","findings":[]}))

    result = SelfReview.evaluate(issue(), repo, enabled_config(), provider_module: StubProvider)

    assert result.verdict == "approve"
    assert result.findings == []
    assert result.source.changed_paths == ["feature.txt"]
    assert result.source.acceptance_criteria =~ "Add the self-review gate"
    refute result.source.diff_truncated?

    assert_receive {:self_review_request, %{system: system, user: user}}
    assert system =~ "Bias strongly toward approve"
    assert system =~ "style opinions"
    assert user =~ "Issue title:"
    assert user =~ "Commit subjects and bodies:"
    assert user =~ "feat: add self review"
    assert user =~ "Git diff origin/main..HEAD:"
  end

  test "requests changes for an allowed blocking finding" do
    repo = changed_repo!("feature.txt", "misaligned implementation\n")

    Application.put_env(
      :symphony_elixir,
      :self_review_test_response,
      ~s({"verdict":"request_changes","findings":[{"severity":"blocking","category":"commit_message","description":"The commit subject claims a gate but only changes docs.","evidence":"feat: add self review"}]})
    )

    result = SelfReview.evaluate(issue(), repo, enabled_config(), provider_module: StubProvider)

    assert result.verdict == "request_changes"

    assert [
             %{
               severity: "blocking",
               category: "commit_message",
               description: "The commit subject claims a gate but only changes docs.",
               evidence: "feat: add self review"
             }
           ] = result.findings
  end

  test "drops subjective or unsupported categories before deciding the verdict" do
    repo = changed_repo!("feature.txt", "implementation\n")

    Application.put_env(
      :symphony_elixir,
      :self_review_test_response,
      ~s({"verdict":"request_changes","findings":[{"severity":"blocking","category":"style","description":"The code could be prettier."}]})
    )

    result = SelfReview.evaluate(issue(), repo, enabled_config(), provider_module: StubProvider)

    assert result.verdict == "approve"
    assert result.findings == []
  end

  test "truncates large diffs and logs a warning while still running the gate" do
    repo = changed_repo!("feature.txt", Enum.map_join(1..20, "\n", &"line #{&1}"))
    Application.put_env(:symphony_elixir, :self_review_test_response, ~s({"verdict":"approve","findings":[]}))

    log =
      capture_log(fn ->
        result = SelfReview.evaluate(issue(), repo, enabled_config(diff_max_lines: 3), provider_module: StubProvider)
        assert result.verdict == "approve"
        assert result.source.diff_truncated?
        assert result.source.diff_line_count > 3
      end)

    assert log =~ "SelfReview diff truncated"
    assert_receive {:self_review_request, %{user: user}}
    assert user =~ "Diff truncated: showing first 3"
  end

  test "malformed output fails open as approve" do
    repo = changed_repo!("feature.txt", "implementation\n")
    Application.put_env(:symphony_elixir, :self_review_test_response, "not json")

    log =
      capture_log(fn ->
        result = SelfReview.evaluate(issue(), repo, enabled_config(), provider_module: StubProvider)
        assert result.verdict == "approve"
        assert result.findings == []
        assert result.fail_open_reason == {:malformed_response, :no_json_object}
      end)

    assert log =~ "SelfReview malformed LLM output"
  end

  test "disabled config is a no-op and does not call the provider" do
    repo = changed_repo!("feature.txt", "implementation\n")

    result =
      SelfReview.evaluate(issue(), repo, %Schema.SelfReview{enabled: false}, provider_module: RaisingProvider)

    assert result.verdict == "approve"
    assert result.findings == []
    assert result.fail_open_reason == :disabled

    refute_receive {:self_review_request, _request}, 50
  end

  test "nil config and invalid inputs fail open without provider calls" do
    repo = changed_repo!("feature.txt", "implementation\n")

    assert %{verdict: "approve", fail_open_reason: :disabled} = SelfReview.evaluate(issue(), repo, nil)
    assert %{verdict: "approve", fail_open_reason: :invalid_input} = SelfReview.evaluate(%{}, repo, enabled_config())

    refute_receive {:self_review_request, _request}, 50
  end

  test "provider setup and local git failures fail open" do
    repo = changed_repo!("feature.txt", "implementation\n")
    plain_dir = Path.join(System.tmp_dir!(), "symphony-self-review-plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(plain_dir) end)

    log =
      capture_log(fn ->
        missing_callback = SelfReview.evaluate(issue(), repo, enabled_config(), provider_module: NoReviewProvider)
        local_git_failure = SelfReview.evaluate(issue(), plain_dir, enabled_config(), provider_module: StubProvider)

        assert missing_callback.verdict == "approve"
        assert local_git_failure.verdict == "approve"
      end)

    assert log =~ "provider_missing_review_callback"
    assert log =~ "git_failed"
  end

  test "parses schema edge cases and prompt helpers" do
    assert {:error, {:malformed_response, :empty_response}} = SelfReview.parse_response(nil)
    assert {:error, {:malformed_response, :empty_response}} = SelfReview.parse_response("")
    assert {:error, {:malformed_response, :empty_response}} = SelfReview.parse_response("```json\n```")
    assert {:error, {:malformed_response, :no_json_object}} = SelfReview.parse_response("no json here")
    assert {:error, {:malformed_response, :no_json_object}} = SelfReview.parse_response("{")
    assert {:error, {:malformed_response, {:invalid_json, _}}} = SelfReview.parse_response("{bad}")
    assert {:error, {:malformed_response, :invalid_verdict}} = SelfReview.parse_response(~s({"verdict":"maybe","findings":[]}))
    assert {:error, {:malformed_response, :invalid_findings}} = SelfReview.parse_response(~s({"verdict":"approve","findings":{}}))

    assert {:ok, %{verdict: "approve", findings: []}} =
             SelfReview.parse_response(~s({"verdict":"approve","findings":[],"note":"escaped \\" quote"}))

    assert {:ok, %{verdict: "request_changes", findings: [%{evidence: "line"}]}} =
             SelfReview.parse_response(~s({"verdict":"request_changes","findings":[{"severity":"blocking","category":"scope_creep","description":"Unrelated file changed.","evidence":"line"}]}))

    assert {:ok, %{verdict: "request_changes", findings: [%{category: "scope_creep"}]}} =
             SelfReview.parse_response(~s({"verdict":"request_changes","findings":[{"severity":"blocking","category":"scope_creep","description":"Unrelated file changed.","evidence":""}]}))

    assert {:ok, %{verdict: "request_changes", findings: [%{category: "scope_creep"}]}} =
             SelfReview.parse_response(~s({"verdict":"request_changes","findings":[{"severity":"blocking","category":"scope_creep","description":"Unrelated file changed.","evidence":123}]}))

    assert SelfReview.request_changes?(%{verdict: "request_changes", findings: [%{category: "scope_creep"}]})
    refute SelfReview.request_changes?(%{verdict: "approve", findings: []})
    assert SelfReview.approval_prompt(%{}) =~ "approved"
    assert SelfReview.push_prompt(%{findings: []}) =~ "no remaining blocking findings"

    finding = %{severity: "blocking", category: "scope_creep", description: "Unrelated file changed.", evidence: "diff --git"}
    assert SelfReview.request_changes_prompt(%{findings: [finding]}) =~ "Evidence: diff --git"
    assert SelfReview.push_prompt(%{findings: [finding]}) =~ "Push regardless now"
    assert SelfReview.known_limitations_section([finding]) =~ "Evidence: `diff --git`"

    bare_finding = %{severity: "blocking", category: "commit_message", description: "Commit body overclaims."}
    assert SelfReview.request_changes_prompt(%{findings: [bare_finding]}) =~ "Commit body overclaims."
    assert SelfReview.known_limitations_section([bare_finding]) =~ "commit_message"
  end

  test "handles remote git collection through ssh" do
    fake =
      fake_ssh!("remote-success", """
      count_file="${SYMP_TEST_SSH_COUNT_FILE}"
      count=0
      if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
      count=$((count + 1))
      printf '%s' "$count" > "$count_file"
      case "$count" in
        1) printf '%s\\n' 'diff --git a/remote.txt b/remote.txt' '+remote change' ;;
        2) printf '%s\\n' 'remote.txt' ;;
        *) printf '%s\\n' 'feat: remote self review' ;;
      esac
      """)

    Application.put_env(:symphony_elixir, :self_review_test_response, ~s({"verdict":"approve","findings":[]}))

    result =
      with_fake_ssh(fake, fn ->
        SelfReview.evaluate(issue(), "/remote/worktree", enabled_config(), worker_host: "worker-1", provider_module: StubProvider)
      end)

    assert result.verdict == "approve"
    assert result.source.changed_paths == ["remote.txt"]
    assert_receive {:self_review_request, %{user: user}}
    assert user =~ "feat: remote self review"
  end

  test "remote git command failures fail open" do
    fake = fake_ssh!("remote-status", "printf '%s\\n' 'remote failed'; exit 42")

    log =
      capture_log(fn ->
        result =
          with_fake_ssh(fake, fn ->
            SelfReview.evaluate(issue(), "/remote/worktree", enabled_config(), worker_host: "worker-1", provider_module: StubProvider)
          end)

        assert result.verdict == "approve"
      end)

    assert log =~ "git_failed"
    assert log =~ "remote failed"
  end

  test "missing ssh executable fails open" do
    previous_path = System.get_env("PATH")
    System.put_env("PATH", "")

    try do
      log =
        capture_log(fn ->
          result = SelfReview.evaluate(issue(), "/remote/worktree", enabled_config(), worker_host: "worker-1", provider_module: StubProvider)
          assert result.verdict == "approve"
        end)

      assert log =~ "ssh_not_found"
    after
      restore_env("PATH", previous_path)
    end
  end

  test "source material tolerates missing and non-string issue fields" do
    repo = changed_repo!("feature.txt", "implementation\n")
    Application.put_env(:symphony_elixir, :self_review_test_response, ~s({"verdict":"approve","findings":[]}))

    issue = %Issue{id: "issue-weird", identifier: "MT-WEIRD", title: 123, description: nil}
    result = SelfReview.evaluate(issue, repo, enabled_config(), provider_module: StubProvider)

    assert result.verdict == "approve"
    assert result.source.issue_title == "123"
    assert result.source.issue_description == ""
    assert result.source.acceptance_criteria == ""
  end

  test "source material handles empty diffs and changed path lists" do
    repo = unchanged_repo!()
    Application.put_env(:symphony_elixir, :self_review_test_response, ~s({"verdict":"approve","findings":[]}))

    issue = %Issue{id: "issue-no-diff", identifier: "MT-NO-DIFF", title: nil, description: "No criteria here."}
    result = SelfReview.evaluate(issue, repo, enabled_config(), provider_module: StubProvider)

    assert result.verdict == "approve"
    assert result.source.issue_title == ""
    assert result.source.acceptance_criteria == ""
    assert result.source.diff == ""
    assert result.source.diff_line_count == 0
    assert result.source.changed_paths == []

    assert_receive {:self_review_request, %{user: user}}
    assert user =~ "Changed file paths:\n(none)"
  end

  defp enabled_config(opts \\ []) do
    struct!(
      Schema.SelfReview,
      Keyword.merge(
        [
          enabled: true,
          provider: "anthropic",
          model: "claude-haiku-4-5-20251001",
          diff_max_lines: 600,
          max_rounds: 1
        ],
        opts
      )
    )
  end

  defp issue do
    %Issue{
      id: "issue-self-review",
      identifier: "MT-SR",
      title: "Add a self-review gate",
      description: """
      ## Problem

      The implementation needs a fresh reviewer before push.

      ## Acceptance criteria

      - Add the self-review gate.
      - Keep disabled behavior unchanged.

      ## Notes

      Use the existing provider abstraction.
      """
    }
  end

  defp changed_repo!(path, contents) do
    repo = Path.join(System.tmp_dir!(), "symphony-self-review-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(repo) end)

    init_repo!(repo)

    full_path = Path.join(repo, path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, contents)
    git!(repo, ["add", path])
    git!(repo, ["commit", "-m", "feat: add self review", "-m", "Implement the configured pre-push gate."])

    repo
  end

  defp unchanged_repo! do
    repo = Path.join(System.tmp_dir!(), "symphony-self-review-unchanged-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(repo) end)
    init_repo!(repo)
    repo
  end

  defp init_repo!(repo) do
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "# test\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
  end

  defp fake_ssh!(name, body) do
    dir = Path.join(System.tmp_dir!(), "symphony-self-review-ssh-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)

    ssh = Path.join(dir, "ssh")

    File.write!(ssh, """
    #!/bin/sh
    #{body}
    """)

    File.chmod!(ssh, 0o755)
    %{dir: dir, count_file: Path.join(dir, "count")}
  end

  defp with_fake_ssh(%{dir: dir, count_file: count_file}, fun) do
    previous_path = System.get_env("PATH")
    previous_count = System.get_env("SYMP_TEST_SSH_COUNT_FILE")

    System.put_env("PATH", dir <> ":" <> (previous_path || ""))
    System.put_env("SYMP_TEST_SSH_COUNT_FILE", count_file)

    try do
      fun.()
    after
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_COUNT_FILE", previous_count)
    end
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
