defmodule SymphonyElixir.DependencyGateTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DependencyAudit
  alias SymphonyElixir.DependencyGate

  test "build/3 defaults the audit module and invalid gates allow by default" do
    assert DependencyGate.hold_state() == "In Review"

    gate = DependencyGate.build("/tmp/workspace", nil, nil)

    assert gate.audit_module == DependencyAudit
    assert DependencyGate.audit(:not_a_gate) == {:ok, []}
  end

  test "react_to_hold logs tracker update failures and continues" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_result, {:error, :rate_limited})

    issue = %Issue{
      id: "issue-dependency-gate-failure",
      identifier: "ACME-GATE-FAILURE",
      title: "Dependency gate failure",
      description: "Exercise tracker update failure branch",
      state: "In Progress"
    }

    gate = DependencyGate.build("/tmp/workspace", issue, nil, repo_key: "default")

    assert capture_log(fn ->
             assert :ok = DependencyGate.react_to_hold(gate, [])
           end) =~ "Failed to move dependency hold issue to In Review"
  end

  test "react_to_audit_error tolerates missing issue context" do
    gate = DependencyGate.build("/tmp/workspace", nil, nil, repo_key: "default")

    assert :ok = DependencyGate.react_to_audit_error(gate, :boom)
  end
end
