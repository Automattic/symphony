defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Agent, StringOrMap}
  alias SymphonyElixir.Config.Schema.Verification.DevServer, as: DevServerConfig
  alias SymphonyElixir.Config.Schema.Workspace.Lifecycle, as: WorkspaceLifecycle
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Secret

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy creates reuses and removes issue worktrees" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      origin_repo = Path.join(test_root, "origin.git")
      peer_repo = Path.join(test_root, "peer")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo, origin_repo)
      {_output, 0} = System.cmd("git", ["clone", origin_repo, peer_repo])
      configure_git_user!(peer_repo)
      File.write!(Path.join(peer_repo, "remote.txt"), "remote update\n")
      git!(peer_repo, ["add", "remote.txt"])
      git!(peer_repo, ["commit", "-m", "remote update"])
      git!(peer_repo, ["push", "origin", "main"])
      new_origin_head = git!(peer_repo, ["rev-parse", "HEAD"]) |> String.trim()

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        hook_after_create: "echo after_create >> hook.count"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-WT")

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "default", "MT-WT"]))

      assert workspace == expected_workspace
      assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
      refute File.exists?(Path.join(workspace, "remote.txt"))
      assert String.trim(File.read!(Path.join(workspace, "hook.count"))) == "after_create"
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "auto/MT-WT"
      assert git_branch_exists?(primary_repo, "auto/MT-WT")
      assert String.trim(git!(primary_repo, ["rev-parse", "origin/main"])) == new_origin_head

      assert {:ok, ^workspace} = Workspace.create_for_issue("MT-WT")
      assert String.trim(File.read!(Path.join(workspace, "hook.count"))) == "after_create"

      assert :ok = Workspace.remove_issue_workspaces("MT-WT")
      refute File.exists?(workspace)
      refute git_branch_exists?(primary_repo, "auto/MT-WT")
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy can skip fetch before dispatch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-no-fetch-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-NO-FETCH")
      assert File.read!(Path.join(workspace, "README.md")) == "initial\n"

      assert :ok = Workspace.remove_issue_workspaces("MT-NO-FETCH")
    after
      File.rm_rf(test_root)
    end
  end

  test "repo-level worktree settings select the matched repo primary clone" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-repo-worktree-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "api-primary")
      workflow_dir = Path.join(test_root, "api-workflow")
      workflow_path = Path.join(workflow_dir, "WORKFLOW.md")
      workspace_root = Path.join(test_root, "workspaces")

      create_primary_repo!(primary_repo)
      File.mkdir_p!(workflow_dir)

      File.write!(workflow_path, """
      ---
      hooks:
        after_create: echo api > repo-hook.txt
      ---
      API prompt
      """)

      File.write!(Workflow.symphony_file_path(), """
      tracker:
        kind: memory
      workspace:
        root: #{workspace_root}
      agent:
        kind: codex
        command: codex app-server
      repos:
        - name: api
          workflow: #{workflow_path}
          team: Test
          workspace:
            strategy: worktree
            repo: #{primary_repo}
            fetch_before_dispatch: false
      """)

      issue = %Issue{id: "api-issue", identifier: "API-WT", repo_key: "api"}

      assert :ok = Config.validate!()
      assert {:ok, workspace} = Workspace.create_for_issue(issue)

      assert {:ok, expected_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([workspace_root, "api", "API-WT"]))

      assert workspace == expected_workspace
      assert File.read!(Path.join(workspace, "README.md")) == "initial\n"
      assert File.read!(Path.join(workspace, "repo-hook.txt")) == "api\n"
      assert String.trim(git!(workspace, ["branch", "--show-current"])) == "auto/API-WT"
      assert git_branch_exists?(primary_repo, "auto/API-WT")

      assert :ok = Workspace.remove_issue_workspaces(issue)
      refute File.exists?(workspace)
      refute git_branch_exists?(primary_repo, "auto/API-WT")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace lifecycle config has conservative defaults and parses overrides" do
    lifecycle = Config.settings!().workspace.lifecycle

    assert lifecycle.age_gc_enabled == true
    assert lifecycle.max_age_days == 14
    assert lifecycle.gc_interval_ms == 3_600_000
    assert lifecycle.min_free_bytes == nil
    assert lifecycle.orphan_action == "log"
    assert lifecycle.trash_dir == ".trash"

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_lifecycle: %{
        age_gc_enabled: false,
        max_age_days: 3,
        gc_interval_ms: 5_000,
        min_free_bytes: 1_048_576,
        orphan_action: "trash",
        trash_dir: ".workspace-trash"
      }
    )

    lifecycle = Config.settings!().workspace.lifecycle

    assert lifecycle.age_gc_enabled == false
    assert lifecycle.max_age_days == 3
    assert lifecycle.gc_interval_ms == 5_000
    assert lifecycle.min_free_bytes == 1_048_576
    assert lifecycle.orphan_action == "trash"
    assert lifecycle.trash_dir == ".workspace-trash"

    blank_trash_dir =
      %WorkspaceLifecycle{}
      |> WorkspaceLifecycle.changeset(%{trash_dir: " "})
      |> Changeset.apply_changes()

    assert blank_trash_dir.trash_dir == ".trash"

    nil_trash_dir =
      %WorkspaceLifecycle{}
      |> WorkspaceLifecycle.changeset(%{trash_dir: nil})
      |> Changeset.apply_changes()

    assert nil_trash_dir.trash_dir == ".trash"
  end

  test "dependency allow-list config defaults and normalizes entries" do
    assert Config.settings!().dependencies.allow_registries == []
    assert Config.settings!().dependencies.allow_git_sources == []
    assert Config.settings!().dependencies.allow_path_sources == []

    write_workflow_file!(Workflow.workflow_file_path(),
      dependencies: %{
        allow_registries: [" private-hex.internal ", "", "private-hex.internal"],
        allow_git_sources: [" github.com/acme/* ", "github.com/acme/*"],
        allow_path_sources: nil
      }
    )

    dependencies = Config.settings!().dependencies

    assert dependencies.allow_registries == ["private-hex.internal"]
    assert dependencies.allow_git_sources == ["github.com/acme/*"]
    assert dependencies.allow_path_sources == []

    nil_allow_list =
      %Schema.Dependencies{allow_path_sources: ["../old"]}
      |> Schema.Dependencies.changeset(%{allow_path_sources: nil})
      |> Changeset.apply_changes()

    assert nil_allow_list.allow_path_sources == []
  end

  test "workspace lifecycle rejects unsafe trash directories" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_lifecycle: %{orphan_action: "trash", trash_dir: "../outside"}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.settings()
    assert message =~ "trash_dir"
    assert message =~ "must not contain parent directory segments"
  end

  test "workspace age GC removes stale workspaces while protecting active identifiers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-age-gc-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      stale_workspace = Path.join([workspace_root, "default", "MT-STALE"])
      protected_workspace = Path.join([workspace_root, "default", "MT-RUNNING"])
      recent_workspace = Path.join([workspace_root, "default", "MT-RECENT"])
      other_repo_workspace = Path.join([workspace_root, "other", "MT-OTHER-STALE"])

      Enum.each([stale_workspace, protected_workspace, recent_workspace, other_repo_workspace], &File.mkdir_p!/1)
      old_timestamp = {{2026, 1, 1}, {0, 0, 0}}
      File.touch!(stale_workspace, old_timestamp)
      File.touch!(protected_workspace, old_timestamp)
      File.touch!(other_repo_workspace, old_timestamp)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_lifecycle: %{max_age_days: 14}
      )

      now = DateTime.new!(~D[2026-01-20], ~T[00:00:00], "Etc/UTC")

      assert {:ok, actions} = Workspace.reclaim_stale_workspaces(["MT-RUNNING"], now)

      assert Enum.any?(actions, &match?(%{identifier: "MT-STALE", action: :deleted, reason: :age_gc}, &1))
      refute File.exists?(stale_workspace)
      assert File.exists?(protected_workspace)
      assert File.exists?(recent_workspace)
      assert File.exists?(other_repo_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "startup orphan sweep can delete untracked workspace directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-orphan-sweep-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      tracked_workspace = Path.join([workspace_root, "default", "MT-TRACKED"])
      orphan_workspace = Path.join([workspace_root, "default", "MT-ORPHAN"])
      other_repo_orphan = Path.join([workspace_root, "other", "MT-ORPHAN"])

      File.mkdir_p!(tracked_workspace)
      File.mkdir_p!(orphan_workspace)
      File.mkdir_p!(other_repo_orphan)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_lifecycle: %{orphan_action: "delete"}
      )

      assert {:ok, actions} = Workspace.sweep_orphan_workspaces(["MT-TRACKED"])

      assert Enum.any?(actions, &match?(%{identifier: "MT-ORPHAN", action: :deleted, reason: :orphan}, &1))
      assert File.exists?(tracked_workspace)
      refute File.exists?(orphan_workspace)
      assert File.exists?(other_repo_orphan)

      assert {:ok, other_actions} = Workspace.sweep_orphan_workspaces("other", [])
      assert Enum.any?(other_actions, &match?(%{repo_key: "other", identifier: "MT-ORPHAN", action: :deleted, reason: :orphan}, &1))
      refute File.exists?(other_repo_orphan)
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree strategy rejects existing directories that are not registered worktrees" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-stale-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      stale_workspace = Path.join([workspace_root, "default", "MT-STALE"])

      create_primary_repo!(primary_repo)
      File.mkdir_p!(stale_workspace)
      File.write!(Path.join(stale_workspace, "stale.txt"), "manual directory\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      assert {:ok, expected_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)

      assert {:error, {:workspace_not_registered_worktree, ^expected_workspace}} =
               Workspace.create_for_issue("MT-STALE")

      assert File.read!(Path.join(stale_workspace, "stale.txt")) == "manual directory\n"
      refute git_branch_exists?(primary_repo, "auto/MT-STALE")
    after
      File.rm_rf(test_root)
    end
  end

  test "worktree registration checks warn when git worktree list fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-worktree-list-fail-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "not-git")
      workspace_root = Path.join(test_root, "workspaces")
      stale_workspace = Path.join([workspace_root, "default", "MT-WT-LIST-FAIL"])

      File.mkdir_p!(primary_repo)
      File.mkdir_p!(stale_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: primary_repo,
        workspace_fetch_before_dispatch: false
      )

      log =
        capture_log(fn ->
          assert {:error, {:workspace_not_registered_worktree, _workspace}} =
                   Workspace.create_for_issue("MT-WT-LIST-FAIL")
        end)

      assert log =~ "Git worktree list failed"
      assert log =~ primary_repo
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(Path.dirname(first_workspace)) == "default"
    assert Path.basename(first_workspace) == "MT_Det"
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join([workspace_root, "default", "MT-STALE"])
      File.mkdir_p!(Path.dirname(stale_workspace))
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join([workspace_root, "default", "MT-SYM"])

      File.mkdir_p!(Path.dirname(symlink_path))
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_outside_root} = SymphonyElixir.PathSafety.canonicalize(outside_root)
      assert {:ok, canonical_workspace_root} = SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_outside_root, ^canonical_outside_root, ^canonical_workspace_root}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join([actual_root, "default", "MT-LINK"]))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error, {:workspace_hook_failed, "after_create", 17, _output}} =
               Workspace.create_for_issue("MT-FAIL")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join([workspace_root, "default", "MT-608"])
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join([workspace_root, "default", "S_1"])
      untouched_workspace = Path.join([workspace_root, "default", "OTHER-#{System.unique_integer([:positive])}"])

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "attachments" => %{
        "nodes" => [
          %{
            "title" => "Pull Request #123",
            "url" => "https://github.com/example/repo/pull/123",
            "sourceType" => "github"
          },
          %{
            "title" => "Pull Request #124",
            "url" => "https://github.example.com/org/repo/pull/124",
            "sourceType" => "github"
          },
          %{
            "title" => "Design",
            "url" => "https://example.org/design",
            "sourceType" => "figma"
          }
        ]
      },
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "comments" => %{
        "nodes" => [
          %{
            "body" => "Clarifying answer",
            "createdAt" => "2026-01-01T01:00:00Z",
            "user" => %{"name" => "Reviewer"}
          }
        ]
      },
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.comments == [%{author: "Reviewer", body: "Clarifying answer", created_at: ~U[2026-01-01 01:00:00Z]}]
    assert issue.priority == 2
    assert issue.state == "Todo"

    assert issue.pr_urls == [
             "https://github.com/example/repo/pull/123",
             "https://github.example.com/org/repo/pull/124"
           ]

    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client extracts GitHub pull request attachment URLs" do
    raw_issue = %{
      "id" => "issue-pr",
      "identifier" => "MT-PR",
      "title" => "Reviewable issue",
      "state" => %{"name" => "In Review"},
      "attachments" => %{
        "nodes" => [
          %{
            "sourceType" => "github",
            "url" => "https://github.com/example/repo/issues/1"
          },
          %{
            "sourceType" => "github",
            "url" => "https://github.com/example/repo/pull/42"
          }
        ]
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue)

    assert issue.pull_request_url == "https://github.com/example/repo/pull/42"
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client sends configured assignee in candidate filter" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "user-1")

    graphql_fun = fn query, variables ->
      send(self(), {:candidate_query, query, variables})

      {:ok, linear_page_response([raw_linear_issue("issue-1", "MT-1", "user-1")])}
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(graphql_fun)

    assert Enum.map(issues, & &1.identifier) == ["MT-1"]
    assert Enum.all?(issues, & &1.assigned_to_worker)

    assert_receive {:candidate_query, query, variables}

    assert query =~ "SymphonyLinearPoll"
    assert query =~ "$filter: IssueFilter!"
    assert query =~ "issues(filter: $filter"
    assert query =~ "comments(last: $commentLast, orderBy: createdAt)"

    assert variables == %{
             filter: %{
               "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
               "project" => %{"slugId" => %{"eq" => "project"}},
               "team" => %{"key" => %{"eq" => "Test"}},
               "assignee" => %{"id" => %{"in" => ["user-1"]}}
             },
             first: 50,
             relationFirst: 50,
             attachmentFirst: 20,
             commentLast: 20,
             after: nil
           }
  end

  test "linear client normalizes team and project from graphql responses" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "token")

    raw_issue =
      raw_linear_issue("issue-1", "MT-1", "user-1")
      |> Map.merge(%{
        "team" => %{"key" => "RSM", "name" => "Radical Speed Month"},
        "project" => %{"id" => "project-1", "name" => "Multi-repo support"}
      })

    graphql_fun = fn query, variables ->
      send(self(), {:candidate_query, query, variables})

      {:ok, linear_page_response([raw_issue])}
    end

    assert {:ok, [issue]} = Client.fetch_candidate_issues_for_test(graphql_fun)

    assert issue.team == %{key: "RSM", name: "Radical Speed Month"}
    assert issue.project == %{id: "project-1", name: "Multi-repo support"}

    assert_receive {:candidate_query, query, _variables}
    assert query =~ ~r/team\s*\{\s*key\s*name\s*\}/
    assert query =~ ~r/project\s*\{\s*id\s*name\s*\}/
  end

  test "linear client resolves assignee me before sending candidate filter" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "me")

    graphql_fun = fn query, variables ->
      if query =~ "SymphonyLinearViewer" do
        send(self(), {:viewer_query, variables})
        {:ok, %{"data" => %{"viewer" => %{"id" => "user-2"}}}}
      else
        send(self(), {:candidate_query, variables})
        {:ok, linear_page_response([raw_linear_issue("issue-2", "MT-2", "user-2")])}
      end
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(graphql_fun)

    assert Enum.map(issues, & &1.identifier) == ["MT-2"]

    assert_receive {:viewer_query, %{}}
    assert_receive {:candidate_query, variables}
    assert get_in(variables, [:filter, "assignee", "id", "in"]) == ["user-2"]
  end

  test "linear client fails loud when assignee filter shape drifts" do
    assert Client.assignee_filter_ids_for_test(nil) == nil
    assert Client.assignee_filter_ids_for_test(%{match_values: MapSet.new(["user-2", "user-1"])}) == ["user-1", "user-2"]

    assert_raise FunctionClauseError, fn ->
      Client.assignee_filter_ids_for_test(%{matches: MapSet.new(["user-1"])})
    end
  end

  test "linear client sends team key in candidate filter" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team: "RSM"
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
             "team" => %{"key" => %{"eq" => "RSM"}}
           }

    refute Map.has_key?(variables.filter, "project")
    refute Map.has_key?(variables.filter, "labels")
    refute Map.has_key?(variables.filter, "assignee")
  end

  test "linear client sends team id in candidate filter for UUID team" do
    team_id = "a42df4c4-7416-4a08-8fb2-97087043169f"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team: team_id
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
             "team" => %{"id" => %{"eq" => team_id}}
           }
  end

  test "linear client sends uppercase UUID team as id in candidate filter" do
    team_id = "A42DF4C4-7416-4A08-8FB2-97087043169F"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team: team_id
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
             "team" => %{"id" => %{"eq" => team_id}}
           }
  end

  test "linear client does not treat loose 36 character team values as ids" do
    team = "------------------------------------"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team: team
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
             "team" => %{"key" => %{"eq" => team}}
           }
  end

  test "linear client sends single and multiple labels with OR semantics" do
    for labels <- [["backend"], ["backend", "infra"]] do
      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_project_slug: nil,
        tracker_labels: labels
      )

      variables = capture_candidate_variables!()

      assert variables.filter == %{
               "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
               "team" => %{"key" => %{"eq" => "Test"}},
               "labels" => %{"some" => %{"name" => %{"in" => labels}}}
             }
    end
  end

  test "linear client omits empty labels from candidate filter" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team: "RSM",
      tracker_labels: []
    )

    variables = capture_candidate_variables!()

    refute Map.has_key?(variables.filter, "labels")
    refute Enum.any?(variables.filter, fn {_key, value} -> is_nil(value) end)
  end

  test "linear client normalizes blank candidate scope values before building filter" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: " ",
      tracker_team: " RSM ",
      tracker_labels: ["", " backend ", " "]
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
             "team" => %{"key" => %{"eq" => "RSM"}},
             "labels" => %{"some" => %{"name" => %{"in" => ["backend"]}}}
           }

    refute Map.has_key?(variables.filter, "project")
  end

  test "linear client combines configured candidate filter dimensions" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_team: "RSM",
      tracker_labels: ["backend"],
      tracker_assignee: "user-1"
    )

    variables = capture_candidate_variables!()

    assert variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
             "project" => %{"slugId" => %{"eq" => "project"}},
             "team" => %{"key" => %{"eq" => "RSM"}},
             "labels" => %{"some" => %{"name" => %{"in" => ["backend"]}}},
             "assignee" => %{"id" => %{"in" => ["user-1"]}}
           }
  end

  test "linear client sends one isolated server-side candidate filter per repo" do
    repo_root = Path.dirname(Workflow.workflow_file_path())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: "legacy-project",
      tracker_team: "LEGACY",
      tracker_labels: ["legacy"],
      tracker_assignee: "legacy-user",
      repos: [
        %{
          "name" => "web",
          "path" => repo_root,
          "workflow" => "WORKFLOW.md",
          "team" => "RSM",
          "projects" => ["Project Alpha"],
          "labels" => ["web"],
          "assignee" => "user-web"
        },
        %{
          "name" => "api",
          "path" => repo_root,
          "workflow" => "WORKFLOW.md",
          "team" => "RSM",
          "projects" => ["Project Beta"],
          "labels" => ["api"],
          "assignee" => "user-api"
        }
      ]
    )

    graphql_fun = fn query, variables ->
      send(self(), {:candidate_query, query, variables})

      issue =
        case get_in(variables, [:filter, "assignee", "id", "in"]) do
          ["user-web"] -> raw_linear_issue("issue-web", "RSM-WEB", "user-web")
          ["user-api"] -> raw_linear_issue("issue-api", "RSM-API", "user-api")
        end

      {:ok, linear_page_response([issue])}
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert Enum.map(issues, &{&1.identifier, &1.repo_key}) == [{"RSM-API", "api"}, {"RSM-WEB", "web"}]

    assert_receive {:candidate_query, query, web_variables}
    assert_receive {:candidate_query, ^query, api_variables}

    assert web_variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
             "project" => %{
               "or" => [
                 %{"name" => %{"in" => ["Project Alpha"]}},
                 %{"slugId" => %{"in" => ["Project Alpha"]}}
               ]
             },
             "team" => %{"key" => %{"eq" => "RSM"}},
             "labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "web"}}},
             "assignee" => %{"id" => %{"in" => ["user-web"]}}
           }

    assert api_variables.filter == %{
             "state" => %{"name" => %{"in" => ["Todo", "In Progress"]}},
             "project" => %{
               "or" => [
                 %{"name" => %{"in" => ["Project Beta"]}},
                 %{"slugId" => %{"in" => ["Project Beta"]}}
               ]
             },
             "team" => %{"key" => %{"eq" => "RSM"}},
             "labels" => %{"some" => %{"name" => %{"eqIgnoreCase" => "api"}}},
             "assignee" => %{"id" => %{"in" => ["user-api"]}}
           }

    refute inspect([web_variables.filter, api_variables.filter]) =~ "legacy"
  end

  test "linear client state reconciliation keeps partial repo successes when one repo errors" do
    repo_root = Path.dirname(Workflow.workflow_file_path())

    write_workflow_file!(Workflow.workflow_file_path(),
      repos: [
        %{
          "name" => "web",
          "path" => repo_root,
          "workflow" => "WORKFLOW.md",
          "team" => "RSM",
          "labels" => ["web"]
        },
        %{
          "name" => "api",
          "path" => repo_root,
          "workflow" => "WORKFLOW.md",
          "team" => "RSM",
          "labels" => ["api"]
        }
      ]
    )

    graphql_fun = fn query, variables ->
      send(self(), {:state_query, query, variables})

      case get_in(variables, [:filter, "labels", "some", "name", "eqIgnoreCase"]) do
        "web" ->
          issue =
            raw_linear_issue("issue-web", "RSM-WEB")
            |> Map.put("state", %{"name" => "In Progress"})

          {:ok, linear_page_response([issue])}

        "api" ->
          {:error, :linear_unavailable}
      end
    end

    assert {:ok, issues} = Client.fetch_issues_by_states_for_test(["In Progress"], graphql_fun)

    assert Enum.map(issues, &{&1.identifier, &1.repo_key}) == [{"RSM-WEB", "web"}]
    assert_receive {:state_query, query, web_variables}
    assert_receive {:state_query, ^query, api_variables}
    assert get_in(web_variables, [:filter, "labels", "some", "name", "eqIgnoreCase"]) == "web"
    assert get_in(api_variables, [:filter, "labels", "some", "name", "eqIgnoreCase"]) == "api"
  end

  test "linear client repeats candidate filter while paginating" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_project_slug: nil,
      tracker_team: "RSM",
      tracker_labels: ["backend"]
    )

    graphql_fun = fn query, variables ->
      send(self(), {:candidate_page, query, variables})

      case variables.after do
        nil ->
          {:ok,
           linear_page_response([raw_linear_issue("issue-1", "MT-1")], %{
             "hasNextPage" => true,
             "endCursor" => "cursor-1"
           })}

        "cursor-1" ->
          {:ok, linear_page_response([raw_linear_issue("issue-2", "MT-2")])}
      end
    end

    assert {:ok, issues} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert Enum.map(issues, & &1.identifier) == ["MT-1", "MT-2"]

    assert_receive {:candidate_page, query, first_variables}
    assert_receive {:candidate_page, ^query, second_variables}

    assert first_variables[:after] == nil
    assert second_variables[:after] == "cursor-1"
    assert first_variables.filter == second_variables.filter
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids
    assert Enum.all?(issues, & &1.assigned_to_worker)

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"
    assert query =~ ~r/team\s*\{\s*key\s*name\s*\}/
    assert query =~ ~r/project\s*\{\s*id\s*name\s*\}/

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client refresh by id marks reassigned and unassigned issues as not routed to worker" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "user-1")

    raw_issues = [
      raw_linear_issue("issue-1", "MT-1", "user-2"),
      raw_linear_issue("issue-2", "MT-2", nil),
      raw_linear_issue("issue-3", "MT-3", "user-1")
    ]

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})
      {:ok, %{"data" => %{"issues" => %{"nodes" => raw_issues}}}}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(["issue-1", "issue-2", "issue-3"], graphql_fun)

    assert Enum.map(issues, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
    assert Enum.map(issues, & &1.assigned_to_worker) == [false, false, true]

    assert_receive {:fetch_issue_states_page, query, %{ids: ["issue-1", "issue-2", "issue-3"], first: 3, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"
    assert query =~ "issues(filter: {id: {in: $ids}}"
  end

  test "linear client logs response bodies for non-200 graphql responses" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_api_token: "token")

    body = %{
      "errors" => [
        %{
          "message" => "Variable \"$ids\" got invalid value",
          "extensions" => %{"code" => "BAD_USER_INPUT"}
        }
      ]
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400, ^body}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers ->
                     {:ok,
                      %{
                        status: 400,
                        body: body
                      }}
                   end
                 )
      end)

    assert log =~ "Linear GraphQL request failed status=400"
    assert log =~ ~s(body=%{"errors" => [%{"extensions" => %{"code" => "BAD_USER_INPUT"})
    assert log =~ "Variable \\\"$ids\\\" got invalid value"
  end

  test "linear client redacts configured secrets from graphql request error logs" do
    token = "linear-secret-token"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: token,
      tracker_project_slug: "project"
    )

    reason = {:closed, %{headers: [{"authorization", "Bearer #{token}"}], body: "token=#{token}"}}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_request, ^reason}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   request_fun: fn _payload, _headers -> {:error, reason} end
                 )
      end)

    assert log =~ "Linear GraphQL request failed"
    refute log =~ token
    assert log =~ "[REDACTED]"
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "workspace remove returns error information for missing directory" do
    random_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-#{System.unique_integer([:positive])}"
      )

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "run hooks receive verification port env when provided" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-verification-env-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: "printf '%s' \"$SYMPHONY_VERIFICATION_PORT\" > before-port.txt",
        hook_after_run: "printf '%s' \"$SYMPHONY_VERIFICATION_PORT\" > after-port.txt"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-PORT-ENV")
      env = [{"SYMPHONY_VERIFICATION_PORT", "4077"}]

      assert :ok = Workspace.run_before_run_hook(workspace, "MT-PORT-ENV", nil, env: env)
      assert :ok = Workspace.run_after_run_hook(workspace, "MT-PORT-ENV", nil, env: env)

      assert File.read!(Path.join(workspace, "before-port.txt")) == "4077"
      assert File.read!(Path.join(workspace, "after-port.txt")) == "4077"
    after
      File.rm_rf(test_root)
    end
  end

  test "run hooks use repo_key option for identifier-only context" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-repo-key-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      api_repo = Path.join(test_root, "api")
      primary_marker = Path.join(test_root, "primary-after.log")
      api_marker = Path.join(test_root, "api-after.log")

      File.mkdir_p!(workspace)
      File.mkdir_p!(api_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        hook_after_run: "printf primary > #{primary_marker}",
        repos: [
          %{
            "name" => "default",
            "path" => Path.dirname(Workflow.workflow_file_path()),
            "workflow" => Path.basename(Workflow.workflow_file_path()),
            "team" => "Test",
            "default" => true
          },
          %{
            "name" => "api",
            "path" => api_repo,
            "workflow" => "WORKFLOW.md",
            "team" => "Test",
            "labels" => ["api"]
          }
        ]
      )

      File.write!(Path.join(api_repo, "WORKFLOW.md"), """
      ---
      hooks:
        after_run: printf api > #{api_marker}
      ---
      API prompt
      """)

      assert :ok = Workspace.run_after_run_hook(workspace, "MT-API", nil, repo_key: "api")

      assert File.read!(api_marker) == "api"
      refute File.exists?(primary_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace cleanup logs removal failures while keeping fire-and-forget API" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-remove-log-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.write!(Path.join(outside_workspace, "marker.txt"), "keep\n")
      escape_workspace = Path.join([workspace_root, "default", "MT-ESCAPE"])
      File.mkdir_p!(Path.dirname(escape_workspace))
      File.ln_s!(outside_workspace, escape_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      log =
        capture_log(fn ->
          assert :ok = Workspace.remove_issue_workspaces("MT-ESCAPE")
        end)

      assert log =~ "Workspace removal failed"
      assert log =~ "issue_identifier=MT-ESCAPE"
      assert log =~ "workspace_outside_root"
      assert File.exists?(Path.join(outside_workspace, "marker.txt"))
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    previous_timeout = Application.get_env(:symphony_elixir, :workspace_hook_timeout_ms)

    on_exit(fn ->
      if is_nil(previous_timeout) do
        Application.delete_env(:symphony_elixir, :workspace_hook_timeout_ms)
      else
        Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, previous_timeout)
      end
    end)

    Application.put_env(:symphony_elixir, :workspace_hook_timeout_ms, 10)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: nil,
      max_concurrent_agents: nil,
      agent_approval_policy: nil,
      agent_thread_sandbox: nil,
      agent_turn_sandbox_policy: nil,
      agent_turn_timeout_ms: nil,
      agent_read_timeout_ms: nil,
      agent_stall_timeout_ms: nil,
      agent_command_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.workspace.strategy == "clone"
    assert config.workspace.repo == nil
    assert config.workspace.fetch_before_dispatch
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.agent.max_tokens_per_issue == nil
    assert config.agent.max_tokens_per_day == nil
    assert config.agent.command == "codex app-server"

    assert config.agent.approval_policy == %{
             "reject" => %{
               "sandbox_approval" => true,
               "rules" => true,
               "mcp_elicitations" => true
             }
           }

    assert config.agent.thread_sandbox == "workspace-write"
    assert config.agent.network_access.mode == "allowlist"
    assert config.agent.network_access.allowed_domains == []
    assert config.agent.network_access.denied_domains == []

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.agent.turn_timeout_ms == 3_600_000
    assert config.agent.read_timeout_ms == 5_000
    assert config.agent.stall_timeout_ms == 300_000
    assert config.agent.command_timeout_ms == 600_000
    assert config.watchdog.enabled
    assert config.watchdog.tick_interval_ms == 60_000
    assert config.watchdog.no_progress_threshold_ms == 600_000
    assert config.server.port == nil
    assert config.server.host == "127.0.0.1"
    assert Config.server_port() == 0
    assert Config.server_host() == "127.0.0.1"
    assert config.verification.enabled == false
    assert config.verification.port_allocation.range == [4000, 4099]
    assert config.verification.dev_server.start_cmd == nil
    assert config.verification.dev_server.health_check_url == nil
    assert config.verification.dev_server.health_timeout_ms == 30_000
    assert config.verification.dev_server.stop_signal == "TERM"
    assert config.verification.dev_server.stop_timeout_ms == 10_000
    refute SymphonyElixir.Verification.PortPool in SymphonyElixir.Application.child_specs_for_runtime(%{})

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().agent.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{
        enabled: true,
        port_allocation: %{range: [4100, 4102]},
        dev_server: %{
          start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT",
          health_check_url: "http://localhost:${SYMPHONY_VERIFICATION_PORT}/healthz",
          health_timeout_ms: 100,
          stop_signal: "sigterm",
          stop_timeout_ms: 50
        }
      }
    )

    assert Config.settings!().verification.enabled == true
    assert Config.settings!().verification.port_allocation.range == [4100, 4102]
    assert Config.settings!().verification.dev_server.stop_signal == "TERM"
    verification_children = SymphonyElixir.Application.child_specs_for_runtime(%{})

    dev_server_supervisor_child = {
      DynamicSupervisor,
      strategy: :one_for_one, name: SymphonyElixir.Verification.DevServerSupervisor
    }

    assert SymphonyElixir.Verification.PortPool in verification_children
    assert dev_server_supervisor_child in verification_children

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{enabled: true, port_allocation: %{range: [4102, 4100]}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "verification.port_allocation.range"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{enabled: true, port_allocation: %{range: [4100]}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "must contain exactly two port integers"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{enabled: true, port_allocation: %{range: [0, 70_000]}}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "must contain two port integers between 1 and 65535"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{
        enabled: true,
        dev_server: %{start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"}
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "verification.dev_server.start_cmd is set"

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{
        enabled: true,
        dev_server: %{
          start_cmd: " ",
          health_check_url: " ",
          stop_signal: "sigint",
          stop_timeout_ms: 0
        }
      }
    )

    assert Config.settings!().verification.dev_server.start_cmd == nil
    assert Config.settings!().verification.dev_server.health_check_url == nil
    assert Config.settings!().verification.dev_server.stop_signal == "INT"
    assert Config.settings!().verification.dev_server.stop_timeout_ms == 0

    write_workflow_file!(Workflow.workflow_file_path(),
      verification: %{
        enabled: true,
        dev_server: %{stop_signal: "USR1"}
      }
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "verification.dev_server.stop_signal"

    dev_server_changeset =
      DevServerConfig.changeset(%DevServerConfig{}, %{
        start_cmd: nil,
        health_check_url: nil,
        stop_signal: nil
      })

    assert dev_server_changeset.valid?

    write_workflow_file!(Workflow.workflow_file_path(),
      max_tokens_per_issue: 500_000,
      max_tokens_per_day: 5_000_000
    )

    config = Config.settings!()
    assert config.agent.max_tokens_per_issue == 500_000
    assert config.agent.max_tokens_per_day == 5_000_000

    write_workflow_file!(Workflow.workflow_file_path(), server_port: 4123)
    assert Config.server_port() == 4123

    write_workflow_file!(Workflow.workflow_file_path(), server_host: "0.0.0.0")
    assert Config.server_host() == "0.0.0.0"

    Application.put_env(:symphony_elixir, :server_host_override, "localhost")
    assert Config.server_host() == "localhost"
    Application.delete_env(:symphony_elixir, :server_host_override)

    write_workflow_file!(Workflow.workflow_file_path(), observability_enabled: false)
    assert Config.server_port() == nil

    write_workflow_file!(Workflow.workflow_file_path(),
      max_tokens_per_issue: 500_000,
      agent_command: "codex run"
    )

    warning =
      capture_log(fn ->
        assert :ok = Config.validate!()
      end)

    assert warning =~ "agent.max_tokens_per_issue is configured"
    assert warning =~ "may not report token usage"

    write_workflow_file!(Workflow.workflow_file_path(),
      max_tokens_per_day: 5_000_000,
      agent_command: "codex run"
    )

    warning =
      capture_log(fn ->
        assert :ok = Config.validate!()
      end)

    assert warning =~ "agent.max_tokens_per_day is configured"
    assert warning =~ "may not report token usage"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      agent_approval_policy: "on-request",
      agent_thread_sandbox: "workspace-write",
      agent_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.agent.approval_policy == "on-request"
    assert config.agent.thread_sandbox == "workspace-write"

    assert {:ok, canonical_explicit_workspace} =
             SymphonyElixir.PathSafety.canonicalize(explicit_workspace)

    assert {:ok, canonical_explicit_workspace_git} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(explicit_workspace, ".git"))

    assert {:ok, canonical_explicit_cache} =
             SymphonyElixir.PathSafety.canonicalize(explicit_cache)

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [
               canonical_explicit_workspace,
               canonical_explicit_workspace_git,
               canonical_explicit_cache
             ],
             "networkAccess" => true
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_per_issue: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "agent.max_tokens_per_issue"

    write_workflow_file!(Workflow.workflow_file_path(), max_tokens_per_day: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "agent.max_tokens_per_day"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), agent_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "agent.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), agent_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "agent.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), agent_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "agent.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), agent_command_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "agent.command_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      watchdog: %{enabled: true, tick_interval_ms: 0, no_progress_threshold_ms: "bad"}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "watchdog.tick_interval_ms"
    assert message =~ "watchdog.no_progress_threshold_ms"

    write_workflow_file!(Workflow.workflow_file_path(), workspace_strategy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "workspace.strategy"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      observability_transcript_buffer_size: -1,
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate_repo_workflows()

    write_workflow_file!(Workflow.workflow_file_path(), agent_approval_policy: "")
    assert :ok = Config.validate!()
    assert Config.settings!().agent.approval_policy == ""

    write_workflow_file!(Workflow.workflow_file_path(), agent_thread_sandbox: "")
    assert :ok = Config.validate!()
    assert Config.settings!().agent.thread_sandbox == ""

    write_workflow_file!(Workflow.workflow_file_path(), agent_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "agent.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      agent_approval_policy: "future-policy",
      agent_thread_sandbox: "future-sandbox",
      agent_turn_sandbox_policy: %{
        type: "futureSandbox",
        nested: %{flag: true}
      }
    )

    config = Config.settings!()
    assert config.agent.approval_policy == "future-policy"
    assert config.agent.thread_sandbox == "future-sandbox"

    assert :ok = Config.validate!()

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "futureSandbox",
             "nested" => %{"flag" => true}
           }

    write_workflow_file!(Workflow.workflow_file_path(), agent_command: "codex app-server")
    assert Config.settings!().agent.command == "codex app-server"
  end

  test "codex runtime approval policy maps auto approve all to Codex wire value" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_approval_policy: "auto_approve_all")

    assert Config.settings!().agent.approval_policy == "auto_approve_all"
    assert {:ok, runtime_settings} = Config.codex_runtime_settings()
    assert runtime_settings.approval_policy == "never"
    assert runtime_settings.auto_approve_requests == true
  end

  test "config warns that Codex approval policy never is deprecated" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_approval_policy: "never")

    warning =
      capture_log(fn ->
        assert :ok = Config.validate!()
      end)

    assert warning =~ "agent.approval_policy: \"never\" is deprecated for Codex"
    assert warning =~ "auto-approves all approval requests"
    assert warning =~ "auto_approve_all"

    assert {:ok, runtime_settings} = Config.codex_runtime_settings()
    assert runtime_settings.approval_policy == "never"
    assert runtime_settings.auto_approve_requests == true
  end

  test "config defaults omitted Claude approval policy to never" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_kind: "claude",
      agent_command: "claude",
      agent_approval_policy: nil
    )

    config = Config.settings!()
    assert config.agent.kind == "claude"
    assert config.agent.approval_policy == "never"
  end

  test "config validates local worktree repository settings" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-worktree-config-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      not_git_repo = Path.join(test_root, "not-git")
      missing_repo = Path.join(test_root, "missing")

      File.mkdir_p!(not_git_repo)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: nil
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "workspace.repo is required"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: missing_repo
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "workspace.repo does not exist"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: not_git_repo
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "workspace.repo is not a valid git repository"

      create_primary_repo!(primary_repo)
      File.write!(Path.join(primary_repo, "dirty.txt"), "dirty\n")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: primary_repo
      )

      log =
        capture_log(fn ->
          assert :ok = Config.validate!()
        end)

      assert log =~ "Worktree primary clone has uncommitted changes"
      assert log =~ primary_repo

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_strategy: "worktree",
        workspace_repo: "~/remote-primary",
        worker_ssh_hosts: ["worker-01"]
      )

      assert :ok = Config.validate!()
      assert Config.settings!().workspace.repo == "~/remote-primary"
    after
      File.rm_rf(test_root)
    end
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      agent_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert Secret.unwrap(config.tracker.api_key) == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.agent.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert Secret.unwrap(config.tracker.api_key) == "env:#{api_key_env_var}"
    assert config.workspace.root == "env:#{workspace_env_var}"
  end

  test "config supports per-state max concurrent agent overrides" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 10,
      max_concurrent_agents_by_state: %{
        "todo" => 1,
        "In Progress" => 4,
        "In Review" => 2
      }
    )

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert changeset.errors == [
             limits: {"state names must not be blank", []},
             limits: {"limits must be positive integers", []}
           ]
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               agent: %{kind: "codex", command: "codex app-server", approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.agent.approval_policy == %{
             "reject" => %{"sandbox_approval" => true}
           }

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""},
               agent: %{kind: "codex", command: "codex app-server"}
             })

    assert Secret.unwrap(settings.tracker.api_key) == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Agent{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == Map.put(explicit_policy, "networkAccess", true)

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             agent: %Agent{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               agent: %Agent{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema keeps workspace roots raw while sandbox helpers expand only for local use" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               agent: %{kind: "codex", command: "codex app-server"}
             })

    assert settings.workspace.root == "~/.symphony-workspaces"

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy == %{
             "type" => "workspaceWrite",
             "writableRoots" => ["~/.symphony-workspaces"],
             "readOnlyAccess" => %{"type" => "fullAccess"},
             "networkAccess" => true,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }
  end

  test "schema resolves codex network allowlist config" do
    assert {:ok, settings} =
             Schema.parse(%{
               agent: %{
                 kind: "codex",
                 command: "codex app-server",
                 network_access: %{
                   mode: "allowlist",
                   allowed_domains: ["API.MyCompany.com", " registry.npmjs.org "],
                   denied_domains: ["REGISTRY.NPMJS.ORG", "api.github.com"]
                 }
               }
             })

    built_in_domains = Schema.codex_built_in_network_allowed_domains()
    assert "github.com" in built_in_domains
    assert "registry.npmjs.org" in built_in_domains

    assert settings.agent.network_access.mode == "allowlist"
    assert settings.agent.network_access.allowed_domains == ["api.mycompany.com", "registry.npmjs.org"]
    assert settings.agent.network_access.denied_domains == ["registry.npmjs.org", "api.github.com"]

    effective_domains = Schema.codex_effective_network_allowed_domains(settings)
    assert "github.com" in effective_domains
    assert "api.mycompany.com" in effective_domains
    refute "api.github.com" in effective_domains
    refute "registry.npmjs.org" in effective_domains

    thread_config = Schema.resolve_codex_thread_config(settings)
    experimental_network = thread_config["experimental_network"]

    assert experimental_network["enabled"] == true
    assert experimental_network["managedAllowedDomainsOnly"] == true
    assert experimental_network["domains"]["github.com"] == "allow"
    assert experimental_network["domains"]["api.mycompany.com"] == "allow"
    refute Map.has_key?(experimental_network["domains"], "api.github.com")
    refute Map.has_key?(experimental_network["domains"], "registry.npmjs.org")
  end

  test "schema maps codex network modes to sandbox policy and thread config" do
    assert {:ok, block_settings} =
             Schema.parse(%{
               agent: %{
                 kind: "codex",
                 command: "codex app-server",
                 network_access: %{mode: "block"},
                 turn_sandbox_policy: %{type: "workspaceWrite", networkAccess: true}
               }
             })

    assert Schema.resolve_turn_sandbox_policy(block_settings)["networkAccess"] == false
    assert Schema.resolve_codex_thread_config(block_settings) == nil

    assert {:ok, open_settings} =
             Schema.parse(%{
               agent: %{
                 kind: "codex",
                 command: "codex app-server",
                 network_access: %{mode: "open"},
                 turn_sandbox_policy: %{type: "workspaceWrite", networkAccess: false}
               }
             })

    assert Schema.resolve_turn_sandbox_policy(open_settings)["networkAccess"] == true
    assert Schema.resolve_codex_thread_config(open_settings) == nil
  end

  test "schema network helpers tolerate missing embedded network config" do
    settings = %Schema{
      agent: %Agent{network_access: nil},
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert "github.com" in Schema.codex_effective_network_allowed_domains(settings)
    assert get_in(Schema.resolve_codex_thread_config(settings), ["experimental_network", "domains", "github.com"]) == "allow"

    nil_domains_settings = %Schema{
      agent: %Agent{
        network_access: %Agent.NetworkAccess{allowed_domains: nil, denied_domains: nil}
      },
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert Schema.codex_effective_network_allowed_domains(nil_domains_settings) ==
             Schema.codex_built_in_network_allowed_domains()
  end

  test "schema network helpers fail on malformed embedded network config" do
    settings = %Schema{
      agent: %Agent{network_access: %{mode: "open"}},
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert_raise FunctionClauseError, fn ->
      Schema.codex_effective_network_allowed_domains(settings)
    end
  end

  test "runtime sandbox policy keeps workspaceWrite policy rootless when no workspace is available" do
    settings = %Schema{
      agent: %Agent{
        network_access: %Agent.NetworkAccess{mode: "block"},
        turn_sandbox_policy: %{"type" => "workspaceWrite", "writableRoots" => []}
      },
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert {:ok, policy} = Schema.resolve_runtime_turn_sandbox_policy(settings, nil)
    assert policy == %{"type" => "workspaceWrite", "writableRoots" => [], "networkAccess" => false}
  end

  test "runtime sandbox policy resolution keeps clone workspace writable with explicit roots" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert {:ok, canonical_issue_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_issue_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_issue_workspace, canonical_issue_workspace_git, "relative/path"],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_turn_sandbox_policy: %{
          type: "futureSandbox",
          nested: %{flag: true}
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "futureSandbox",
               "nested" => %{"flag" => true}
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy discovers regular clone git metadata roots" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-clone-git-roots-#{System.unique_integer([:positive])}"
      )

    try do
      source_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-CLONE")

      create_primary_repo!(source_repo)
      File.mkdir_p!(workspace_root)
      {_output, 0} = System.cmd("git", ["clone", source_repo, issue_workspace], stderr_to_stdout: true)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert {:ok, canonical_issue_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_issue_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_issue_workspace, canonical_issue_workspace_git, "relative/path"],
               "networkAccess" => true
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy discovers linked worktree git metadata roots from workspace" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-discovered-worktree-roots-#{System.unique_integer([:positive])}"
      )

    try do
      primary_repo = Path.join(test_root, "primary")
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-DISCOVER")

      create_primary_repo!(primary_repo)
      File.mkdir_p!(workspace_root)
      git!(primary_repo, ["worktree", "add", "-b", "auto/MT-DISCOVER", issue_workspace])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "clone",
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      git_dir =
        issue_workspace
        |> git!(["rev-parse", "--path-format=absolute", "--git-dir"])
        |> String.trim()

      git_common_dir =
        issue_workspace
        |> git!(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        |> String.trim()

      assert {:ok, canonical_issue_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_issue_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert {:ok, canonical_git_dir} = SymphonyElixir.PathSafety.canonicalize(git_dir)
      assert {:ok, canonical_git_common_dir} = SymphonyElixir.PathSafety.canonicalize(git_common_dir)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [
                 canonical_issue_workspace,
                 canonical_issue_workspace_git,
                 canonical_git_dir,
                 canonical_git_common_dir,
                 "relative/path"
               ],
               "networkAccess" => true
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy resolution adds worktree git metadata root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-worktree-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")
      repo = Path.join(test_root, "repo")
      repo_git = Path.join(repo, ".git")

      File.mkdir_p!(issue_workspace)
      File.mkdir_p!(repo_git)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: repo,
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: ["relative/path"],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert {:ok, canonical_issue_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_issue_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert {:ok, canonical_repo_git} = SymphonyElixir.PathSafety.canonicalize(repo_git)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [
                 canonical_issue_workspace,
                 canonical_issue_workspace_git,
                 canonical_repo_git,
                 "relative/path"
               ],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: repo,
        agent_turn_sandbox_policy: nil
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_issue_workspace, canonical_issue_workspace_git, canonical_repo_git],
               "readOnlyAccess" => %{"type" => "fullAccess"},
               "networkAccess" => true,
               "excludeTmpdirEnvVar" => false,
               "excludeSlashTmp" => false
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: repo,
        agent_turn_sandbox_policy: %{
          type: "workspaceWrite",
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [canonical_issue_workspace, canonical_issue_workspace_git, canonical_repo_git],
               "readOnlyAccess" => %{"type" => "fullAccess"},
               "networkAccess" => true,
               "excludeTmpdirEnvVar" => false,
               "excludeSlashTmp" => false
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy resolution filters non-string writableRoots entries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-nonstring-roots-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-NS")
      invalid_root = Path.join(test_root, String.duplicate("a", 300))
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      settings = Config.settings!()

      policy_settings = %{
        settings
        | agent: %{
            settings.agent
            | turn_sandbox_policy: %{
                "type" => "workspaceWrite",
                "writableRoots" => ["relative/path", invalid_root, 8080, %{"nested" => true}]
              }
          }
      }

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(issue_workspace)

      assert {:ok, canonical_workspace_git} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(issue_workspace, ".git"))

      assert {:ok, policy} =
               Schema.resolve_runtime_turn_sandbox_policy(policy_settings, issue_workspace)

      assert policy["writableRoots"] == [canonical_workspace, canonical_workspace_git, "relative/path"]

      invalid_root_settings = %{
        settings
        | agent: %{
            settings.agent
            | turn_sandbox_policy: %{
                "type" => "workspaceWrite",
                "writableRoots" => [invalid_root]
              }
          }
      }

      assert {:ok, invalid_root_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(invalid_root_settings, issue_workspace)

      assert invalid_root_policy["writableRoots"] == [canonical_workspace, canonical_workspace_git]

      invalid_roots_settings = %{
        settings
        | agent: %{
            settings.agent
            | turn_sandbox_policy: %{
                "type" => "workspaceWrite",
                "writableRoots" => "not-a-list"
              }
          }
      }

      assert {:ok, invalid_roots_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(invalid_roots_settings, issue_workspace)

      assert invalid_roots_policy["writableRoots"] == [canonical_workspace, canonical_workspace_git]
    after
      File.rm_rf(test_root)
    end
  end

  test "runtime sandbox policy resolution keeps explicit absolute roots raw in remote mode" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-remote-roots-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      settings = Config.settings!()

      policy_settings = %{
        settings
        | agent: %{
            settings.agent
            | turn_sandbox_policy: %{
                "type" => "workspaceWrite",
                "writableRoots" => ["/remote/absolute/path", "relative/path"]
              }
          }
      }

      assert {:ok, policy} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 policy_settings,
                 "/remote/workspace",
                 remote: true
               )

      assert policy["writableRoots"] == [
               "/remote/workspace",
               "/remote/workspace/.git",
               "/remote/absolute/path",
               "relative/path"
             ]
    after
      File.rm_rf(test_root)
    end
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | agent: %{settings.agent | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      future_settings = %{
        settings
        | agent: %{settings.agent | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:ok, %{"type" => "futureSandbox", "nested" => %{"flag" => true}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "token budget defaults apply when omitted and explicit null disables caps" do
    write_workflow_without_token_budget_keys!()

    config = Config.settings!()
    assert config.agent.max_tokens_per_issue == 500_000
    assert config.agent.max_tokens_per_day == 5_000_000

    write_workflow_file!(Workflow.workflow_file_path(),
      max_tokens_per_issue: nil,
      max_tokens_per_day: nil
    )

    config = Config.settings!()
    assert config.agent.max_tokens_per_issue == nil
    assert config.agent.max_tokens_per_day == nil
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "remote workspace lifecycle uses ssh host aliases from worker config" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_path = "/remote/home/.symphony-remote-workspaces/default/MT-SSH-WS"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]
      assert Config.settings!().workspace.root == workspace_root
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "-p 2200 worker-01 bash -lc"
      assert trace =~ "__SYMPHONY_WORKSPACE__"
      assert trace =~ "~/.symphony-remote-workspaces/default/MT-SSH-WS"
      assert trace =~ "${workspace#~/}"
      assert trace =~ "echo before-run"
      assert trace =~ "echo after-run"
      assert trace =~ "echo before-remove"
      assert trace =~ "rm -rf"
      assert trace =~ workspace_path
    after
      File.rm_rf(test_root)
    end
  end

  test "remote worktree lifecycle uses host-local repository paths" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-worktree-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_root = "~/.symphony-remote-workspaces"
      workspace_repo = "~/primary-clone"
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WT"

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      trace_file="${SYMP_TEST_SSH_TRACE:-/tmp/symphony-fake-ssh.trace}"
      printf 'ARGV:%s\\n' "$*" >> "$trace_file"

      case "$*" in
        *"__SYMPHONY_WORKSPACE__"*)
          printf '%s\\t%s\\t%s\\n' '__SYMPHONY_WORKSPACE__' '1' '#{workspace_path}'
          ;;
      esac

      exit 0
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        workspace_strategy: "worktree",
        workspace_repo: workspace_repo,
        worker_ssh_hosts: ["worker-01:2200"]
      )

      assert :ok = Config.validate!()
      assert {:ok, ^workspace_path} = Workspace.create_for_issue("MT-SSH-WT", "worker-01:2200")
      assert :ok = Workspace.remove_issue_workspaces("MT-SSH-WT", "worker-01:2200")

      trace = File.read!(trace_file)
      assert trace =~ "~/primary-clone"
      assert trace =~ "${repo#~/}"
      assert trace =~ "git -C \"$repo\" fetch origin"
      assert trace =~ "git -C \"$repo\" worktree add"
      assert trace =~ "workspace_worktree_list_failed"
      assert trace =~ "auto/MT-SSH-WT"
      assert trace =~ "git -C \"$repo\" worktree remove --force"
      refute trace =~ "git clone"
    after
      File.rm_rf(test_root)
    end
  end

  test "remote worktree creation surfaces missing primary clone errors" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-worktree-missing-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
    end)

    try do
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      echo "workspace_repo_missing: /remote/missing-primary"
      exit 41
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "/remote/workspaces",
        workspace_strategy: "worktree",
        workspace_repo: "/remote/missing-primary",
        worker_ssh_hosts: ["worker-01"]
      )

      assert {:error, {:workspace_prepare_failed, "worker-01", 41, output}} =
               Workspace.create_for_issue("MT-MISSING-REMOTE", "worker-01")

      assert output =~ "workspace_repo_missing: /remote/missing-primary"
    after
      File.rm_rf(test_root)
    end
  end

  defp create_primary_repo!(primary_repo, origin_repo \\ nil) do
    File.mkdir_p!(primary_repo)
    git!(primary_repo, ["init", "-b", "main"])
    configure_git_user!(primary_repo)
    File.write!(Path.join(primary_repo, "README.md"), "initial\n")
    git!(primary_repo, ["add", "README.md"])
    git!(primary_repo, ["commit", "-m", "initial"])

    if is_binary(origin_repo) do
      File.mkdir_p!(Path.dirname(origin_repo))
      {_output, 0} = System.cmd("git", ["init", "--bare", origin_repo])
      git!(primary_repo, ["remote", "add", "origin", origin_repo])
      git!(primary_repo, ["push", "-u", "origin", "main"])
      {_output, 0} = System.cmd("git", ["-C", origin_repo, "symbolic-ref", "HEAD", "refs/heads/main"])
      git!(primary_repo, ["fetch", "origin"])
    end

    :ok
  end

  defp configure_git_user!(repo) do
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
  end

  defp capture_candidate_variables! do
    graphql_fun = fn query, variables ->
      send(self(), {:candidate_query, query, variables})
      {:ok, linear_page_response([])}
    end

    assert {:ok, []} = Client.fetch_candidate_issues_for_test(graphql_fun)
    assert_receive {:candidate_query, query, variables}
    assert query =~ "SymphonyLinearPoll"

    variables
  end

  defp write_workflow_without_token_budget_keys! do
    File.write!(Workflow.workflow_file_path(), "Prompt\n")

    File.write!(Workflow.symphony_file_path(), """
    tracker:
      kind: memory
    agent:
      kind: codex
      command: codex app-server
    repos:
      - name: default
        path: #{Path.dirname(Workflow.workflow_file_path())}
        workflow: #{Path.basename(Workflow.workflow_file_path())}
        team: Test
    """)

    reload_workflow_store()
  end

  defp reload_workflow_store do
    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp linear_page_response(nodes, page_info \\ %{"hasNextPage" => false, "endCursor" => nil}) do
    %{
      "data" => %{
        "issues" => %{
          "nodes" => nodes,
          "pageInfo" => page_info
        }
      }
    }
  end

  defp raw_linear_issue(id, identifier, assignee_id \\ nil) do
    %{
      "id" => id,
      "identifier" => identifier,
      "title" => identifier,
      "state" => %{"name" => "Todo"},
      "assignee" => assignee_id && %{"id" => assignee_id},
      "labels" => %{"nodes" => []},
      "inverseRelations" => %{"nodes" => []}
    }
  end

  defp git!(repo, args) do
    case System.cmd("git", ["-C", repo | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with status #{status}: #{output}")
    end
  end

  defp git_branch_exists?(repo, branch) do
    case System.cmd("git", ["-C", repo, "rev-parse", "--verify", "refs/heads/#{branch}"], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  describe "local_worktree_dirty_status/1" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "sym_dirty_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      git!(tmp, ["init", "-q", "-b", "main"])
      git!(tmp, ["config", "user.email", "t@t"])
      git!(tmp, ["config", "user.name", "t"])
      File.write!(Path.join(tmp, "f"), "x")
      git!(tmp, ["add", "."])
      git!(tmp, ["commit", "-q", "-m", "init"])

      on_exit(fn -> File.rm_rf!(tmp) end)
      %{repo: tmp}
    end

    test "returns :clean for a clean repo", %{repo: repo} do
      assert SymphonyElixir.Config.local_worktree_dirty_status(repo) == :clean
    end

    test "returns {:dirty, summary} when there are uncommitted changes", %{repo: repo} do
      File.write!(Path.join(repo, "f"), "y")
      assert {:dirty, summary} = SymphonyElixir.Config.local_worktree_dirty_status(repo)
      assert summary =~ "M f"
    end

    test "returns :not_applicable for a non-git path" do
      assert SymphonyElixir.Config.local_worktree_dirty_status("/nonexistent_xyzzy") ==
               :not_applicable
    end
  end
end
