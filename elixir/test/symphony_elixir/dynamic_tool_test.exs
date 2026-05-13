defmodule SymphonyElixir.Codex.DynamicToolTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Linear.CommentRegistry
  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs advertises scoped Linear tools and not raw GraphQL" do
    tool_names = Enum.map(DynamicTool.tool_specs(), & &1["name"])

    assert "linear_get_current_issue" in tool_names
    assert "linear_update_state" in tool_names
    assert "linear_attach_file" in tool_names
    refute "linear_graphql" in tool_names
    refute "linear.get_current_issue" in tool_names

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

  test "legacy dotted tool aliases are accepted but not advertised" do
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
end
