defmodule SymphonyElixir.AgentTools.LinearTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Linear

  describe "list_own_comment_ids/2" do
    test "returns IDs of comments authored by the viewer only" do
      test_pid = self()

      result =
        Linear.list_own_comment_ids(
          %{issue: %Issue{id: "issue-current"}},
          linear_client: fn query, variables, opts ->
            send(test_pid, {:linear_client_called, query, variables, opts})

            cond do
              query =~ "SymphonyAgentViewer" ->
                {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-id"}}}}

              query =~ "SymphonyAgentIssueComments" ->
                {:ok,
                 %{
                   "data" => %{
                     "issue" => %{
                       "comments" => %{
                         "nodes" => [
                           %{"id" => "c1", "body" => "own", "user" => %{"id" => "viewer-id"}},
                           %{"id" => "c2", "body" => "other", "user" => %{"id" => "other-id"}},
                           %{"id" => "c3", "body" => "also own", "user" => %{"id" => "viewer-id"}}
                         ]
                       }
                     }
                   }
                 }}
            end
          end
        )

      assert {:ok, ids} = result
      assert Enum.sort(ids) == ["c1", "c3"]
    end

    test "returns empty list when no comments match the viewer" do
      result =
        Linear.list_own_comment_ids(
          %{issue: %Issue{id: "issue-current"}},
          linear_client: fn query, _variables, _opts ->
            cond do
              query =~ "SymphonyAgentViewer" ->
                {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-id"}}}}

              query =~ "SymphonyAgentIssueComments" ->
                {:ok,
                 %{
                   "data" => %{
                     "issue" => %{
                       "comments" => %{
                         "nodes" => [
                           %{"id" => "c1", "body" => "human", "user" => %{"id" => "human-id"}}
                         ]
                       }
                     }
                   }
                 }}
            end
          end
        )

      assert {:ok, []} = result
    end

    test "returns error when viewer query fails" do
      result =
        Linear.list_own_comment_ids(
          %{issue: %Issue{id: "issue-current"}},
          linear_client: fn query, _variables, _opts ->
            if query =~ "SymphonyAgentViewer" do
              {:error, :network_error}
            else
              flunk("comments query should not run if viewer fetch fails")
            end
          end
        )

      assert {:error, :network_error} = result
    end

    test "returns error when context has no issue" do
      assert {:error, :missing_current_issue} = Linear.list_own_comment_ids(%{}, [])
    end
  end

  describe "recover_comment_registry_seeds/3" do
    test "returns IDs when tracker kind is linear and Linear succeeds" do
      ids =
        Linear.recover_comment_registry_seeds(
          %Issue{id: "issue-current"},
          "linear",
          linear_client: fn query, _variables, _opts ->
            cond do
              query =~ "SymphonyAgentViewer" ->
                {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-id"}}}}

              query =~ "SymphonyAgentIssueComments" ->
                {:ok,
                 %{
                   "data" => %{
                     "issue" => %{
                       "comments" => %{
                         "nodes" => [
                           %{"id" => "own-1", "user" => %{"id" => "viewer-id"}}
                         ]
                       }
                     }
                   }
                 }}
            end
          end
        )

      assert ids == ["own-1"]
    end

    test "returns [] without calling Linear when tracker kind is not linear" do
      ids =
        Linear.recover_comment_registry_seeds(
          %Issue{id: "issue-current"},
          "memory",
          linear_client: fn _query, _variables, _opts ->
            flunk("Linear client should not be invoked for non-linear trackers")
          end
        )

      assert ids == []
    end

    test "returns [] and logs when the Linear call fails" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ids =
            Linear.recover_comment_registry_seeds(
              %Issue{id: "issue-current"},
              "linear",
              linear_client: fn _query, _variables, _opts ->
                {:error, :network_error}
              end
            )

          assert ids == []
        end)

      assert log =~ "comment registry"
      assert log =~ ":network_error"
    end
  end
end
