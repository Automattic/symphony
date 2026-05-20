defmodule SymphonyElixir.InitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.{Init, Workflow}

  test "scaffolds valid Elixir workflow and symphony config from flags" do
    root = tmp_dir()
    File.write!(Path.join(root, "mix.exs"), "")
    parent = self()

    assert :ok =
             Init.run(
               ["--team", "ENG", "--project-slug", "harness", "--agent", "codex"],
               deps(root, parent)
             )

    assert_receive {:stdout, banner}
    assert banner =~ "Created WORKFLOW.md and symphony.yml for elixir"
    assert banner =~ "export LINEAR_API_KEY=..."
    assert banner =~ "open http://127.0.0.1:4000"

    workflow = File.read!(Path.join(root, "WORKFLOW.md"))
    symphony = File.read!(Path.join(root, "symphony.yml"))

    assert workflow =~ "mix deps.get"
    assert workflow =~ "validation:\n  - mix test"
    assert symphony =~ "team: \"ENG\""
    assert symphony =~ "project_slug: \"harness\""
    assert symphony =~ "kind: \"codex\""
    assert symphony =~ "quality_gate:\n  enabled: false"
    assert symphony =~ "path: #{Jason.encode!(Path.expand(root))}"

    assert_valid_rendered_config!(workflow, symphony)
  end

  test "prompts for values omitted from flags" do
    root = tmp_dir()
    parent = self()

    prompt = fn
      "Linear team key: " -> "OPS\n"
      "Linear project slug: " -> "platform\n"
      "Agent kind [codex]: " -> "\n"
    end

    assert :ok =
             Init.run(
               [],
               deps(root, parent, prompt: prompt)
             )

    assert File.read!(Path.join(root, "symphony.yml")) =~ "team: \"OPS\""
    assert File.read!(Path.join(root, "symphony.yml")) =~ "project_slug: \"platform\""
    assert File.read!(Path.join(root, "symphony.yml")) =~ "kind: \"codex\""
  end

  test "defaults prompted agent kind when prompt returns nil" do
    root = tmp_dir()

    assert :ok =
             Init.run(
               ["--team", "OPS", "--project-slug", "platform"],
               deps(root, self(), prompt: fn "Agent kind [codex]: " -> nil end)
             )

    assert File.read!(Path.join(root, "symphony.yml")) =~ "kind: \"codex\""
  end

  test "rejects missing required prompt values" do
    assert {:error, "team is required"} =
             Init.run(
               ["--project-slug", "platform"],
               deps(tmp_dir(), self(), prompt: fn "Linear team key: " -> nil end)
             )

    assert {:error, "team is required"} =
             Init.run(
               ["--team", " ", "--project-slug", "platform"],
               deps(tmp_dir(), self())
             )
  end

  test "reports generated config validation failures" do
    root = tmp_dir()
    priv_dir = tmp_dir()
    File.mkdir_p!(Path.join(priv_dir, "templates/init/generic"))
    File.write!(Path.join(priv_dir, "templates/init/generic/WORKFLOW.md"), valid_generic_workflow())
    File.write!(Path.join(priv_dir, "templates/init/symphony.yml.eex"), "agent:\n  kind: other\n")

    assert {:error, message} =
             Init.run(
               ["--team", "ENG", "--project-slug", "harness", "--agent", "codex"],
               deps(root, self(), priv_dir: fn -> priv_dir end)
             )

    assert message =~ "Generated config failed validation"
    assert message =~ "invalid_symphony_config"
  end

  test "refuses to overwrite existing files without force and includes a diff" do
    root = tmp_dir()
    File.write!(Path.join(root, "WORKFLOW.md"), "old workflow\n")
    File.write!(Path.join(root, "symphony.yml"), "old config\n")

    assert {:error, message} =
             Init.run(
               ["--team", "ENG", "--project-slug", "harness", "--agent", "claude"],
               deps(root, self())
             )

    assert message =~ "Refusing to overwrite existing files without --force"
    assert message =~ "--- #{Path.join(root, "WORKFLOW.md")} (existing)"
    assert message =~ "-old workflow"
    assert message =~ "+tracker:"
    assert File.read!(Path.join(root, "WORKFLOW.md")) == "old workflow\n"
    assert File.read!(Path.join(root, "symphony.yml")) == "old config\n"
  end

  test "force overwrites existing files" do
    root = tmp_dir()
    File.write!(Path.join(root, "WORKFLOW.md"), "old workflow\n")
    File.write!(Path.join(root, "symphony.yml"), "old config\n")

    assert :ok =
             Init.run(
               ["--team", "ENG", "--project-slug", "harness", "--agent", "claude", "--force"],
               deps(root, self())
             )

    assert File.read!(Path.join(root, "WORKFLOW.md")) =~ "You are working on a Linear issue"
    assert File.read!(Path.join(root, "symphony.yml")) =~ "command: \"claude --dangerously-skip-permissions\""
  end

  test "detects supported stacks by marker files" do
    markers = [
      {"mix.exs", :elixir},
      {"package.json", :node},
      {"Gemfile", :ruby},
      {"pyproject.toml", :python},
      {"go.mod", :go},
      {"Cargo.toml", :rust}
    ]

    for {marker, language} <- markers do
      root = tmp_dir()
      File.write!(Path.join(root, marker), "")

      assert Init.detect_language(root) == language
    end

    assert Init.detect_language(tmp_dir()) == :generic
  end

  test "rejects unsupported agent kind" do
    assert {:error, "agent.kind must be one of: codex, claude"} =
             Init.run(
               ["--team", "ENG", "--project-slug", "harness", "--agent", "other"],
               deps(tmp_dir(), self())
             )
  end

  test "falls back to repo name when cwd has no basename" do
    parent = self()

    assert :ok =
             Init.run(
               ["--team", "ENG", "--project-slug", "harness", "--agent", "codex"],
               deps("/", parent,
                 file_regular?: fn _path -> false end,
                 mkdir_p!: fn _path -> :ok end,
                 write!: fn path, content -> send(parent, {:write, path, content}) end
               )
             )

    assert_receive {:write, "/symphony.yml", symphony}
    assert symphony =~ "name: \"repo\""
  end

  defp deps(root, parent, overrides \\ []) do
    Map.merge(
      %{
        cwd: fn -> root end,
        diff: &test_diff/3,
        file_regular?: &File.regular?/1,
        mkdir_p!: &File.mkdir_p!/1,
        priv_dir: fn -> Path.expand("priv") end,
        prompt: fn _prompt -> nil end,
        puts: fn message -> send(parent, {:stdout, message}) end,
        read!: &File.read!/1,
        write!: &File.write!/2
      },
      Map.new(overrides)
    )
  end

  defp test_diff(path, existing, generated) do
    [
      "--- ",
      path,
      " (existing)\n",
      "+++ ",
      path,
      " (generated)\n",
      existing |> String.split("\n", trim: false) |> Enum.map(&["-", &1, "\n"]),
      generated |> String.split("\n", trim: false) |> Enum.map(&["+", &1, "\n"])
    ]
    |> IO.iodata_to_binary()
  end

  defp assert_valid_rendered_config!(workflow, symphony) do
    assert {:ok, repo_workflow} = Workflow.parse_repo_workflow(workflow)
    assert {:ok, raw_system} = Workflow.parse_symphony(symphony)
    assert {:ok, system} = SystemSchema.parse(raw_system)

    assert {:ok, _settings} =
             system
             |> SystemSchema.to_config_map()
             |> deep_merge(repo_workflow.config)
             |> Schema.parse()
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value -> deep_merge(left_value, right_value) end)
  end

  defp deep_merge(_left, right), do: right

  defp tmp_dir do
    root = Path.join(System.tmp_dir!(), "symphony-init-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  defp valid_generic_workflow do
    """
    ---
    hooks: {}
    verification:
      enabled: false
    ---

    Prompt
    """
  end
end
