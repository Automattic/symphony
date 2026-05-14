defmodule SymphonyElixir.AgentTools.LinearTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.Linear

  describe "secret-prefix rejection" do
    test "add_comment rejects high-confidence secret prefixes and accepts normal body" do
      workspace = tmp_workspace!("linear-agent-comment-secret")
      audit_dir = Path.join(workspace, "audit")
      context = secret_context(workspace)

      try do
        for token <- secret_fixtures() do
          assert {:error, :secret_pattern_detected} =
                   Linear.add_comment(context, "leaked credential: " <> token,
                     dir: audit_dir,
                     linear_client: fn _query, _variables, _opts ->
                       flunk("Linear should not be called for secret-bearing comments")
                     end
                   )
        end

        assert {:ok, response} =
                 Linear.add_comment(context, "normal review note",
                   linear_client: fn query, variables, _opts ->
                     assert query =~ "SymphonyAgentAddComment"
                     assert variables == %{issueId: "issue-secret", body: "normal review note"}

                     {:ok,
                      %{
                        "data" => %{
                          "commentCreate" => %{
                            "success" => true,
                            "comment" => %{"id" => "comment-ok", "body" => "normal review note", "url" => "https://linear.test/comment"}
                          }
                        }
                      }}
                   end
                 )

        assert get_in(response, ["data", "commentCreate", "comment", "id"]) == "comment-ok"
        assert [%{"event_type" => "refused_agent_action", "reason" => "secret_pattern_detected"} | _rest] = audit_events(audit_dir)
        refute inspect(audit_events(audit_dir)) =~ openai_fixture()
      after
        File.rm_rf(workspace)
      end
    end

    test "attach_url rejects high-confidence secret prefixes and accepts normal URL" do
      workspace = tmp_workspace!("linear-agent-url-secret")
      audit_dir = Path.join(workspace, "audit")
      context = secret_context(workspace)

      try do
        assert {:error, :secret_pattern_detected} =
                 Linear.attach_url(context, "https://attacker.example/?d=" <> openai_fixture(), nil,
                   dir: audit_dir,
                   linear_client: fn _query, _variables, _opts ->
                     flunk("Linear should not be called for secret-bearing URLs")
                   end
                 )

        assert {:ok, response} =
                 Linear.attach_url(context, "https://example.com/report", "Report",
                   linear_client: fn query, variables, _opts ->
                     assert query =~ "SymphonyAgentAttachURL"
                     assert variables == %{issueId: "issue-secret", url: "https://example.com/report", title: "Report"}

                     {:ok,
                      %{
                        "data" => %{
                          "attachmentLinkURL" => %{
                            "success" => true,
                            "attachment" => %{"id" => "attachment-ok", "url" => "https://example.com/report"}
                          }
                        }
                      }}
                   end
                 )

        assert get_in(response, ["data", "attachmentLinkURL", "attachment", "id"]) == "attachment-ok"
        assert [%{"field" => "url", "reason" => "secret_pattern_detected"}] = audit_events(audit_dir)
      after
        File.rm_rf(workspace)
      end
    end

    test "attach_file rejects high-confidence secret prefixes before upload" do
      workspace = tmp_workspace!("linear-agent-file-secret")
      audit_dir = Path.join(workspace, "audit")
      path = Path.join(workspace, "proof.txt")
      File.write!(path, "token=" <> openai_fixture())

      try do
        assert {:error, :secret_pattern_detected} =
                 Linear.attach_file(secret_context(workspace), path, "Proof",
                   dir: audit_dir,
                   linear_client: fn _query, _variables, _opts ->
                     flunk("Linear should not request an upload for secret-bearing files")
                   end,
                   upload_client: fn _url, _opts ->
                     flunk("secret-bearing files should not be uploaded")
                   end
                 )

        assert [%{"field" => "file", "reason" => "secret_pattern_detected"}] = audit_events(audit_dir)
      after
        File.rm_rf(workspace)
      end
    end

    test "attach_file rejects private uploads for sensitive basenames before upload" do
      workspace = tmp_workspace!("linear-agent-file-private-sensitive")
      path = Path.join(workspace, ".env.local")
      File.write!(path, "ordinary test fixture")

      try do
        assert {:error, {:private_upload_denied_sensitive_filename, ".env.local"}} =
                 Linear.attach_file(secret_context(workspace), path, "Proof",
                   linear_client: fn _query, _variables, _opts ->
                     flunk("Linear should not request an upload for private sensitive filenames")
                   end,
                   upload_client: fn _url, _opts ->
                     flunk("private sensitive filenames should not be uploaded")
                   end
                 )
      after
        File.rm_rf(workspace)
      end
    end

    test "attach_file accepts normal files" do
      workspace = tmp_workspace!("linear-agent-file-normal")
      path = Path.join(workspace, "proof.txt")
      File.write!(path, "ordinary proof")
      test_pid = self()

      linear_client = fn query, variables, _opts ->
        send(test_pid, {:linear_client_called, query, variables})

        cond do
          query =~ "SymphonyAgentFileUpload" ->
            {:ok,
             %{
               "data" => %{
                 "fileUpload" => %{
                   "success" => true,
                   "uploadFile" => %{
                     "uploadUrl" => "https://uploads.example.test/proof",
                     "assetUrl" => "https://assets.example.test/proof.txt",
                     "headers" => []
                   }
                 }
               }
             }}

          query =~ "SymphonyAgentAttachFile" ->
            {:ok,
             %{
               "data" => %{
                 "attachmentCreate" => %{
                   "success" => true,
                   "attachment" => %{"id" => "attachment-ok", "url" => variables.url}
                 }
               }
             }}
        end
      end

      upload_client = fn url, opts ->
        send(test_pid, {:upload_called, url, opts})
        {:ok, %{status: 200}}
      end

      try do
        assert {:ok, response} =
                 Linear.attach_file(secret_context(workspace), path, "Proof",
                   linear_client: linear_client,
                   upload_client: upload_client
                 )

        assert get_in(response, ["data", "attachmentCreate", "attachment", "id"]) == "attachment-ok"
        assert_receive {:upload_called, "https://uploads.example.test/proof", upload_opts}
        assert upload_opts[:body] == "ordinary proof"
      after
        File.rm_rf(workspace)
      end
    end
  end

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

  defp secret_context(workspace) do
    %{issue: %Issue{id: "issue-secret", identifier: "RSM-3189"}, workspace: workspace}
  end

  defp secret_fixtures do
    [
      "sk-ant-" <> String.duplicate("a", 24),
      openai_fixture(),
      "sk-proj-" <> String.duplicate("a", 24),
      "sk-svcacct-" <> String.duplicate("a", 24),
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

  defp openai_fixture, do: "sk-" <> String.duplicate("a", 48)

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

  defp tmp_workspace!(name) do
    workspace = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end
end
