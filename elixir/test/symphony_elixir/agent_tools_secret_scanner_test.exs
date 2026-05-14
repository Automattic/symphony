defmodule SymphonyElixir.AgentTools.SecretScannerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentTools.SecretScanner

  test "detect returns nil for non-string and non-secret content" do
    refute SecretScanner.detect(:not_a_string)
    refute SecretScanner.detect("normal code review text")
  end

  test "OpenAI patterns require proj-/svcacct- prefix or full 48-char legacy form" do
    assert SecretScanner.detect("sk-proj-" <> String.duplicate("a", 24)) == :openai_api_key
    assert SecretScanner.detect("sk-svcacct-" <> String.duplicate("a", 24)) == :openai_api_key
    assert SecretScanner.detect("sk-" <> String.duplicate("a", 48)) == :openai_api_key

    refute SecretScanner.detect("sk-" <> String.duplicate("a", 24))
    refute SecretScanner.detect("sk-test-" <> String.duplicate("a", 24))
  end

  test "Anthropic keys are reported as anthropic_api_key regardless of pattern ordering" do
    assert SecretScanner.detect("sk-ant-" <> String.duplicate("a", 24)) == :anthropic_api_key
  end

  test "non-UTF-8 binary content is scanned for high-confidence prefixes" do
    payload = <<0xFF, 0xFE, "leading bytes ", "sk-ant-", String.duplicate("a", 24)::binary, 0x00>>
    refute String.valid?(payload)
    assert SecretScanner.detect(payload) == :anthropic_api_key

    github_payload = <<0xFF, "ghp_", String.duplicate("A", 24)::binary, 0xFE>>
    refute String.valid?(github_payload)
    assert SecretScanner.detect(github_payload) == :github_token

    benign_binary = <<0xFF, 0xFE, "ordinary binary payload", 0x00>>
    refute String.valid?(benign_binary)
    refute SecretScanner.detect(benign_binary)
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
