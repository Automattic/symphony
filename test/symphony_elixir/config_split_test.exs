defmodule SymphonyElixir.ConfigSplitTest do
  use ExUnit.Case

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Cache
  alias SymphonyElixir.Config.SystemSchema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.Repo.Supervisor, as: RepoSupervisor

  setup do
    original_symphony_path = SymphonyElixir.Workflow.symphony_file_path()
    original_workflow_path = SymphonyElixir.Workflow.workflow_file_path()
    original_primary_repo = Application.get_env(:symphony_elixir, :primary_repo_name)
    original_cache_reader = Application.get_env(:symphony_elixir, :config_cache_file_reader)

    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-config-split-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    ensure_repo_registry_started!()
    Cache.clear()

    on_exit(fn ->
      Cache.clear()
      SymphonyElixir.Workflow.set_symphony_file_path(original_symphony_path)
      SymphonyElixir.Workflow.set_workflow_file_path(original_workflow_path)
      restore_app_env(:primary_repo_name, original_primary_repo)
      restore_app_env(:config_cache_file_reader, original_cache_reader)
      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "settings caches symphony.yml reads after warmup", %{root: root} do
    repo = write_repo!(root, "app", "Repo prompt\n")
    write_symphony!(root, [repo])
    symphony_path = Path.join(root, "symphony.yml")
    SymphonyElixir.Workflow.set_symphony_file_path(symphony_path)

    counter = :counters.new(1, [])

    Application.put_env(:symphony_elixir, :config_cache_file_reader, fn path ->
      if Path.expand(path) == Path.expand(symphony_path) do
        :counters.add(counter, 1, 1)
      end

      File.read(path)
    end)

    assert {:ok, first} = Config.settings()

    for _ <- 1..5 do
      assert {:ok, ^first} = Config.settings()
    end

    assert :counters.get(counter, 1) == 1
  end

  test "settings reloads when symphony.yml changes", %{root: root} do
    repo = write_repo!(root, "app", "Repo prompt\n")
    write_symphony_text!(root, symphony_text([repo], poll_interval_ms: 11_111))
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    assert Config.settings!().polling.interval_ms == 11_111

    write_symphony_text!(root, symphony_text([repo], poll_interval_ms: 222_222))

    assert Config.settings!().polling.interval_ms == 222_222
  end

  test "symphony_file_path override isolates cached settings", %{root: root} do
    repo = write_repo!(root, "app", "Repo prompt\n")
    first_path = Path.join(root, "first-symphony.yml")
    second_path = Path.join(root, "second-symphony.yml")

    File.write!(first_path, symphony_text([repo], poll_interval_ms: 12_345))
    File.write!(second_path, symphony_text([repo], poll_interval_ms: 54_321))

    SymphonyElixir.Workflow.set_symphony_file_path(first_path)
    assert Config.settings!().polling.interval_ms == 12_345

    SymphonyElixir.Workflow.set_symphony_file_path(second_path)
    assert Config.settings!().polling.interval_ms == 54_321
  end

  test "settings serves last good symphony config after parse error", %{root: root} do
    repo = write_repo!(root, "app", "Repo prompt\n")
    write_symphony_text!(root, symphony_text([repo], poll_interval_ms: 33_333))
    symphony_path = Path.join(root, "symphony.yml")
    SymphonyElixir.Workflow.set_symphony_file_path(symphony_path)

    assert Config.settings!().polling.interval_ms == 33_333

    File.write!(symphony_path, "tracker: [unterminated\n")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert Config.settings!().polling.interval_ms == 33_333
      end)

    assert log =~ "keeping last known good value"
  end

  test "missing symphony.yml keeps existing error shape", %{root: root} do
    missing_path = Path.join(root, "missing-symphony.yml")
    SymphonyElixir.Workflow.set_symphony_file_path(missing_path)

    assert {:error, {:missing_symphony_file, ^missing_path, :enoent}} = Config.system()
  end

  test "repo workflow files are cached and reloaded by absolute path", %{root: root} do
    web_repo = write_repo!(root, "web", "Web prompt\n")

    api_repo =
      write_repo!(root, "api", """
      ---
      hooks:
        before_run: echo api
      ---
      API prompt
      """)

    write_symphony_text!(root, symphony_text([web_repo, api_repo], poll_interval_ms: 30_000))
    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    api_workflow_path = Path.join(api_repo.path, "WORKFLOW.md")
    counter = :counters.new(1, [])

    Application.put_env(:symphony_elixir, :config_cache_file_reader, fn path ->
      if Path.expand(path) == Path.expand(api_workflow_path) do
        :counters.add(counter, 1, 1)
      end

      File.read(path)
    end)

    assert Config.settings_for_repo!("api").hooks.before_run == "echo api"
    assert Config.settings_for_repo!("api").hooks.before_run == "echo api"
    assert :counters.get(counter, 1) == 1

    File.write!(api_workflow_path, """
    ---
    hooks:
      before_run: echo api changed
    ---
    API prompt changed
    """)

    assert Config.settings_for_repo!("api").hooks.before_run == "echo api changed"
  end

  test "symphony.yml is required before application children can be built", %{root: root} do
    missing_path = Path.join(root, "missing-symphony.yml")
    SymphonyElixir.Workflow.set_symphony_file_path(missing_path)

    assert_raise ArgumentError, ~r/Missing symphony.yml/, fn ->
      SymphonyElixir.Application.child_specs_for_runtime(%{"SYMPHONY_DISABLE_ORCHESTRATOR" => "1"})
    end
  end

  test "application runtime validation reports missing modules and functions compactly" do
    assert :ok =
             SymphonyElixir.Application.validate_runtime_modules!([
               {SymphonyElixir.ProjectGuidePrompt, :append_to_prompt, 4},
               {SymphonyElixir.ProjectGuides, :append_to_prompt, 4}
             ])

    assert_raise ArgumentError, ~r/runtime module unavailable: SymphonyElixir.MissingRuntimeModule/, fn ->
      SymphonyElixir.Application.validate_runtime_modules!([
        {SymphonyElixir.MissingRuntimeModule, :run, 1}
      ])
    end

    assert_raise ArgumentError, ~r/runtime function unavailable: SymphonyElixir.ProjectGuides.missing\/4/, fn ->
      SymphonyElixir.Application.validate_runtime_modules!([
        {SymphonyElixir.ProjectGuides, :missing, 4}
      ])
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

  test "system schema accepts operator-level verification defaults" do
    assert {:ok, system_config} =
             SystemSchema.parse(
               system_config(%{
                 "verification" => %{
                   "enabled" => true,
                   "port_allocation" => %{"range" => [4400, 4402]}
                 }
               })
             )

    config_map = SystemSchema.to_config_map(system_config)
    assert get_in(config_map, ["verification", "enabled"]) == true
    assert get_in(config_map, ["verification", "port_allocation", "range"]) == [4400, 4402]
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

  test "repo workflow with an empty prompt falls back to the default prompt", %{root: root} do
    api_repo =
      write_repo!(root, "api", """
      ---
      ---
      """)

    write_symphony_text!(root, """
    tracker:
      kind: memory
    agent:
      kind: codex
      command: codex app-server
    repos:
      - name: api
        path: #{api_repo.path}
        workflow: WORKFLOW.md
        team: Test
    """)

    SymphonyElixir.Workflow.set_symphony_file_path(Path.join(root, "symphony.yml"))

    issue = %Issue{
      id: "issue-api-fallback",
      identifier: "RSM-FALLBACK",
      title: "Use default prompt",
      state: "Todo",
      repo_key: "api"
    }

    prompt = PromptBuilder.build_prompt(issue)

    assert prompt =~ "You are working on a Linear issue."
    assert prompt =~ "Identifier: RSM-FALLBACK"
    assert prompt =~ "Title: <linear_issue_title>\nUse default prompt\n</linear_issue_title>"
  end

  test "repo workflow verification deep merges over operator defaults", %{root: root} do
    web_repo =
      write_repo!(root, "web", """
      ---
      verification:
        enabled: false
      ---
      Web prompt
      """)

    api_repo =
      write_repo!(root, "api", """
      ---
      verification:
        dev_server:
          start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
          health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/"
      ---
      API prompt
      """)

    write_symphony_text!(root, """
    tracker:
      kind: memory
    verification:
      enabled: true
      port_allocation:
        range: [4400, 4402]
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

    web_settings = Config.settings_for_repo!("web")
    api_settings = Config.settings_for_repo!("api")

    refute web_settings.verification.enabled
    assert api_settings.verification.enabled
    assert api_settings.verification.port_allocation.range == [4400, 4402]
    assert api_settings.verification.dev_server.start_cmd == "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
    assert api_settings.verification.dev_server.health_check_url == "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/"
  end

  test "application starts verification supervisors when any repo enables verification", %{root: root} do
    web_repo = write_repo!(root, "web", "Web prompt\n")

    api_repo =
      write_repo!(root, "api", """
      ---
      verification:
        enabled: true
      ---
      API prompt
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

    verification_children = SymphonyElixir.Application.child_specs_for_runtime(%{})

    dev_server_supervisor_child = {
      DynamicSupervisor,
      strategy: :one_for_one, name: SymphonyElixir.Verification.DevServerSupervisor
    }

    assert SymphonyElixir.Verification.PortPool in verification_children
    assert dev_server_supervisor_child in verification_children
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

    blocker = ensure_supervisor_name_blocked!()
    assert is_pid(blocker)

    assert {:error, {:already_started, ^blocker}} = SymphonyElixir.Application.start(:normal, [])
    refute Application.get_env(:symphony_elixir, :primary_repo_name)
    refute Application.get_env(:symphony_elixir, :workflow_file_path)
  end

  defp write_symphony!(root, repos) do
    File.write!(Path.join(root, "symphony.yml"), """
    tracker:
      kind: memory
    agent:
      kind: codex
      command: codex app-server
    repos:
    #{repos_yaml(repos)}
    """)
  end

  defp write_symphony_text!(root, content) do
    File.write!(Path.join(root, "symphony.yml"), content)
  end

  defp symphony_text(repos, opts) do
    poll_interval_ms = Keyword.fetch!(opts, :poll_interval_ms)

    """
    tracker:
      kind: memory
    polling:
      interval_ms: #{poll_interval_ms}
    agent:
      kind: codex
      command: codex app-server
    repos:
    #{repos_yaml(repos)}
    """
  end

  defp repos_yaml(repos) do
    repos
    |> Enum.with_index()
    |> Enum.map_join("", fn {repo, index} ->
      routing_yaml =
        if index == 0 do
          "    default: true\n"
        else
          "    labels:\n      - #{repo.name}\n"
        end

      """
        - name: #{repo.name}
          path: #{repo.path}
          workflow: WORKFLOW.md
          team: Test
      #{routing_yaml}\
      """
    end)
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

  defp ensure_repo_registry_started! do
    case Process.whereis(SymphonyElixir.Repo.Registry) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        start_supervised!({Registry, keys: :unique, name: SymphonyElixir.Repo.Registry})
        :ok
    end
  end

  defp ensure_supervisor_name_blocked! do
    case Process.whereis(SymphonyElixir.Supervisor) do
      pid when is_pid(pid) ->
        pid

      _ ->
        {:ok, pid} = Agent.start_link(fn -> :blocked end, name: SymphonyElixir.Supervisor)

        on_exit(fn -> stop_supervisor_name_blocker(pid) end)

        pid
    end
  end

  defp stop_supervisor_name_blocker(pid) do
    if Process.alive?(pid) do
      Agent.stop(pid)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
