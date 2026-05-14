defmodule SymphonyElixir.AgentTools.SecretScannerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.SecretScanner

  test "detect returns nil for non-string and non-secret content" do
    refute SecretScanner.detect(:not_a_string)
    refute SecretScanner.detect("normal code review text")
  end

  test "four-argument rejection helper records string-key issue contexts" do
    workspace = tmp_workspace!("secret-scanner-string-issue")
    audit_dir = Path.join(workspace, "audit")

    try do
      assert {:error, :secret_pattern_detected} =
               SecretScanner.reject_if_secret_pattern(
                 "token=" <> openai_fixture(),
                 %{"issue" => %{"id" => "issue-secret", "identifier" => "RSM-3189"}},
                 "tool_name",
                 "body",
                 dir: audit_dir
               )

      assert [%{"issue_identifier" => "RSM-3189", "tool" => "tool_name"}] = audit_events(audit_dir)
    after
      File.rm_rf(workspace)
    end
  end

  test "non-string content is accepted without scanning" do
    assert :ok = SecretScanner.reject_if_secret_pattern(%{body: openai_fixture()}, %{}, "tool_name", "body", [])
  end

  test "missing issue context still writes a refused-action audit event" do
    workspace = tmp_workspace!("secret-scanner-missing-issue")
    audit_dir = Path.join(workspace, "audit")

    try do
      assert {:error, :secret_pattern_detected} =
               SecretScanner.reject_if_secret_pattern("token=" <> openai_fixture(), %{}, "tool_name", "body", dir: audit_dir)

      assert [%{"event_type" => "refused_agent_action", "tool" => "tool_name"}] = audit_events(audit_dir)
    after
      File.rm_rf(workspace)
    end
  end

  test "audit write failures are logged without changing rejection result" do
    workspace = tmp_workspace!("secret-scanner-audit-error")
    audit_path = Path.join(workspace, "audit-file")
    File.write!(audit_path, "not a directory")

    try do
      log =
        capture_log(fn ->
          assert {:error, :secret_pattern_detected} =
                   SecretScanner.reject_if_secret_pattern(
                     "token=" <> openai_fixture(),
                     %{},
                     "tool_name",
                     "body",
                     dir: audit_path
                   )
        end)

      assert log =~ "Audit log failed to record secret-pattern rejection"
    after
      File.rm_rf(workspace)
    end
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

  defp tmp_workspace!(name) do
    workspace = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    workspace
  end
end
