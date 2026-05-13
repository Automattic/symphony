defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises scoped Linear tools and not raw GraphQL" do
    tool_names = Enum.map(DynamicTool.tool_specs(), & &1["name"])

    assert "linear_get_current_issue" in tool_names
    assert "linear_update_state" in tool_names
    assert "linear_attach_file" in tool_names
    assert "github_get_pull_request" in tool_names
    assert "github_create_pull_request" in tool_names
    assert "github_push_branch" in tool_names
    assert "github_get_pr_checks" in tool_names
    refute "linear_graphql" in tool_names
    refute "linear.get_current_issue" in tool_names
    refute "github.get_pull_request" in tool_names

    assert Enum.all?(tool_names, &Regex.match?(~r/^[a-zA-Z0-9_-]+$/, &1))

    assert Enum.all?(DynamicTool.tool_specs(), fn spec ->
             get_in(spec, ["inputSchema", "additionalProperties"]) == false
           end)
  end

  test "unsupported raw linear_graphql returns tool_not_found" do
    response = DynamicTool.execute("linear_graphql", %{"query" => "query Viewer { viewer { id } }"})

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "tool_not_found",
               "supportedTools" => supported_tools
             }
           } = Jason.decode!(response["output"])

    refute "linear_graphql" in supported_tools
  end

  test "update_state resolves against the current issue team and updates current issue only" do
    test_pid = self()
    issue = %Issue{id: "issue-current", identifier: "RSM-1"}

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "In Progress"},
        issue: issue,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          cond do
            query =~ "SymphonyAgentIssueTeamStates" ->
              {:ok,
               %{
                 "data" => %{
                   "issue" => %{
                     "team" => %{
                       "states" => %{
                         "nodes" => [
                           %{"id" => "state-started", "name" => "In Progress", "type" => "started"}
                         ]
                       }
                     }
                   }
                 }
               }}

            query =~ "SymphonyAgentUpdateIssueState" ->
              {:ok,
               %{
                 "data" => %{
                   "issueUpdate" => %{
                     "success" => true,
                     "issue" => %{"id" => variables.id, "state" => %{"id" => variables.stateId}}
                   }
                 }
               }}
          end
        end
      )

    assert response["success"] == true
    assert_received {:linear_client_called, query, %{id: "issue-current"}, []}
    assert query =~ "SymphonyAgentIssueTeamStates"
    assert_received {:linear_client_called, query, %{id: "issue-current", stateId: "state-started"}, []}
    assert query =~ "SymphonyAgentUpdateIssueState"
  end

  test "update_state returns state_not_found with available states when name is unknown" do
    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => "Shipped"},
        issue: %Issue{id: "issue-current"},
        linear_client: fn query, _variables, _opts ->
          true = query =~ "SymphonyAgentIssueTeamStates"

          {:ok,
           %{
             "data" => %{
               "issue" => %{
                 "team" => %{
                   "states" => %{
                     "nodes" => [
                       %{"id" => "state-1", "name" => "Todo", "type" => "unstarted"},
                       %{"id" => "state-2", "name" => "In Progress", "type" => "started"},
                       %{"id" => "state-3", "name" => "Done", "type" => "completed"}
                     ]
                   }
                 }
               }
             }
           }}
        end
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "state_not_found",
               "available_states" => ["Todo", "In Progress", "Done"]
             }
           } = Jason.decode!(response["output"])
  end

  test "update_state skips team introspection when given a UUID state id" do
    test_pid = self()
    state_uuid = "11111111-2222-3333-4444-555555555555"

    response =
      DynamicTool.execute(
        "linear_update_state",
        %{"state_name_or_id" => state_uuid},
        issue: %Issue{id: "issue-current"},
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:linear_client_called, query, variables})

          if query =~ "SymphonyAgentIssueTeamStates" do
            flunk("team states introspection should be skipped for UUID state ids")
          end

          {:ok,
           %{
             "data" => %{
               "issueUpdate" => %{
                 "success" => true,
                 "issue" => %{"id" => variables.id, "state" => %{"id" => variables.stateId}}
               }
             }
           }}
        end
      )

    assert response["success"] == true
    assert_received {:linear_client_called, query, %{id: "issue-current", stateId: ^state_uuid}}
    assert query =~ "SymphonyAgentUpdateIssueState"
  end

  test "add_comment surfaces commentCreate success=false from Linear as a failure" do
    {:ok, registry} = CommentRegistry.start_link()

    response =
      DynamicTool.execute(
        "linear_add_comment",
        %{"body" => "blocked"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"data" => %{"commentCreate" => %{"success" => false, "comment" => nil}}}}
        end
      )

    assert response["success"] == false

    assert %{
             "error" => %{
               "code" => "linear_mutation_failed",
               "field" => "commentCreate"
             }
           } = Jason.decode!(response["output"])

    refute CommentRegistry.owned?(registry, "any-id")
  end

  test "legacy dotted tool aliases are accepted but still reject smuggled issue ids" do
    response =
      DynamicTool.execute(
        "linear.update_state",
        %{"issue_id" => "issue-other", "state_name_or_id" => "Done"},
        issue: %Issue{id: "issue-current"}
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "scope_argument_rejected"}} =
             Jason.decode!(response["output"])
  end

  test "add_comment records ownership and update_comment allows owned comments" do
    {:ok, registry} = CommentRegistry.start_link()
    test_pid = self()

    add_response =
      DynamicTool.execute(
        "linear_add_comment",
        %{"body" => "first"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          {:ok,
           %{
             "data" => %{
               "commentCreate" => %{
                 "success" => true,
                 "comment" => %{"id" => "comment-owned", "body" => variables.body, "url" => "https://linear/comment"}
               }
             }
           }}
        end
      )

    assert add_response["success"] == true
    assert CommentRegistry.owned?(registry, "comment-owned")

    update_response =
      DynamicTool.execute(
        "linear_update_comment",
        %{"comment_id" => "comment-owned", "body" => "edited"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})

          {:ok,
           %{
             "data" => %{
               "commentUpdate" => %{
                 "success" => true,
                 "comment" => %{"id" => variables.id, "body" => variables.body}
               }
             }
           }}
        end
      )

    assert update_response["success"] == true
    assert_received {:linear_client_called, query, %{id: "comment-owned", body: "edited"}, []}
    assert query =~ "SymphonyAgentUpdateComment"
  end

  test "update_comment rejects comments not created in this run" do
    {:ok, registry} = CommentRegistry.start_link()

    response =
      DynamicTool.execute(
        "linear_update_comment",
        %{"comment_id" => "comment-other", "body" => "edited"},
        issue: %Issue{id: "issue-current"},
        comment_registry: registry,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for unowned comments")
        end
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => ":comment_not_owned_by_run"}} =
             Jason.decode!(response["output"])
  end

  test "attach_file rejects paths outside the workspace before upload" do
    test_root = Path.join(System.tmp_dir!(), "linear-attach-file-#{System.unique_integer([:positive])}")
    workspace = Path.join(test_root, "workspace")
    outside = Path.join(test_root, "outside.txt")

    try do
      File.mkdir_p!(workspace)
      File.write!(outside, "outside")

      response =
        DynamicTool.execute(
          "linear_attach_file",
          %{"local_path" => outside, "title" => "outside"},
          issue: %Issue{id: "issue-current"},
          workspace: workspace,
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called for outside paths")
          end
        )

      assert response["success"] == false

      assert %{"error" => %{"code" => ":path_outside_workspace"}} =
               Jason.decode!(response["output"])
    after
      File.rm_rf(test_root)
    end
  end

  test "github.create_pull_request uses current branch and configured origin repo" do
    workspace = tmp_workspace!("github-create-pr")

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
          "Automattic/symphony",
          "--head",
          "auto/RSM-3051",
          "--title",
          "Add tools",
          "--body",
          "Body"
        ],
        opts ->
          assert opts[:cd] == workspace
          {"https://github.com/Automattic/symphony/pull/3051\n", 0}
      end

      response =
        DynamicTool.execute(
          "github_create_pull_request",
          %{"title" => "Add tools", "body" => "Body"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "url" => "https://github.com/Automattic/symphony/pull/3051",
               "repo" => "Automattic/symphony",
               "head" => "auto/RSM-3051"
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.create_pull_request rejects smuggled repo arguments" do
    response =
      DynamicTool.execute(
        "github_create_pull_request",
        %{"title" => "Add tools", "body" => "Body", "repo" => "attacker/repo"},
        workspace: System.tmp_dir!(),
        command_security: %{origin_repo: "Automattic/symphony"}
      )

    assert response["success"] == false

    assert %{"error" => %{"code" => "scope_argument_rejected", "message" => message}} =
             Jason.decode!(response["output"])

    assert message =~ "configured origin"
  end

  test "github tools reject smuggled branch and remote arguments" do
    for {tool, args} <- [
          {"github_create_pull_request", %{"title" => "Add tools", "body" => "Body", "head" => "owned"}},
          {"github_get_pull_request", %{"branch" => "owned"}},
          {"github_add_pr_comment", %{"body" => "Looks good", "remote" => "evil"}},
          {"github_get_pr_checks", %{"base" => "owned"}}
        ] do
      response =
        DynamicTool.execute(
          tool,
          args,
          workspace: System.tmp_dir!(),
          command_security: %{origin_repo: "Automattic/symphony"}
        )

      assert response["success"] == false
      assert %{"error" => %{"code" => "scope_argument_rejected"}} = Jason.decode!(response["output"])
    end
  end

  test "github.push_branch rejects smuggled refspec arguments" do
    response =
      DynamicTool.execute(
        "github_push_branch",
        %{"refspec" => "main:refs/heads/owned"},
        workspace: System.tmp_dir!(),
        command_security: %{origin_repo: "Automattic/symphony"}
      )

    assert response["success"] == false
    assert %{"error" => %{"code" => "scope_argument_rejected"}} = Jason.decode!(response["output"])
  end

  test "github.push_branch pushes origin current branch only" do
    workspace = tmp_workspace!("github-push-branch")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/RSM-3051\n", 0}

        ["push", "origin", "auto/RSM-3051"], opts ->
          assert opts[:cd] == workspace
          {"pushed\n", 0}
      end

      response =
        DynamicTool.execute(
          "github_push_branch",
          %{},
          github_tool_opts(workspace, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"remote" => "origin", "branch" => "auto/RSM-3051"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "legacy dotted github aliases are accepted but not advertised" do
    workspace = tmp_workspace!("github-legacy-alias")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/RSM-3051\n", 0}

        ["push", "origin", "auto/RSM-3051"], opts ->
          assert opts[:cd] == workspace
          {"pushed\n", 0}
      end

      response =
        DynamicTool.execute(
          "github.push_branch",
          %{},
          github_tool_opts(workspace, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"remote" => "origin", "branch" => "auto/RSM-3051"} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_pull_request resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-get-pr")

    try do
      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/RSM-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "--repo", "Automattic/symphony", "--head", "auto/RSM-3051", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => "https://github.com/Automattic/symphony/pull/3051",
             "headRefName" => "auto/RSM-3051",
             "baseRefName" => "main"
           }), 0}
      end

      response =
        DynamicTool.execute(
          "github_get_pull_request",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "url" => "https://github.com/Automattic/symphony/pull/3051",
               "headRefName" => "auto/RSM-3051",
               "baseRefName" => "main"
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.update_pull_request_body resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-update-pr-body")

    try do
      pr_url = "https://github.com/Automattic/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/RSM-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "--repo", "Automattic/symphony", "--head", "auto/RSM-3051", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Old body",
             "url" => pr_url,
             "headRefName" => "auto/RSM-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "edit", ^pr_url, "--body", "New body"], opts ->
          assert opts[:cd] == workspace
          {"", 0}
      end

      response =
        DynamicTool.execute(
          "github_update_pull_request_body",
          %{"body" => "New body"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"url" => ^pr_url} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.add_pr_comment resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-add-pr-comment")

    try do
      pr_url = "https://github.com/Automattic/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/RSM-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "--repo", "Automattic/symphony", "--head", "auto/RSM-3051", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/RSM-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "comment", ^pr_url, "--body", "Validation passed"], opts ->
          assert opts[:cd] == workspace
          {"", 0}
      end

      response =
        DynamicTool.execute(
          "github_add_pr_comment",
          %{"body" => "Validation passed"},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true
      assert %{"url" => ^pr_url} = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  test "github.get_pr_checks resolves the current branch PR server-side" do
    workspace = tmp_workspace!("github-get-pr-checks")

    try do
      pr_url = "https://github.com/Automattic/symphony/pull/3051"

      git_runner = fn
        ["branch", "--show-current"], opts ->
          assert opts[:cd] == workspace
          {"auto/RSM-3051\n", 0}
      end

      gh_runner = fn
        ["pr", "view", "--repo", "Automattic/symphony", "--head", "auto/RSM-3051", "--json", fields], opts ->
          assert opts[:cd] == workspace
          assert fields == "number,state,title,body,url,headRefName,baseRefName"

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "body" => "Body",
             "url" => pr_url,
             "headRefName" => "auto/RSM-3051",
             "baseRefName" => "main"
           }), 0}

        ["pr", "view", ^pr_url, "--json", "number,state,title,url,headRefOid,statusCheckRollup"], opts ->
          assert opts[:cd] == workspace

          {Jason.encode!(%{
             "number" => 3051,
             "state" => "OPEN",
             "title" => "Add tools",
             "url" => pr_url,
             "headRefOid" => "abc123",
             "statusCheckRollup" => [
               %{
                 "__typename" => "CheckRun",
                 "name" => "mix test",
                 "status" => "COMPLETED",
                 "conclusion" => "SUCCESS",
                 "detailsUrl" => "https://github.com/Automattic/symphony/actions/runs/1"
               }
             ]
           }), 0}
      end

      response =
        DynamicTool.execute(
          "github_get_pr_checks",
          %{},
          github_tool_opts(workspace, gh_runner: gh_runner, git_runner: git_runner)
        )

      assert response["success"] == true

      assert %{
               "pr_url" => ^pr_url,
               "commit_sha" => "abc123",
               "checks" => [%{"name" => "mix test", "conclusion" => "SUCCESS"}]
             } = Jason.decode!(response["output"])
    after
      File.rm_rf(workspace)
    end
  end

  defp tmp_workspace!(name) do
    workspace = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end

  defp github_tool_opts(workspace, opts) do
    opts
    |> Keyword.put(:workspace, workspace)
    |> Keyword.put(:command_security, %{origin_repo: "Automattic/symphony", workspace: workspace})
  end
end
