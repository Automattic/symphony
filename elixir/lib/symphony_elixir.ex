defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.SystemSchema

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children = child_specs_for_runtime()

    Supervisor.start_link(
      children,
      strategy: :one_for_one,
      name: SymphonyElixir.Supervisor
    )
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end

  @doc false
  @spec child_specs_for_runtime(map()) :: [Supervisor.child_spec() | module() | {module(), term()}]
  def child_specs_for_runtime(env \\ System.get_env()) when is_map(env) do
    system_config = Config.system!()
    primary_repo = SystemSchema.primary_repo(system_config)
    Application.put_env(:symphony_elixir, :primary_repo_name, primary_repo.name)
    SymphonyElixir.Workflow.set_workflow_file_path(primary_repo.workflow_path)

    core_children =
      [
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        {Registry, keys: :unique, name: SymphonyElixir.Repo.Registry},
        repo_supervisor_specs(system_config.repos),
        SymphonyElixir.Notifications.Notifier
      ]
      |> List.flatten()

    if orchestrator_runtime_disabled?(env) do
      core_children
    else
      (core_children ++
         [
           SymphonyElixir.RunStore
         ] ++
         SymphonyElixir.Verification.child_specs_for_runtime(Config.settings!()) ++
         [
           SymphonyElixir.Orchestrator,
           pr_review_child_spec(),
           ci_child_spec(),
           SymphonyElixir.HttpServer,
           SymphonyElixir.StatusDashboard
         ])
      |> Enum.reject(&is_nil/1)
    end
  end

  defp repo_supervisor_specs(repos) do
    Enum.map(repos, &SymphonyElixir.Repo.Supervisor.child_spec/1)
  end

  defp pr_review_child_spec do
    case SymphonyElixir.Config.settings!().pr_review.mode do
      "polling" -> SymphonyElixir.PrReviewPoller
      _mode -> nil
    end
  end

  defp ci_child_spec do
    settings = SymphonyElixir.Config.settings!()

    if settings.pr_review.mode == "polling" and settings.ci.enabled do
      SymphonyElixir.CiPoller
    end
  end

  defp orchestrator_runtime_disabled?(env) do
    truthy_env?(Map.get(env, "SYMPHONY_DISABLE_ORCHESTRATOR")) ||
      (truthy_env?(Map.get(env, "SYMPHONY_AGENT_RUNTIME")) && Map.get(env, "MIX_ENV") != "test")
  end

  defp truthy_env?(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
  end

  defp truthy_env?(_value), do: false
end
