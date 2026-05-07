defmodule SymphonyElixir.GitHub.PullRequestTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.PullRequest

  test "fetch_activity separates review timestamps from PR updates and supports enterprise hosts" do
    pr_url = "https://github.example.com/org/repo/pull/42"

    runner = fn
      ["pr", "view", ^pr_url, "--json", fields], opts ->
        assert fields == "number,state,reviewDecision,updatedAt,comments,reviews,title,body,url"
        assert opts[:stderr_to_stdout]

        {Jason.encode!(%{
           "number" => 42,
           "title" => "Ship review polling",
           "body" => "PR body",
           "state" => "OPEN",
           "reviewDecision" => "APPROVED",
           "updatedAt" => "2026-05-01T10:00:00Z",
           "comments" => [],
           "reviews" => [
             %{
               "id" => "PRR_kw1",
               "author" => %{"login" => "reviewer"},
               "body" => "Looks good.",
               "url" => "#{pr_url}#pullrequestreview-1",
               "state" => "APPROVED",
               "submittedAt" => "2026-05-01T09:00:00Z"
             }
           ],
           "url" => pr_url
         }), 0}

      ["api", "--hostname", "github.example.com", "repos/org/repo/pulls/42/comments"], opts ->
        assert opts[:stderr_to_stdout]

        {Jason.encode!([
           %{
             "id" => 123,
             "user" => %{"login" => "reviewer"},
             "body" => "Nit fixed separately.",
             "html_url" => "#{pr_url}#discussion_r1",
             "path" => "lib/example.ex",
             "line" => 42,
             "created_at" => "2026-05-01T09:03:00Z",
             "updated_at" => "2026-05-01T09:05:00Z"
           }
         ]), 0}
    end

    assert {:ok, activity} = PullRequest.fetch_activity(pr_url, gh_runner: runner)

    assert activity.pr_url == pr_url
    assert activity.pr_number == 42
    assert activity.pr_title == "Ship review polling"
    assert activity.pr_description == "PR body"
    assert activity.state == "OPEN"
    assert activity.review_decision == "APPROVED"
    assert activity.latest_activity_at == ~U[2026-05-01 10:00:00Z]
    assert activity.latest_review_activity_at == ~U[2026-05-01 09:05:00Z]
    assert Enum.map(activity.comments, & &1.kind) == ["review", "inline_comment"]
    assert Enum.map(activity.comments, & &1.id) == ["PRR_kw1", "123"]
    assert List.last(activity.comments).path == "lib/example.ex"
    assert List.last(activity.comments).line == 42
  end

  test "fetch_activity ignores a stale cwd when the workspace was already removed" do
    pr_url = "https://github.com/org/repo/pull/17"
    missing_cwd = Path.join(System.tmp_dir!(), "missing-symphony-workspace-#{System.unique_integer([:positive])}")

    runner = fn
      ["pr", "view", ^pr_url, "--json", _fields], opts ->
        refute Keyword.has_key?(opts, :cd)

        {Jason.encode!(%{
           "number" => 17,
           "state" => "MERGED",
           "reviewDecision" => nil,
           "updatedAt" => "2026-05-05T09:34:09Z",
           "comments" => [],
           "reviews" => [],
           "url" => pr_url
         }), 0}

      ["api", "repos/org/repo/pulls/17/comments"], opts ->
        refute Keyword.has_key?(opts, :cd)

        {Jason.encode!([]), 0}
    end

    assert {:ok, activity} = PullRequest.fetch_activity(pr_url, cwd: missing_cwd, gh_runner: runner)
    assert activity.state == "MERGED"
  end

  test "fetch_ci_status reads status rollup and failed GitHub Actions run ids" do
    pr_url = "https://github.com/org/repo/pull/17"

    runner = fn
      ["pr", "view", ^pr_url, "--json", fields], opts ->
        assert fields == "number,state,title,url,headRefOid,statusCheckRollup"
        assert opts[:stderr_to_stdout]

        {Jason.encode!(%{
           "state" => "OPEN",
           "title" => "Fix CI",
           "url" => pr_url,
           "headRefOid" => "abc123",
           "statusCheckRollup" => [
             %{
               "name" => "test",
               "status" => "COMPLETED",
               "conclusion" => "FAILURE",
               "detailsUrl" => "https://github.com/org/repo/actions/runs/987/jobs/654",
               "workflowName" => "CI"
             }
           ]
         }), 0}
    end

    assert {:ok, status} = PullRequest.fetch_ci_status(pr_url, gh_runner: runner)
    assert status.pr_url == pr_url
    assert status.pr_title == "Fix CI"
    assert status.commit_sha == "abc123"
    assert [%{name: "test", conclusion: "FAILURE", run_id: "987"}] = status.checks
  end

  test "fetch_failed_log and rerun_failed use gh run commands" do
    runner = fn
      ["run", "view", "987", "--log-failed"], opts ->
        assert opts[:stderr_to_stdout]
        {"failed log", 0}

      ["run", "rerun", "987", "--failed"], opts ->
        assert opts[:stderr_to_stdout]
        {"", 0}
    end

    assert {:ok, "failed log"} = PullRequest.fetch_failed_log("987", gh_runner: runner)
    assert :ok = PullRequest.rerun_failed("987", gh_runner: runner)
  end

  test "reply_to_comment posts inline replies and request_review re-requests reviewers" do
    pr_url = "https://github.example.com/org/repo/pull/42"

    runner = fn
      ["api", "--hostname", "github.example.com", "repos/org/repo/pulls/42/comments/123/replies", "-f", "body=Addressed."], opts ->
        assert opts[:stderr_to_stdout]
        {"{}", 0}

      ["pr", "edit", ^pr_url, "--add-reviewer", "reviewer", "--add-reviewer", "maintainer"], opts ->
        assert opts[:stderr_to_stdout]
        {"", 0}
    end

    assert :ok =
             PullRequest.reply_to_comment(
               pr_url,
               %{id: "123", kind: "inline_comment"},
               "Addressed.",
               gh_runner: runner
             )

    assert :ok = PullRequest.request_review(pr_url, ["reviewer", "reviewer", "maintainer"], gh_runner: runner)
  end

  test "reply_to_comment can fall back to an inline comment node id" do
    pr_url = "https://github.example.com/org/repo/pull/42"

    runner = fn
      ["api", "--hostname", "github.example.com", "repos/org/repo/pulls/42/comments/PRRC_kwDO/replies", "-f", "body=Addressed."], opts ->
        assert opts[:stderr_to_stdout]
        {"{}", 0}
    end

    assert :ok =
             PullRequest.reply_to_comment(
               pr_url,
               %{node_id: "PRRC_kwDO", kind: "inline_comment"},
               "Addressed.",
               gh_runner: runner
             )
  end
end
