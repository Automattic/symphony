defmodule SymphonyElixir.Init do
  @moduledoc """
  Scaffolds a starter Symphony operator config and repo workflow.
  """

  alias SymphonyElixir.Config.{Schema, SystemSchema}
  alias SymphonyElixir.Workflow

  @target_files ["WORKFLOW.md", "symphony.yml"]
  @languages [
    {:elixir, "mix.exs"},
    {:node, "package.json"},
    {:ruby, "Gemfile"},
    {:python, "pyproject.toml"},
    {:go, "go.mod"},
    {:rust, "Cargo.toml"}
  ]
  @template_root Path.expand("../../priv/templates/init", __DIR__)
  @symphony_template_path Path.join(@template_root, "symphony.yml.eex")
  @external_resource @symphony_template_path
  @compiled_symphony_template File.read!(@symphony_template_path)
  @compiled_workflow_templates Map.new([{:generic, nil} | @languages], fn {language, _marker} ->
                                 path = Path.join([@template_root, Atom.to_string(language), "WORKFLOW.md"])
                                 @external_resource path
                                 {language, File.read!(path)}
                               end)
  @switches [
    agent: :string,
    agent_kind: :string,
    force: :boolean,
    project: :string,
    project_slug: :string,
    team: :string
  ]

  @type agent_kind :: :codex | :claude
  @type language :: :elixir | :node | :ruby | :python | :go | :rust | :generic
  @type rendered_files :: %{required(String.t()) => String.t()}
  @type deps :: %{
          cwd: (-> Path.t()),
          diff: (Path.t(), String.t(), String.t() -> String.t()),
          file_regular?: (Path.t() -> boolean()),
          mkdir_p!: (Path.t() -> :ok),
          priv_dir: (-> Path.t()),
          prompt: (String.t() -> String.t() | nil),
          puts: (String.t() -> any()),
          read!: (Path.t() -> String.t()),
          write!: (Path.t(), String.t() -> :ok)
        }

  @spec run([String.t()]) :: :ok | {:error, String.t()}
  def run(args), do: run(args, runtime_deps())

  @spec run([String.t()], deps()) :: :ok | {:error, String.t()}
  def run(args, deps) do
    with {:ok, opts} <- parse_args(args),
         {:ok, answers} <- collect_answers(opts, deps),
         {:ok, rendered} <- render_files(answers, deps),
         :ok <- validate_rendered(rendered),
         :ok <- check_conflicts(rendered, opts.force, deps),
         :ok <- write_files(rendered, deps) do
      deps.puts.(success_banner(answers))
      :ok
    end
  end

  @spec detect_language(Path.t()) :: language()
  def detect_language(root) when is_binary(root) do
    case Enum.find(@languages, fn {_language, file} -> File.regular?(Path.join(root, file)) end) do
      {language, _file} -> language
      nil -> :generic
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        opts =
          opts
          |> Map.new()
          |> Map.put_new(:force, false)

        {:ok, opts}

      _other ->
        {:error, usage()}
    end
  end

  defp collect_answers(opts, deps) do
    with {:ok, team} <- required_value(opts, :team, "Linear team key: ", deps),
         {:ok, project_slug} <- project_slug(opts, deps),
         {:ok, agent_kind} <- agent_kind(opts, deps) do
      cwd = deps.cwd.()
      language = detect_language(cwd)

      {:ok,
       %{
         agent_command: agent_command(agent_kind),
         agent_kind: agent_kind,
         cwd: Path.expand(cwd),
         language: language,
         project_slug: project_slug,
         repo_name: repo_name(cwd),
         team: team,
         workspace_root: Path.join(Path.expand(cwd), ".symphony/workspaces")
       }}
    end
  end

  defp project_slug(opts, deps) do
    case Map.get(opts, :project_slug) || Map.get(opts, :project) do
      value when is_binary(value) -> normalize_required(value, "Linear project slug")
      _value -> prompt_required("Linear project slug: ", "Linear project slug", deps)
    end
  end

  defp agent_kind(opts, deps) do
    raw = Map.get(opts, :agent_kind) || Map.get(opts, :agent)

    raw =
      case raw do
        value when is_binary(value) -> value
        _value -> prompt_with_default("Agent kind [codex]: ", "codex", deps)
      end

    case raw |> to_string() |> String.trim() |> String.downcase() do
      "codex" -> {:ok, :codex}
      "claude" -> {:ok, :claude}
      _other -> {:error, "agent.kind must be one of: codex, claude"}
    end
  end

  defp required_value(opts, key, prompt, deps) do
    case Map.get(opts, key) do
      value when is_binary(value) -> normalize_required(value, Atom.to_string(key))
      _value -> prompt_required(prompt, Atom.to_string(key), deps)
    end
  end

  defp prompt_required(prompt, label, deps) do
    prompt
    |> deps.prompt.()
    |> normalize_required(label)
  end

  defp prompt_with_default(prompt, default, deps) do
    case deps.prompt.(prompt) do
      nil -> default
      value -> if String.trim(value) == "", do: default, else: value
    end
  end

  defp normalize_required(value, label) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "#{label} is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_required(_value, label), do: {:error, "#{label} is required"}

  defp render_files(answers, deps) do
    priv_dir = deps.priv_dir.()

    workflow_template =
      [priv_dir, "templates", "init", Atom.to_string(answers.language), "WORKFLOW.md"]
      |> Path.join()
      |> read_template(Map.fetch!(@compiled_workflow_templates, answers.language), deps)

    symphony_template =
      [priv_dir, "templates", "init", "symphony.yml.eex"]
      |> Path.join()
      |> read_template(@compiled_symphony_template, deps)

    assigns = Map.put(answers, :yaml, &yaml_quote/1)

    {:ok,
     %{
       "WORKFLOW.md" => EEx.eval_string(workflow_template, assigns: assigns),
       "symphony.yml" => EEx.eval_string(symphony_template, assigns: assigns)
     }}
  end

  defp validate_rendered(%{"WORKFLOW.md" => workflow, "symphony.yml" => symphony}) do
    with {:ok, repo_workflow} <- Workflow.parse_repo_workflow(workflow),
         {:ok, raw_system} <- Workflow.parse_symphony(symphony),
         {:ok, system} <- SystemSchema.parse(raw_system),
         {:ok, _settings} <-
           system
           |> SystemSchema.to_config_map()
           |> deep_merge(repo_workflow.config)
           |> Schema.parse() do
      :ok
    else
      {:error, reason} -> {:error, "Generated config failed validation: #{inspect(reason)}"}
    end
  end

  defp read_template(path, compiled_template, deps) do
    if deps.file_regular?.(path), do: deps.read!.(path), else: compiled_template
  end

  defp check_conflicts(rendered, force?, deps) do
    conflicts =
      rendered
      |> Enum.filter(fn {relative, _content} -> deps.file_regular?.(Path.join(deps.cwd.(), relative)) end)
      |> Enum.map(fn {relative, content} ->
        path = Path.join(deps.cwd.(), relative)
        deps.diff.(path, deps.read!.(path), content)
      end)

    if force? or conflicts == [] do
      :ok
    else
      {:error,
       [
         "Refusing to overwrite existing files without --force.",
         "Review the diff below, then rerun with --force if these replacements are intended.",
         "",
         Enum.join(conflicts, "\n")
       ]
       |> IO.iodata_to_binary()}
    end
  end

  defp write_files(rendered, deps) do
    Enum.each(@target_files, fn relative ->
      path = Path.join(deps.cwd.(), relative)
      directory = Path.dirname(path)

      deps.mkdir_p!.(directory)
      deps.write!.(path, Map.fetch!(rendered, relative))
    end)

    :ok
  end

  defp success_banner(answers) do
    """
    Created WORKFLOW.md and symphony.yml for #{answers.language}.

    Next steps:
      export LINEAR_API_KEY=...
      symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4000
      open http://127.0.0.1:4000
    """
    |> String.trim_trailing()
  end

  defp agent_command(:codex), do: "codex app-server"
  defp agent_command(:claude), do: "claude --dangerously-skip-permissions"

  defp repo_name(cwd) do
    cwd
    |> Path.expand()
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9_.-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "repo"
      name -> name
    end
  end

  defp yaml_quote(value) when is_atom(value), do: value |> Atom.to_string() |> yaml_quote()

  defp yaml_quote(value) do
    value
    |> to_string()
    |> Jason.encode!()
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value -> deep_merge(left_value, right_value) end)
  end

  defp deep_merge(_left, right), do: right

  defp usage do
    "Usage: symphony init [--team TEAM] [--project-slug PROJECT] [--agent codex|claude] [--force]"
  end

  defp runtime_deps do
    %{
      cwd: &File.cwd!/0,
      diff: &text_diff/3,
      file_regular?: &File.regular?/1,
      mkdir_p!: &File.mkdir_p!/1,
      priv_dir: &priv_dir/0,
      prompt: &IO.gets/1,
      puts: &IO.puts/1,
      read!: &File.read!/1,
      write!: &File.write!/2
    }
  end

  defp priv_dir, do: :symphony_elixir |> :code.priv_dir() |> List.to_string()

  defp text_diff(path, existing, generated) do
    existing_lines = existing |> String.split("\n", trim: false) |> Enum.map(&["-", &1, "\n"])
    generated_lines = generated |> String.split("\n", trim: false) |> Enum.map(&["+", &1, "\n"])

    [
      "--- ",
      path,
      " (existing)\n",
      "+++ ",
      path,
      " (generated)\n",
      existing_lines,
      generated_lines
    ]
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end
end
