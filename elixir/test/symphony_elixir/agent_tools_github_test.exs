defmodule SymphonyElixir.AgentTools.GitHubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.GitHub
  alias SymphonyElixir.AgentTools.SecretScanner

  test "public defaults fail closed when required scope is missing" do
    assert {:error, :missing_github_origin_repo} = GitHub.get_pull_request(%{})
    assert {:error, :missing_github_origin_repo} = GitHub.get_pull_request(:invalid_context)
    assert {:error, :missing_github_origin_repo} = GitHub.create_pull_request(%{}, "Title", "Body")
    assert {:error, :missing_github_origin_repo} = GitHub.update_pull_request_body(%{}, "Body")
    assert {:error, :missing_github_origin_repo} = GitHub.add_pr_comment(%{}, "Body")
    assert {:error, :missing_github_origin_repo} = GitHub.get_pr_checks(%{})
    assert {:error, :missing_workspace} = GitHub.push_branch(%{})
  end

  test "validates explicit inputs and workspace context" do
    missing_workspace = Path.join(System.tmp_dir!(), "github-agent-tool-missing-#{System.unique_integer([:positive])}")

    assert {:error, :invalid_title} =
             GitHub.create_pull_request(scoped_context(System.tmp_dir!()), :bad, "Body", nil, [])

    assert {:error, :invalid_body} =
             GitHub.update_pull_request_body(scoped_context(System.tmp_dir!()), :bad, [])

    assert {:error, :invalid_draft} =
             GitHub.create_pull_request(scoped_context(System.tmp_dir!()), "Title", "Body", "yes", [])

    assert {:error, :workspace_not_found} =
             GitHub.push_branch(%{command_security: %{origin_repo: "acme/symphony", workspace: missing_workspace}}, [])
  end

  test "pull request body tools reject high-confidence secret prefixes before calling GitHub" do
    workspace = tmp_workspace!("github-agent-secret-scan")
    audit_dir = Path.join(workspace, "audit")
    context = scoped_context(workspace) |> Map.put(:issue, %{"id" => "issue-secret", "identifier" => "RSM-3189"})

    try do
      for token <- secret_fixtures() do
        body = "leaked credential: " <> token

        assert {:error, :secret_pattern_detected} =
                 GitHub.create_pull_request(context, "Title", body, false, dir: audit_dir)
      end

      assert {:error, :secret_pattern_detected} =
               GitHub.update_pull_request_body(context, "body " <> openai_fixture(), dir: audit_dir)

      assert {:error, :secret_pattern_detected} =
               GitHub.add_pr_comment(context, "body " <> openai_fixture(), dir: audit_dir)

      assert [%{"event_type" => "refused_agent_action", "reason" => "secret_pattern_detected"} | _rest] =
               audit_events(audit_dir)

      refute inspect(audit_events(audit_dir)) =~ openai_fixture()
    after
      File.rm_rf(workspace)
    end
  end

  test "secret scanner handles clean, invalid, and audit-failure paths without content disclosure" do
    workspace = tmp_workspace!("github-agent-secret-scanner")
    audit_dir = Path.join(workspace, "audit")
    blocked_audit_path = Path.join(workspace, "blocked-audit")
    File.write!(blocked_audit_path, "not a directory")

    try do
      assert :ok = SecretScanner.reject_if_secret_pattern("ordinary comment", %{}, "tool", "body")
      assert :ok = SecretScanner.reject_if_secret_pattern(:not_binary, %{}, "tool", "body", [])
      refute SecretScanner.detect("ordinary comment")
      refute SecretScanner.detect(<<255>>)

      assert {:error, :secret_pattern_detected} =
               SecretScanner.reject_if_secret_pattern(openai_fixture(), %{}, "tool", "body", dir: audit_dir)

      assert [%{"event_type" => "refused_agent_action", "reason" => "secret_pattern_detected", "tool" => "tool"}] =
               audit_events(audit_dir)

      log =
        capture_log(fn ->
          assert {:error, :secret_pattern_detected} =
                   SecretScanner.reject_if_secret_pattern(openai_fixture(), %{}, "tool", "body", dir: blocked_audit_path)
        end)

      assert log =~ "Audit log failed to record secret-pattern rejection"
      refute log =~ openai_fixture()
    after
      File.rm_rf(workspace)
    end
  end

  test "create_pull_request passes draft flag when requested" do
    workspace = tmp_workspace!("github-agent-create-draft")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/RSM-3051\n", 0}
      end

      gh_runner = fn
        [
          "pr",
          "create",
          "--repo",
          "acme/symphony",
          "--head",
          "auto/RSM-3051",
          "--title",
          "Title",
          "--body",
          "Body",
          "--draft"
        ],
        opts ->
          assert opts[:cd] == workspace
          {"https://github.com/acme/symphony/pull/3051\n", 0}
      end

      assert {:ok, %{"draft" => true, "head" => "auto/RSM-3051"}} =
               GitHub.create_pull_request(scoped_context(workspace), "Title", "Body", true,
                 git_runner: git_runner,
                 gh_runner: gh_runner
               )
    after
      File.rm_rf(workspace)
    end
  end

  test "current branch detection rejects empty and detached heads" do
    workspace = tmp_workspace!("github-agent-branch-errors")

    try do
      empty_branch_runner = fn
        ["branch", "--show-current"], _opts -> {"\n", 0}
      end

      detached_runner = fn
        ["branch", "--show-current"], _opts -> {"HEAD\n", 0}
      end

      assert {:error, :missing_current_branch} =
               GitHub.push_branch(scoped_context(workspace), git_runner: empty_branch_runner)

      assert {:error, :detached_head} =
               GitHub.push_branch(scoped_context(workspace), git_runner: detached_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "push_branch handles supported git runner return shapes" do
    workspace = tmp_workspace!("github-agent-git-runner-shapes")

    try do
      ok_tuple_runner = fn
        ["branch", "--show-current"], _opts -> {:ok, "auto/RSM-3051\n"}
        ["push", "origin", "auto/RSM-3051"], _opts -> {:ok, "pushed\n"}
      end

      error_tuple_runner = fn
        ["branch", "--show-current"], _opts -> {:error, :git_boom}
      end

      nonzero_runner = fn
        ["branch", "--show-current"], _opts -> {"auto/RSM-3051\n", 0}
        ["push", "origin", "auto/RSM-3051"], _opts -> {"rejected\n", 1}
      end

      raising_runner = fn _args, _opts -> :erlang.error(:enoent) end

      assert {:ok, %{"output" => "pushed"}} =
               GitHub.push_branch(scoped_context(workspace), git_runner: ok_tuple_runner)

      assert {:error, :git_boom} =
               GitHub.push_branch(scoped_context(workspace), git_runner: error_tuple_runner)

      assert {:error, {:git_failed, ["push", "origin", "auto/RSM-3051"], 1, "rejected\n"}} =
               GitHub.push_branch(scoped_context(workspace), git_runner: nonzero_runner)

      assert {:error, {:git_unavailable, _message}} =
               GitHub.push_branch(scoped_context(workspace), git_runner: raising_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "push_branch can use the default git runner" do
    workspace = tmp_workspace!("github-agent-default-git-runner")

    try do
      {_output, 0} = System.cmd("git", ["init"], cd: workspace, stderr_to_stdout: true)

      assert {:error, {:git_failed, ["push", "origin", _branch], _status, _output}} =
               GitHub.push_branch(scoped_context(workspace))
    after
      File.rm_rf(workspace)
    end
  end

  test "pull request payload failures are surfaced" do
    workspace = tmp_workspace!("github-agent-pr-payload-errors")

    try do
      git_runner = branch_runner(workspace)

      list_payload_runner = fn
        ["pr", "view", "auto/RSM-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {"[]", 0}
      end

      invalid_json_runner = fn
        ["pr", "view", "auto/RSM-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {"not json", 0}
      end

      gh_error_runner = fn
        ["pr", "view", "auto/RSM-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {:error, :gh_failed}
      end

      assert {:error, :invalid_pull_request_payload} =
               GitHub.get_pull_request(scoped_context(workspace),
                 git_runner: git_runner,
                 gh_runner: list_payload_runner
               )

      assert {:error, {:invalid_pull_request_payload, _message}} =
               GitHub.get_pull_request(scoped_context(workspace),
                 git_runner: git_runner,
                 gh_runner: invalid_json_runner
               )

      assert {:error, :gh_failed} =
               GitHub.get_pull_request(scoped_context(workspace), git_runner: git_runner, gh_runner: gh_error_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "pull request lookup preserves enterprise host in repo selector" do
    workspace = tmp_workspace!("github-agent-enterprise-host")

    try do
      gh_runner = fn
        ["pr", "view", "auto/RSM-3051", "--repo", "github.example.com/acme/symphony", "--json", _fields], opts ->
          assert opts[:cd] == workspace
          {Jason.encode!(%{"number" => 3051, "url" => "https://github.example.com/acme/symphony/pull/3051"}), 0}
      end

      context = %{
        workspace: workspace,
        command_security: %{
          origin_repo: "acme/symphony",
          origin_gh_repo: "github.example.com/acme/symphony",
          workspace: workspace
        }
      }

      assert {:ok, %{"url" => "https://github.example.com/acme/symphony/pull/3051"}} =
               GitHub.get_pull_request(context, git_runner: branch_runner(workspace), gh_runner: gh_runner)
    after
      File.rm_rf(workspace)
    end
  end

  test "pull request write and check tools require a resolved PR URL" do
    workspace = tmp_workspace!("github-agent-missing-pr-url")

    try do
      gh_runner = fn
        ["pr", "view", "auto/RSM-3051", "--repo", "acme/symphony", "--json", _fields], _opts ->
          {Jason.encode!(%{"number" => 3051, "headRefName" => "auto/RSM-3051"}), 0}
      end

      opts = [git_runner: branch_runner(workspace), gh_runner: gh_runner]

      assert {:error, :missing_pull_request_url} =
               GitHub.update_pull_request_body(scoped_context(workspace), "Body", opts)

      assert {:error, :missing_pull_request_url} =
               GitHub.add_pr_comment(scoped_context(workspace), "Body", opts)

      assert {:error, :missing_pull_request_url} =
               GitHub.get_pr_checks(scoped_context(workspace), opts)
    after
      File.rm_rf(workspace)
    end
  end

  defp scoped_context(workspace) do
    %{workspace: workspace, command_security: %{origin_repo: "acme/symphony", workspace: workspace}}
  end

  defp branch_runner(workspace) do
    fn
      ["branch", "--show-current"], opts ->
        assert opts[:cd] == workspace
        {"auto/RSM-3051\n", 0}
    end
  end

  defp tmp_workspace!(name) do
    workspace = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end

  defp secret_fixtures do
    [
      "sk-ant-" <> String.duplicate("a", 24),
      openai_fixture(),
      "ghp_" <> String.duplicate("A", 24),
      "ghu_" <> String.duplicate("B", 24),
      "gho_" <> String.duplicate("C", 24),
      "ghs_" <> String.duplicate("D", 24),
      "ghr_" <> String.duplicate("E", 24),
      "AKIA" <> String.duplicate("A", 16),
      "ASIA" <> String.duplicate("B", 16),
      "AIza" <> String.duplicate("A", 35)
    ]
  end

  defp openai_fixture, do: "sk-" <> String.duplicate("a", 24)

  defp audit_events(dir) do
    dir
    |> Path.join("*.ndjson")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end)
  end
end
