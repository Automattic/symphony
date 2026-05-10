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
    assert SystemSchema.repo_workflow_path(loaded_repo) == Path.join(repo.path, "WORKFLOW.md")

    assert {:ok, settings} = Config.settings()
    assert settings.tracker.kind == "memory"
    assert settings.hooks.after_create == "echo setup"
    assert settings.verification.enabled == true
  end

  test "startup config accepts single repo without repo-level routing selectors", %{root: root} do
    repo = write_repo!(root, "app", "Prompt\n")

    write_symphony_text!(root, """
    tracker:
      kind: linear
      api_key: token
      project_slug: project
    agent:
      kind: codex
      command: codex app-server
    repos:
      - name: app
        path: #{repo.path}
        workflow: WORKFLOW.md
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:ok, system_config} = Config.system()
    assert [%SystemSchema.Repo{name: "app", team: nil}] = system_config.repos
  end

  test "startup config rejects identical routing match rules", %{root: root} do
    write_symphony_text!(root, """
    tracker:
      kind: memory
    agent:
      kind: codex
      command: codex app-server
    repos:
      - name: web
        path: #{Path.join(root, "web")}
        workflow: WORKFLOW.md
        team: RSM
        labels:
          - backend
      - name: api
        path: #{Path.join(root, "api")}
        workflow: WORKFLOW.md
        team: RSM
        labels:
          - backend
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:error, {:invalid_symphony_config, message}} = Config.system()
    assert message =~ "repos routing rules are invalid"
    assert message =~ "identical match rules"
    assert message =~ "web"
    assert message =~ "api"
  end

  test "startup config rejects ambiguous non-default catch-all routing", %{root: root} do
    write_symphony_text!(root, """
    tracker:
      kind: memory
    agent:
      kind: codex
      command: codex app-server
    repos:
      - name: fallback
        path: #{Path.join(root, "fallback")}
        workflow: WORKFLOW.md
        team: RSM
      - name: api
        path: #{Path.join(root, "api")}
        workflow: WORKFLOW.md
        team: RSM
        labels:
          - api
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:error, {:invalid_symphony_config, message}} = Config.system()
    assert message =~ "repos routing rules are invalid"
    assert message =~ "ambiguous team-only catch-all"
    assert message =~ "fallback"
  end

  test "system schema uses explicit default repo as primary" do
    assert {:ok, system_config} =
             SystemSchema.parse(
               system_config(%{
                 "repos" => [
                   repo_config("secondary"),
                   repo_config("primary", %{"default" => true})
                 ]
               })
             )

    assert SystemSchema.primary_repo(system_config).name == "primary"
  end

  test "system schema rejects duplicate repo names and multiple defaults" do
    assert {:error, {:invalid_symphony_config, duplicate_message}} =
             SystemSchema.parse(
               system_config(%{
                 "repos" => [
                   repo_config("app"),
                   repo_config("app")
                 ]
               })
             )

    assert duplicate_message =~ "repos names must be unique"

    assert {:error, {:invalid_symphony_config, default_message}} =
             SystemSchema.parse(
               system_config(%{
                 "repos" => [
                   repo_config("first", %{"default" => true}),
                   repo_config("second", %{"default" => true})
                 ]
               })
             )

    assert default_message =~ "repos can include at most one default repo"
  end

  test "system schema rejects unknown top-level keys and empty repos" do
    assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `unknown`"}} =
             SystemSchema.parse(system_config(%{"unknown" => true}))

    assert {:error, {:invalid_symphony_config, "unknown symphony.yml key `routing`"}} =
             SystemSchema.parse(system_config(%{"routing" => []}))

    assert {:error, {:invalid_symphony_config, empty_repos_message}} =
             SystemSchema.parse(system_config(%{"repos" => []}))

    assert empty_repos_message =~ "repos"
    assert empty_repos_message =~ "can't be blank"
  end

  test "system schema applies operator aliases and expands repo paths" do
    assert {:ok, system_config} =
             SystemSchema.parse(
               system_config(%{
                 "dispatch" => %{"max_concurrent" => 3},
                 "token_budget" => %{"max_per_issue" => 100, "total_per_day" => 200},
                 "repos" => [
                   repo_config("app", %{"path" => "relative/app", "workflow" => "config/Workflow.md"})
                 ]
               })
             )

    assert %SystemSchema{repos: [repo]} = system_config
    assert repo.path == Path.expand("relative/app")
    assert SystemSchema.repo_workflow_path(repo) == Path.expand("config/Workflow.md", repo.path)

    config_map = SystemSchema.to_config_map(system_config)
    assert get_in(config_map, ["agent", "max_concurrent_agents"]) == 3
    assert get_in(config_map, ["agent", "max_tokens_per_issue"]) == 100
    assert get_in(config_map, ["agent", "max_tokens_per_day"]) == 200
  end

  test "repo workflow path can be declared without a repo checkout path", %{root: root} do
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:ok, system_config} =
             SystemSchema.parse(
               system_config(%{
                 "repos" => [
                   %{
                     "name" => "app",
                     "workflow" => "workflows/app.md",
                     "team" => "Test"
                   }
                 ]
               })
             )

    assert %SystemSchema{repos: [repo]} = system_config
    assert is_nil(repo.path)
    assert SystemSchema.repo_workflow_path(repo) == Path.join(root, "workflows/app.md")
  end

  test "repo workspace overrides global workspace population settings", %{root: root} do
    repo = write_repo!(root, "app", "Prompt\n")
    workspace_root = Path.join(root, "workspaces")
    primary_clone = Path.join(root, "primary")

    write_symphony_text!(root, """
    tracker:
      kind: memory
    workspace:
      root: #{workspace_root}
    agent:
      kind: codex
      command: codex app-server
    repos:
      - name: app
        workflow: #{SystemSchema.repo_workflow_path(repo)}
        team: Test
        workspace:
          strategy: worktree
          repo: #{primary_clone}
          fetch_before_dispatch: false
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    settings = Config.settings_for_repo!("app")
    assert settings.workspace.root == workspace_root
    assert settings.workspace.strategy == "worktree"
    assert settings.workspace.repo == primary_clone
    refute settings.workspace.fetch_before_dispatch
  end

  test "multi-repo config rejects global worktree strategy without repo overrides", %{root: root} do
    web_repo = write_repo!(root, "web", "Web prompt\n")
    api_repo = write_repo!(root, "api", "API prompt\n")

    write_symphony_text!(root, """
    tracker:
      kind: memory
    workspace:
      strategy: worktree
      repo: #{Path.join(root, "primary")}
    agent:
      kind: codex
      command: codex app-server
    repos:
      - name: web
        path: #{web_repo.path}
        workflow: WORKFLOW.md
        team: Test
        default: true
      - name: api
        path: #{api_repo.path}
        workflow: WORKFLOW.md
        team: Test
        labels: ["api"]
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "workspace.strategy is global"
    assert message =~ "repos[].workspace"
    assert message =~ "web"
    assert message =~ "api"
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

  test "runtime validation uses cached repo workflows after invalid reload", %{root: root} do
    valid_repo = write_repo!(root, "valid", "Valid prompt\n")
    api_repo = write_repo!(root, "api", "API prompt\n")

    write_symphony_text!(root, """
    tracker:
      kind: memory
    agent:
      kind: codex
      command: codex app-server
    repos:
      - name: valid
        path: #{valid_repo.path}
        workflow: WORKFLOW.md
        team: Test
        default: true
      - name: api
        path: #{api_repo.path}
        workflow: WORKFLOW.md
        team: Test
        labels:
          - api
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    start_repo_supervisor!(valid_repo)
    start_repo_supervisor!(api_repo)

    assert :ok = Config.validate!()
    assert {:ok, %{prompt: "API prompt"}} = RepoSupervisor.current_workflow("api")

    File.write!(SystemSchema.repo_workflow_path(api_repo), """
    ---
    tracker:
      kind: memory
    ---
    Invalid prompt
    """)

    assert {:ok, %{prompt: "API prompt"}} = RepoSupervisor.current_workflow("api")
    assert :ok = Config.validate!()

    assert {:error, {:invalid_workflow_config, message}} = Config.validate_repo_workflows()
    assert message =~ "WORKFLOW.md: repo api"
    assert message =~ "symphony.yml"
  end

  test "repo-specific workflow is used for prompt and repo-local settings", %{root: root} do
    web_repo =
      write_repo!(root, "web", """
      ---
      hooks:
        before_run: echo web
      ---
      Web {{ repo_key }} {{ issue.identifier }}
      """)

    api_repo =
      write_repo!(root, "api", """
      ---
      hooks:
        before_run: echo api
      verification:
        enabled: true
        port_allocation:
          range: [4300, 4301]
      ---
      API {{ repo_key }} {{ issue.identifier }}
      """)

    write_symphony_text!(root, """
    tracker:
      kind: memory
    agent:
      kind: codex
      command: codex app-server
    repos:
      - name: web
        path: #{web_repo.path}
        workflow: WORKFLOW.md
        team: Test
        default: true
      - name: api
        path: #{api_repo.path}
        workflow: WORKFLOW.md
        team: Test
        labels:
          - api
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert {:ok, %{prompt: "Web {{ repo_key }} {{ issue.identifier }}"}} =
             Config.workflow_for_repo("web")

    assert {:ok, %{prompt: "API {{ repo_key }} {{ issue.identifier }}"}} =
             Config.workflow_for_repo("api")

    assert Config.settings_for_repo!("web").hooks.before_run == "echo web"
    assert Config.settings_for_repo!("api").hooks.before_run == "echo api"
    assert Config.settings_for_repo!("api").verification.port_allocation.range == [4300, 4301]

    issue = %SymphonyElixir.Linear.Issue{
      id: "issue-api",
      identifier: "RSM-API",
      title: "Route to API",
      state: "Todo",
      repo_key: "api",
      labels: ["api"]
    }

    assert SymphonyElixir.PromptBuilder.build_prompt(issue) == "API api RSM-API"
  end

  test "reloading one repo workflow restarts only that repo subtree", %{root: root} do
    first_repo = write_repo!(root, "first", "First prompt\n")
    second_repo = write_repo!(root, "second", "Second prompt\n")

    start_repo_supervisor!(first_repo)
    start_repo_supervisor!(second_repo)

    first_before = GenServer.whereis(RepoSupervisor.workflow_store_name("first"))
    second_before = GenServer.whereis(RepoSupervisor.workflow_store_name("second"))

    File.write!(SystemSchema.repo_workflow_path(first_repo), "Updated first prompt\n")

    assert :ok = RepoSupervisor.reload("first")

    first_after = GenServer.whereis(RepoSupervisor.workflow_store_name("first"))
    second_after = GenServer.whereis(RepoSupervisor.workflow_store_name("second"))

    assert is_pid(first_after)
    assert first_after != first_before
    assert second_after == second_before
    assert {:ok, %{prompt: "Updated first prompt"}} = RepoSupervisor.current_workflow("first")
    assert {:ok, %{prompt: "Second prompt"}} = RepoSupervisor.current_workflow("second")
  end

  test "repo supervisor reload returns a clear error for unknown repos" do
    assert {:error, :repo_supervisor_not_found} = RepoSupervisor.reload("missing-repo")
  end

  test "repo supervisor rejects repo structs without workflow data" do
    Application.put_env(:symphony_elixir, :primary_repo_name, nil)

    repo = %SystemSchema.Repo{name: "broken", workflow: nil, team: "Test"}

    assert_raise ArgumentError, ~r/repo workflow path requires non-empty `workflow`/, fn ->
      RepoSupervisor.start_link(repo)
    end
  end

  test "application child specs clear bootstrap env when later config loading fails", %{root: root} do
    repo =
      write_repo!(root, "invalid", """
      ---
      tracker:
        kind: memory
      ---
      Invalid prompt
      """)

    write_symphony!(root, [repo])
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))
    Application.put_env(:symphony_elixir, :primary_repo_name, "stale")
    Application.put_env(:symphony_elixir, :workflow_file_path, "/tmp/stale-workflow.md")

    assert_raise ArgumentError, ~r/WORKFLOW.md:.*symphony.yml/, fn ->
      SymphonyElixir.Application.child_specs_for_runtime(%{})
    end

    refute Application.get_env(:symphony_elixir, :primary_repo_name)
    refute Application.get_env(:symphony_elixir, :workflow_file_path)
  end

  test "application start clears bootstrap env when supervisor start fails", %{root: root} do
    repo = write_repo!(root, "app", "Prompt\n")
    write_symphony!(root, [repo])
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    blocker = Process.whereis(SymphonyElixir.Supervisor)
    assert is_pid(blocker)

    assert {:error, {:already_started, ^blocker}} = SymphonyElixir.Application.start(:normal, [])
    refute Application.get_env(:symphony_elixir, :primary_repo_name)
    refute Application.get_env(:symphony_elixir, :workflow_file_path)
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

  defp write_symphony_text!(root, content) do
    File.write!(Path.join(root, "symphony.yml"), content)
  end

  defp system_config(overrides) do
    Map.merge(
      %{
        "tracker" => %{"kind" => "memory"},
        "agent" => %{"kind" => "codex", "command" => "codex app-server"},
        "repos" => [repo_config("app")]
      },
      overrides
    )
  end

  defp repo_config(name, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "path" => "tmp/#{name}",
        "workflow" => "WORKFLOW.md",
        "team" => "Test"
      },
      overrides
    )
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
