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

  test "detect recognizes expanded credential formats" do
    cases = [
      {:linear_api_key, "lin_api_" <> String.duplicate("a", 40)},
      {:npm_token, "npm_" <> String.duplicate("b", 36)},
      {:slack_token, "xoxb-" <> String.duplicate("1-", 12) <> String.duplicate("A", 24)},
      {:slack_token, "xoxp-" <> String.duplicate("2-", 12) <> String.duplicate("B", 24)},
      {:slack_token, "xapp-" <> String.duplicate("C", 24)},
      {:gitlab_personal_access_token, "glpat-" <> String.duplicate("D", 20)},
      {:gcp_service_account_key, gcp_service_account_fixture()},
      {:private_key_block, private_key_fixture()},
      {:stripe_secret_key, "sk_live_" <> String.duplicate("e", 24)},
      {:stripe_secret_key, "rk_live_" <> String.duplicate("f", 24)},
      {:twilio_account_sid, "AC" <> String.duplicate("0123456789abcdef", 2)},
      {:twilio_api_key, "SK" <> String.duplicate("fedcba9876543210", 2)},
      {:sendgrid_api_key, "SG." <> String.duplicate("G", 22) <> "." <> String.duplicate("H", 43)},
      {:authorization_bearer_token, "Authorization: Bearer " <> String.duplicate("I", 40)}
    ]

    for {kind, payload} <- cases do
      assert SecretScanner.detect("credential=#{payload}") == kind
    end
  end

  test "expanded credential patterns reject similar-looking non-credentials" do
    refute SecretScanner.detect("lin_api_documentation")
    refute SecretScanner.detect("npm_documentation")
    refute SecretScanner.detect("xoxb-documentation")
    refute SecretScanner.detect("xapp-documentation")
    refute SecretScanner.detect("glpat-documentation")
    refute SecretScanner.detect(~s({"type":"service_account"}))
    refute SecretScanner.detect("-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----")
    refute SecretScanner.detect("sk_live_documentation")
    refute SecretScanner.detect("rk_live_documentation")
    refute SecretScanner.detect("AC" <> String.duplicate("0", 31))
    refute SecretScanner.detect("SK" <> String.duplicate("0", 31))
    refute SecretScanner.detect("SG.short.token")
    refute SecretScanner.detect("Authorization: Bearer documentation")
  end

  test "redact replaces detected secrets with markers and reports matched kinds" do
    linear_token = "lin_api_" <> String.duplicate("a", 40)
    stripe_token = "sk_live_" <> String.duplicate("b", 24)

    assert {redacted, [:linear_api_key, :stripe_secret_key]} =
             SecretScanner.redact("linear=#{linear_token} stripe=#{stripe_token}")

    assert redacted =~ "[REDACTED:linear_api_key]"
    assert redacted =~ "[REDACTED:stripe_secret_key]"
    refute redacted =~ linear_token
    refute redacted =~ stripe_token
  end

  test "redact handles non-string and non-UTF-8 binary content" do
    assert SecretScanner.redact(:not_a_string) == {:not_a_string, []}

    benign_binary = <<0xFF, 0xFE, "ordinary binary payload", 0x00>>
    refute String.valid?(benign_binary)
    assert SecretScanner.redact(benign_binary) == {benign_binary, []}

    secret_binary = <<0xFF, "lin_api_", String.duplicate("a", 40)::binary, 0xFE>>
    refute String.valid?(secret_binary)
    assert SecretScanner.redact(secret_binary) == {"[REDACTED:linear_api_key]", [:linear_api_key]}
  end

  test "audit_redaction records only redaction metadata" do
    workspace = tmp_workspace!("secret-scanner-redaction-audit")
    audit_dir = Path.join(workspace, "audit")

    try do
      assert :ok = SecretScanner.audit_redaction([], %{}, "tool_name", "body", dir: audit_dir)
      assert [] = audit_events(audit_dir)

      assert :ok =
               SecretScanner.audit_redaction([:linear_api_key, :stripe_secret_key], %{}, "tool_name", "body", dir: audit_dir)

      assert [
               %{
                 "event_type" => "agent_tool_secret_redaction",
                 "field" => "body",
                 "reason" => "secret_pattern_detected",
                 "secret_patterns" => ["linear_api_key", "stripe_secret_key"],
                 "tool" => "tool_name"
               }
             ] = audit_events(audit_dir)
    after
      File.rm_rf(workspace)
    end
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
                 %{"issue" => %{"id" => "issue-secret", "identifier" => "ACME-3189"}},
                 "tool_name",
                 "body",
                 dir: audit_dir
               )

      assert [%{"issue_identifier" => "ACME-3189", "tool" => "tool_name"}] = audit_events(audit_dir)
    after
      File.rm_rf(workspace)
    end
  end

  test "non-string content is accepted without scanning" do
    assert :ok = SecretScanner.reject_if_secret_pattern(%{body: openai_fixture()}, %{}, "tool_name", "body", [])
  end

  test "field-list rejection helper rejects the first secret-bearing field" do
    workspace = tmp_workspace!("secret-scanner-field-list")
    audit_dir = Path.join(workspace, "audit")

    try do
      assert :ok = SecretScanner.reject_fields_if_secret_pattern([body: "ordinary body"], %{}, "tool_name")

      assert :ok =
               SecretScanner.reject_fields_if_secret_pattern(
                 [title: "ordinary title", metadata: %{body: openai_fixture()}, empty: nil],
                 %{},
                 "tool_name",
                 dir: audit_dir
               )

      assert {:error, :secret_pattern_detected} =
               SecretScanner.reject_fields_if_secret_pattern(
                 [title: "token=" <> openai_fixture(), body: "token=" <> openai_fixture()],
                 %{},
                 "tool_name",
                 dir: audit_dir
               )

      assert [%{"event_type" => "refused_agent_action", "field" => "title", "tool" => "tool_name"}] =
               audit_events(audit_dir)
    after
      File.rm_rf(workspace)
    end
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

  defp private_key_fixture do
    """
    -----BEGIN OPENSSH PRIVATE KEY-----
    #{String.duplicate("a", 64)}
    -----END OPENSSH PRIVATE KEY-----
    """
  end

  defp gcp_service_account_fixture do
    ~s({"type":"service_account","project_id":"project","private_key":"-----BEGIN PRIVATE KEY-----\\n#{String.duplicate("a", 64)}\\n-----END PRIVATE KEY-----\\n","client_email":"agent@example.test"})
  end

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
