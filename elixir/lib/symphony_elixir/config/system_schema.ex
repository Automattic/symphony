defmodule SymphonyElixir.Config.SystemSchema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @primary_key false
  @allowed_keys ~w(
    agent ci dependencies dispatch github learnings notifications observability polling pr_review quality_gate repos self_review
    server token_budget tracker verification watchdog worker workspace
  )

  defmodule Repo do
    @moduledoc false

    use Ecto.Schema

    import Ecto.Changeset

    @primary_key false
    @fields [:name, :path, :workflow, :base_branch, :team, :labels, :projects, :assignee, :default]

    defmodule Workspace do
      @moduledoc false

      use Ecto.Schema

      import Ecto.Changeset

      @primary_key false

      embedded_schema do
        field(:strategy, :string)
        field(:repo, :string)
        field(:fetch_before_dispatch, :boolean)
      end

      @type t :: %__MODULE__{}

      @spec changeset(t(), map()) :: Ecto.Changeset.t()
      def changeset(schema, attrs) do
        schema
        |> cast(attrs, [:strategy, :repo, :fetch_before_dispatch], empty_values: [])
        |> validate_inclusion(:strategy, ["clone", "worktree"])
      end
    end

    embedded_schema do
      field(:name, :string)
      field(:path, :string)
      field(:workflow, :string, default: "WORKFLOW.md")
      field(:base_branch, :string)
      field(:team, :string)
      field(:labels, {:array, :string}, default: [])
      field(:projects, {:array, :string}, default: [])
      field(:assignee, :string)
      field(:default, :boolean, default: false)
      embeds_one(:workspace, Workspace, on_replace: :update)
    end

    @type t :: %__MODULE__{}

    @spec changeset(t(), map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, @fields, empty_values: [])
      |> cast_embed(:workspace, with: &Workspace.changeset/2)
      |> validate_required([:name, :workflow])
      |> validate_string(:name)
      |> validate_optional_string(:path)
      |> validate_string(:workflow)
      |> validate_optional_string(:base_branch)
      |> validate_string(:team)
      |> normalize_string_list(:labels)
      |> normalize_string_list(:projects)
    end

    defp validate_string(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        if is_binary(value) and String.trim(value) != "" do
          []
        else
          [{field, "must be a non-empty string"}]
        end
      end)
    end

    defp validate_optional_string(changeset, field) do
      validate_change(changeset, field, fn ^field, value ->
        cond do
          is_nil(value) ->
            []

          is_binary(value) and String.trim(value) != "" ->
            []

          true ->
            [{field, "must be a non-empty string"}]
        end
      end)
    end

    defp normalize_string_list(changeset, field) do
      update_change(changeset, field, fn
        values when is_list(values) ->
          values
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        nil ->
          []
      end)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Schema.Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Schema.Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:watchdog, Schema.Watchdog, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Schema.Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Schema.Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:github, Schema.GitHub, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Schema.Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Schema.Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:pr_review, Schema.PrReview, on_replace: :update, defaults_to_struct: true)
    embeds_one(:ci, Schema.Ci, on_replace: :update, defaults_to_struct: true)
    embeds_one(:verification, Schema.Verification, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Schema.Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:quality_gate, Schema.QualityGate, on_replace: :update, defaults_to_struct: true)
    embeds_one(:learnings, Schema.Learnings, on_replace: :update, defaults_to_struct: true)
    embeds_one(:self_review, Schema.SelfReview, on_replace: :update, defaults_to_struct: true)
    embeds_one(:dependencies, Schema.Dependencies, on_replace: :update, defaults_to_struct: true)
    embeds_one(:notifications, Schema.Notifications, on_replace: :update, defaults_to_struct: true)
    embeds_many(:repos, Repo, on_replace: :delete)
  end

  @type t :: %__MODULE__{}

  @spec parse(map()) :: {:ok, t()} | {:error, {:invalid_symphony_config, String.t()}}
  def parse(config) when is_map(config) do
    config =
      config
      |> normalize_keys()
      |> drop_nil_values()
      |> normalize_operator_aliases()

    with :ok <- reject_unknown_keys(config) do
      config
      |> changeset()
      |> apply_action(:validate)
      |> case do
        {:ok, system_config} -> {:ok, finalize_repos(system_config)}
        {:error, changeset} -> {:error, {:invalid_symphony_config, format_errors(changeset)}}
      end
    end
  end

  @spec to_config_map(t()) :: map()
  def to_config_map(%__MODULE__{} = system_config) do
    %{
      "tracker" => struct_to_map(system_config.tracker),
      "polling" => struct_to_map(system_config.polling),
      "watchdog" => struct_to_map(system_config.watchdog),
      "workspace" => workspace_to_map(system_config.workspace),
      "worker" => struct_to_map(system_config.worker),
      "github" => struct_to_map(system_config.github),
      "agent" => agent_to_map(system_config.agent),
      "observability" => struct_to_map(system_config.observability),
      "pr_review" => struct_to_map(system_config.pr_review),
      "ci" => struct_to_map(system_config.ci),
      "verification" => struct_to_map(system_config.verification),
      "server" => struct_to_map(system_config.server),
      "quality_gate" => struct_to_map(system_config.quality_gate),
      "learnings" => struct_to_map(system_config.learnings),
      "self_review" => struct_to_map(system_config.self_review),
      "dependencies" => struct_to_map(system_config.dependencies),
      "notifications" => notifications_to_map(system_config.notifications)
    }
    |> drop_nil_values()
  end

  @spec primary_repo(t()) :: Repo.t() | nil
  def primary_repo(%__MODULE__{repos: repos}) when is_list(repos) do
    Enum.find(repos, & &1.default) || List.first(repos)
  end

  def primary_repo(%__MODULE__{}), do: nil

  @spec repo_workflow_path(Repo.t() | map()) :: Path.t()
  def repo_workflow_path(%Repo{} = repo) do
    repo
    |> Map.from_struct()
    |> repo_workflow_path()
  end

  def repo_workflow_path(repo) when is_map(repo) do
    path = repo_value(repo, :path)
    workflow = repo_value(repo, :workflow, "WORKFLOW.md")

    cond do
      non_empty_string?(path) and non_empty_string?(workflow) ->
        Workflow.repo_workflow_file_path(%{path: path, workflow: workflow})

      non_empty_string?(workflow) ->
        workflow_path_from_symphony_file(workflow)

      true ->
        raise ArgumentError,
              "repo workflow path requires non-empty `workflow`; got: #{inspect(repo)}"
    end
  end

  def repo_workflow_path(repo) do
    raise ArgumentError,
          "repo workflow path requires a repo map or #{inspect(Repo)} struct; got: #{inspect(repo)}"
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Schema.Tracker.changeset/2)
    |> cast_embed(:polling, with: &Schema.Polling.changeset/2)
    |> cast_embed(:watchdog, with: &Schema.Watchdog.changeset/2)
    |> cast_embed(:workspace, with: &Schema.Workspace.changeset/2)
    |> cast_embed(:worker, with: &Schema.Worker.changeset/2)
    |> cast_embed(:github, with: &Schema.GitHub.changeset/2)
    |> cast_embed(:agent, with: &Schema.Agent.changeset/2)
    |> cast_embed(:observability, with: &Schema.Observability.changeset/2)
    |> cast_embed(:pr_review, with: &Schema.PrReview.changeset/2)
    |> cast_embed(:ci, with: &Schema.Ci.changeset/2)
    |> cast_embed(:verification, with: &Schema.Verification.changeset/2)
    |> cast_embed(:server, with: &Schema.Server.changeset/2)
    |> cast_embed(:quality_gate, with: &Schema.QualityGate.changeset/2)
    |> cast_embed(:learnings, with: &Schema.Learnings.changeset/2)
    |> cast_embed(:self_review, with: &Schema.SelfReview.changeset/2)
    |> cast_embed(:dependencies, with: &Schema.Dependencies.changeset/2)
    |> cast_embed(:notifications, with: &Schema.Notifications.changeset/2)
    |> cast_embed(:repos, with: &Repo.changeset/2, required: true)
    |> validate_length(:repos, min: 1)
    |> validate_unique_repo_names()
    |> validate_single_default_repo()
  end

  defp reject_unknown_keys(config) do
    unknown_keys = Map.keys(config) -- @allowed_keys

    case unknown_keys do
      [] -> :ok
      [key | _rest] -> {:error, {:invalid_symphony_config, "unknown symphony.yml key `#{key}`"}}
    end
  end

  defp normalize_operator_aliases(config) do
    config
    |> merge_dispatch_alias()
    |> merge_token_budget_alias()
    |> Map.drop(["dispatch", "token_budget"])
  end

  defp merge_dispatch_alias(%{"dispatch" => %{} = dispatch} = config) do
    agent = Map.get(config, "agent", %{})

    agent =
      case Map.get(dispatch, "max_concurrent") do
        nil -> agent
        max_concurrent -> Map.put_new(agent, "max_concurrent_agents", max_concurrent)
      end

    Map.put(config, "agent", agent)
  end

  defp merge_dispatch_alias(config), do: config

  defp merge_token_budget_alias(%{"token_budget" => %{} = token_budget} = config) do
    agent = Map.get(config, "agent", %{})

    agent =
      agent
      |> put_new_present("max_tokens_per_issue", Map.get(token_budget, "max_per_issue"))
      |> put_new_present("max_tokens_per_day", Map.get(token_budget, "total_per_day"))

    Map.put(config, "agent", agent)
  end

  defp merge_token_budget_alias(config), do: config

  defp put_new_present(map, _key, nil), do: map
  defp put_new_present(map, key, value), do: Map.put_new(map, key, value)

  defp validate_unique_repo_names(changeset) do
    duplicate_names =
      changeset
      |> get_change(:repos, [])
      |> Enum.flat_map(fn repo_changeset ->
        case get_field(repo_changeset, :name) do
          name when is_binary(name) and name != "" -> [name]
          _name -> []
        end
      end)
      |> duplicate_values()

    case duplicate_names do
      [] -> changeset
      _duplicates -> add_error(changeset, :repos, "names must be unique")
    end
  end

  defp validate_single_default_repo(changeset) do
    default_count =
      changeset
      |> get_change(:repos, [])
      |> Enum.count(&truthy_change?(&1, :default))

    if default_count <= 1 do
      changeset
    else
      add_error(changeset, :repos, "can include at most one default repo")
    end
  end

  defp truthy_change?(changeset, field), do: get_field(changeset, field) == true

  defp duplicate_values(values) do
    {_seen, duplicates} =
      Enum.reduce(values, {MapSet.new(), MapSet.new()}, fn value, {seen, duplicates} ->
        if MapSet.member?(seen, value) do
          {seen, MapSet.put(duplicates, value)}
        else
          {MapSet.put(seen, value), duplicates}
        end
      end)

    MapSet.to_list(duplicates)
  end

  defp finalize_repos(%__MODULE__{} = system_config) do
    repos =
      Enum.map(system_config.repos, fn %Repo{} = repo ->
        repo_path = resolve_optional_path(repo.path)
        %{repo | path: repo_path}
      end)

    %{system_config | repos: repos}
  end

  defp resolve_path(path) when is_binary(path), do: Path.expand(path)
  defp resolve_optional_path(path) when is_binary(path), do: resolve_path(path)
  defp resolve_optional_path(_path), do: nil

  defp workflow_path_from_symphony_file(workflow) do
    case Path.type(workflow) do
      :absolute -> Path.expand(workflow)
      _type -> Path.expand(workflow, Path.dirname(Workflow.symphony_file_path()))
    end
  end

  defp repo_value(repo, key, default \\ nil) do
    string_key = to_string(key)

    cond do
      Map.has_key?(repo, key) -> Map.get(repo, key)
      Map.has_key?(repo, string_key) -> Map.get(repo, string_key)
      true -> default
    end
  end

  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp agent_to_map(%Schema.Agent{} = agent) do
    agent
    |> struct_to_map()
    |> Map.update("network_access", nil, &struct_to_map/1)
  end

  defp workspace_to_map(%Schema.Workspace{} = workspace) do
    workspace
    |> struct_to_map()
    |> Map.update("sandbox", nil, &struct_to_map/1)
    |> Map.update("lifecycle", nil, &struct_to_map/1)
  end

  defp notifications_to_map(%Schema.Notifications{} = notifications) do
    %{
      "enabled" => notifications.enabled,
      "redact_titles" => notifications.redact_titles,
      "channels" => Enum.map(notifications.channels || [], &struct_to_map/1)
    }
  end

  defp struct_to_map(nil), do: nil

  defp struct_to_map(struct) when is_struct(struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), struct_to_map(value))
    end)
  end

  defp struct_to_map(values) when is_list(values), do: Enum.map(values, &struct_to_map/1)
  defp struct_to_map(value), do: value

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value), do: drop_nil_values(value, [])

  defp drop_nil_values(value, path) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      child_path = path ++ [key]

      case drop_nil_values(nested, child_path) do
        nil -> put_non_nil_or_preserved_value(acc, key, child_path, nil)
        dropped -> Map.put(acc, key, dropped)
      end
    end)
  end

  defp drop_nil_values(value, path) when is_list(value), do: Enum.map(value, &drop_nil_values(&1, path))
  defp drop_nil_values(value, _path), do: value

  defp put_non_nil_or_preserved_value(acc, key, path, nil) do
    if preserve_explicit_nil_path?(path), do: Map.put(acc, key, nil), else: acc
  end

  defp preserve_explicit_nil_path?(["agent", key]) when key in ["max_tokens_per_issue", "max_tokens_per_day"],
    do: true

  defp preserve_explicit_nil_path?(_path), do: false

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix = if is_nil(prefix), do: to_string(key), else: prefix <> "." <> to_string(key)
      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.flat_map(errors, fn
      error when is_binary(error) -> [prefix <> " " <> error]
      nested -> flatten_errors(nested, prefix)
    end)
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", inspect(value))
    end)
  end
end
