defmodule SymphonyElixir.ConfigSplitTest do
  use ExUnit.Case

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Repo.Supervisor, as: RepoSupervisor

  setup do
    original_symphony_path = SymphonyElixir.Workflow.symphony_file_path()
    original_workflow_path = SymphonyElixir.Workflow.workflow_file_path()
    original_primary_repo = Application.get_env(:symphony_elixir, :primary_repo_name)

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-config-split-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    on_exit(fn ->
      SymphonyElixir.Workflow.set_symphony_file_path(original_symphony_path)
      SymphonyElixir.Workflow.set_workflow_file_path(original_workflow_path)
      restore_app_env(:primary_repo_name, original_primary_repo)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "symphony.yml is required before application children can be built", %{root: root} do
    missing_path = Path.join(root, "missing-symphony.yml")
    SymphonyElixir.Workflow.set_symphony_file_path(missing_path)

    assert_raise ArgumentError, ~r/Missing symphony.yml/, fn ->
      SymphonyElixir.Application.child_specs_for_runtime(%{"SYMPHONY_DISABLE_ORCHESTRATOR" => "1"})
    end
  end

  test "repo WORKFLOW.md rejects operator-level config and points at symphony.yml", %{root: root} do
    repo =
      write_repo!(root, "app", """
      ---
      agent:
        kind: codex
        command: codex app-server
      ---
      Repo prompt
      """)

    write_symphony!(root, [repo])
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert_raise ArgumentError, ~r/operator-level key `agent`.*symphony.yml/, fn ->
      Config.settings!()
    end
  end

  test "system schema accepts operator config and repo workflow accepts only repo-local keys", %{root: root} do
    repo =
      write_repo!(root, "app", """
      ---
      hooks:
        after_create: echo setup
      verification:
        enabled: true
      validation:
        - mix test
      ---
      Repo prompt
      """)

    write_symphony!(root, [repo])
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:ok, %SystemSchema{repos: [loaded_repo]}} = Config.system()
    assert loaded_repo.name == "app"
    assert loaded_repo.workflow_path == Path.join(repo.path, "WORKFLOW.md")

    assert {:ok, settings} = Config.settings()
    assert settings.tracker.kind == "memory"
    assert settings.hooks.after_create == "echo setup"
    assert settings.verification.enabled == true
  end

  test "repo supervisors isolate invalid repo workflow failures", %{root: root} do
    valid_repo = write_repo!(root, "valid", "Valid prompt\n")

    invalid_repo =
      write_repo!(root, "invalid", """
      ---
      tracker:
        kind: memory
      ---
      Invalid prompt
      """)

    start_repo_supervisor!(valid_repo)
    start_repo_supervisor!(invalid_repo)

    assert {:ok, %{prompt: "Valid prompt"}} = RepoSupervisor.current_workflow("valid")
    assert {:error, {:invalid_repo_workflow_config, message}} = RepoSupervisor.current_workflow("invalid")
    assert message =~ "symphony.yml"
  end

  test "reloading one repo workflow restarts only that repo subtree", %{root: root} do
    first_repo = write_repo!(root, "first", "First prompt\n")
    second_repo = write_repo!(root, "second", "Second prompt\n")

    start_repo_supervisor!(first_repo)
    start_repo_supervisor!(second_repo)

    first_before = GenServer.whereis(RepoSupervisor.workflow_store_name("first"))
    second_before = GenServer.whereis(RepoSupervisor.workflow_store_name("second"))

    File.write!(first_repo.workflow_path, "Updated first prompt\n")

    assert :ok = RepoSupervisor.reload("first")

    first_after = GenServer.whereis(RepoSupervisor.workflow_store_name("first"))
    second_after = GenServer.whereis(RepoSupervisor.workflow_store_name("second"))

    assert is_pid(first_after)
    assert first_after != first_before
    assert second_after == second_before
    assert {:ok, %{prompt: "Updated first prompt"}} = RepoSupervisor.current_workflow("first")
    assert {:ok, %{prompt: "Second prompt"}} = RepoSupervisor.current_workflow("second")
  end

  defp write_symphony!(root, repos) do
    repos_yaml =
      repos
      |> Enum.map_join("", fn repo ->
        """
          - name: #{repo.name}
            path: #{repo.path}
            workflow: WORKFLOW.md
            team: Test
        """
      end)

    File.write!(Path.join(root, "symphony.yml"), """
    tracker:
      kind: memory
    agent:
      kind: codex
      command: codex app-server
    repos:
    #{repos_yaml}
    """)
  end

  defp write_repo!(root, name, workflow_content) do
    repo_path = Path.join(root, name)
    workflow_path = Path.join(repo_path, "WORKFLOW.md")
    File.mkdir_p!(repo_path)
    File.write!(workflow_path, workflow_content)

    %SystemSchema.Repo{
      name: name,
      path: repo_path,
      workflow: "WORKFLOW.md",
      workflow_path: workflow_path,
      team: "Test"
    }
  end

  defp start_repo_supervisor!(repo) do
    Application.put_env(:symphony_elixir, :primary_repo_name, nil)
    {:ok, pid} = RepoSupervisor.start_link(repo)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid) do
        try do
          Supervisor.stop(pid)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    pid
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
