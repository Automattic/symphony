defmodule Mix.Tasks.Symphony.AuditTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Symphony.Audit
  alias SymphonyElixir.AuditLog

  setup do
    previous_shell = Mix.shell()
    previous_audit_dir = Application.get_env(:symphony_elixir, :audit_log_dir)
    previous_state_root = Application.get_env(:symphony_elixir, :state_root_override)
    Mix.shell(Mix.Shell.Process)

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-audit-task-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      Mix.shell(previous_shell)
      restore_app_env(:audit_log_dir, previous_audit_dir)
      restore_app_env(:state_root_override, previous_state_root)
      File.rm_rf(test_root)
    end)

    {:ok, test_root: test_root}
  end

  test "prints audit events for an issue and date range", %{test_root: test_root} do
    audit_dir = AuditLog.default_dir(test_root)

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-1",
                 run_id: "run-1",
                 timestamp: ~U[2026-05-07 12:00:00Z],
                 event_type: "tool_call",
                 command: "mix test"
               },
               dir: audit_dir
             )

    Audit.run(["issue-1", "--from", "2026-05-07", "--to", "2026-05-07", "--logs-root", test_root])

    assert_receive {:mix_shell, :info, [line]}
    assert %{"issue_id" => "issue-1", "event_type" => "tool_call", "command" => "mix test"} = Jason.decode!(line)
  end

  test "prints audit events from a state root override", %{test_root: test_root} do
    state_root = Path.join(test_root, "state")
    audit_dir = Path.join(state_root, "audit")

    assert :ok =
             AuditLog.record(
               %{
                 issue_id: "issue-state",
                 run_id: "run-state",
                 timestamp: ~U[2026-05-07 12:00:00Z],
                 event_type: "tool_call",
                 command: "mix test"
               },
               dir: audit_dir
             )

    Audit.run(["issue-state", "--from", "2026-05-07", "--to", "2026-05-07", "--state-root", state_root])

    assert_receive {:mix_shell, :info, [line]}
    assert %{"issue_id" => "issue-state", "event_type" => "tool_call", "command" => "mix test"} = Jason.decode!(line)
  end

  test "raises on missing issue id" do
    assert_raise Mix.Error, ~r/Usage: mix symphony.audit/, fn ->
      Audit.run([])
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
