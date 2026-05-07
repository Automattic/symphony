defmodule SymphonyElixir.Verification do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Verification.{DevServer, PortPool}

  @env_var "SYMPHONY_VERIFICATION_PORT"
  @dev_server_supervisor SymphonyElixir.Verification.DevServerSupervisor

  @type context :: %{
          run_id: String.t(),
          port: pos_integer(),
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil
        }

  @doc false
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc false
  @spec child_specs_for_runtime(Schema.t()) :: [Supervisor.child_spec() | module() | {module(), term()}]
  def child_specs_for_runtime(%Schema{} = settings) do
    if enabled?(settings) do
      [
        PortPool,
        {DynamicSupervisor, strategy: :one_for_one, name: @dev_server_supervisor}
      ]
    else
      []
    end
  end

  @doc false
  @spec enabled?(Schema.t()) :: boolean()
  def enabled?(%Schema{verification: %{enabled: enabled}}), do: enabled == true
  def enabled?(_settings), do: false

  @doc false
  @spec allocate_for_dispatch(Issue.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, context() | nil} | {:error, term()}
  def allocate_for_dispatch(%Issue{} = issue, run_id, worker_host, opts \\ []) when is_binary(run_id) do
    settings = Keyword.get(opts, :settings, Config.settings!())

    if enabled?(settings) do
      attrs = %{
        run_id: run_id,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        worker_host: worker_host,
        port_range: settings.verification.port_allocation.range
      }

      case PortPool.allocate(attrs) do
        {:ok, allocation} -> {:ok, allocation_context(allocation)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  @doc false
  @spec context_for_agent(Issue.t(), keyword()) :: {:ok, context() | nil} | {:error, term()}
  def context_for_agent(%Issue{} = issue, opts \\ []) do
    settings = Keyword.get(opts, :settings, Config.settings!())

    cond do
      not enabled?(settings) ->
        {:ok, nil}

      context = Keyword.get(opts, :verification) ->
        {:ok, normalize_context(context)}

      true ->
        run_id = Keyword.get(opts, :run_id) || standalone_run_id(issue)
        allocate_for_dispatch(issue, run_id, Keyword.get(opts, :worker_host), settings: settings)
    end
  end

  @doc false
  @spec env(context() | nil) :: [{String.t(), String.t()}]
  def env(%{port: port}) when is_integer(port), do: [{@env_var, to_string(port)}]
  def env(_context), do: []

  @doc false
  @spec start_dev_server(context() | nil, Path.t(), keyword()) :: {:ok, pid() | nil} | {:error, term()}
  def start_dev_server(nil, _workspace, _opts), do: {:ok, nil}

  def start_dev_server(%{port: port, run_id: run_id} = context, workspace, opts)
      when is_integer(port) and is_binary(run_id) and is_binary(workspace) do
    settings = Keyword.get(opts, :settings, Config.settings!())
    dev_server = settings.verification.dev_server

    case dev_server.start_cmd do
      command when is_binary(command) and command != "" ->
        start_dev_server_child(
          run_id: run_id,
          port: port,
          workspace: workspace,
          config: dev_server,
          env: env(context),
          owner: self()
        )

      _ ->
        {:ok, nil}
    end
  end

  @doc false
  @spec stop_dev_server(pid() | nil) :: :ok
  def stop_dev_server(pid) when is_pid(pid), do: DevServer.stop(pid)
  def stop_dev_server(_pid), do: :ok

  @doc false
  @spec release(context() | nil, String.t()) :: :ok
  def release(%{run_id: run_id}, reason) when is_binary(run_id), do: PortPool.release(run_id, reason)
  def release(_context, _reason), do: :ok

  defp allocation_context(allocation) when is_map(allocation) do
    %{
      run_id: Map.fetch!(allocation, :run_id),
      port: Map.fetch!(allocation, :port),
      issue_id: Map.get(allocation, :issue_id),
      issue_identifier: Map.get(allocation, :issue_identifier)
    }
  end

  defp normalize_context(context) when is_map(context), do: allocation_context(context)

  defp start_dev_server_child(opts) do
    case Process.whereis(@dev_server_supervisor) do
      pid when is_pid(pid) ->
        DynamicSupervisor.start_child(pid, {DevServer, opts})
        |> normalize_dev_server_start_result()

      _ ->
        DevServer.start(opts)
    end
  end

  defp normalize_dev_server_start_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp normalize_dev_server_start_result({:ok, pid, _info}) when is_pid(pid), do: {:ok, pid}
  defp normalize_dev_server_start_result({:error, reason}), do: {:error, unwrap_dev_server_start_error(reason)}
  defp normalize_dev_server_start_result(result), do: result

  defp unwrap_dev_server_start_error({:shutdown, reason}), do: unwrap_dev_server_start_error(reason)
  defp unwrap_dev_server_start_error({:failed_to_start_child, _id, reason}), do: unwrap_dev_server_start_error(reason)
  defp unwrap_dev_server_start_error(reason), do: reason

  defp standalone_run_id(%Issue{id: issue_id}) when is_binary(issue_id) do
    "#{issue_id}-verification-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end

  defp standalone_run_id(_issue) do
    "verification-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
  end
end
