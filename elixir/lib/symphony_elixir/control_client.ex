defmodule SymphonyElixir.ControlClient do
  @moduledoc """
  Local-node client for operator pause, resume, and stop controls.
  """

  alias SymphonyElixir.Orchestrator

  @default_target_node "symphony@127.0.0.1"
  @default_timeout_ms 15_000

  @type control_result :: {:ok, map()} | :unavailable | {:error, term()}

  @spec pause_dispatch(String.t(), keyword()) :: control_result()
  def pause_dispatch(reason, opts \\ []) when is_binary(reason) do
    call(:pause_dispatch, [reason], opts)
  end

  @spec resume_dispatch(keyword()) :: control_result()
  def resume_dispatch(opts \\ []) do
    call(:resume_dispatch, [], opts)
  end

  @spec stop_running(String.t(), keyword()) :: control_result()
  def stop_running(issue_id_or_identifier, opts \\ []) when is_binary(issue_id_or_identifier) do
    call(:stop_running, [issue_id_or_identifier], opts)
  end

  @spec call(atom(), [term()], keyword()) :: control_result()
  def call(function, args, opts \\ []) when is_atom(function) and is_list(args) do
    if Keyword.get(opts, :prefer_local?, true) and Process.whereis(Orchestrator) do
      apply(Orchestrator, function, args)
    else
      remote_call(function, args, opts)
    end
  end

  defp remote_call(function, args, opts) do
    target = target_node(opts)

    with :ok <- ensure_local_node_started(target, opts),
         :ok <- maybe_set_cookie(opts),
         true <- connect(target, opts) do
      case rpc_call(target, Orchestrator, function, args, opts) do
        {:badrpc, reason} -> {:error, {:remote_call_failed, reason}}
        result -> result
      end
    else
      false -> {:error, {:node_connect_failed, target}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp target_node(opts) do
    opts
    |> Keyword.get(:target_node, System.get_env("SYMPHONY_NODE") || @default_target_node)
    |> normalize_node()
  end

  defp normalize_node(node_name) when is_atom(node_name), do: node_name
  defp normalize_node(node_name) when is_binary(node_name), do: String.to_atom(node_name)

  defp ensure_local_node_started(target, opts) do
    node_alive? = Keyword.get(opts, :node_alive?, &Node.alive?/0)

    if node_alive?.() do
      :ok
    else
      local_node = Keyword.get_lazy(opts, :local_node, fn -> local_node_name(target) end)
      node_start = Keyword.get(opts, :node_start, &Node.start/2)

      case node_start.(local_node, name_mode(target)) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, reason} -> {:error, {:node_start_failed, reason}}
      end
    end
  end

  defp local_node_name(target) do
    host = target |> Atom.to_string() |> node_host()
    String.to_atom("symphony_ctl_#{System.unique_integer([:positive])}@#{host}")
  end

  defp name_mode(target) do
    target
    |> Atom.to_string()
    |> node_host()
    |> then(fn host ->
      if String.contains?(host, "."), do: :longnames, else: :shortnames
    end)
  end

  defp node_host(node_name) do
    case String.split(node_name, "@", parts: 2) do
      [_name, host] -> host
      _ -> "127.0.0.1"
    end
  end

  defp maybe_set_cookie(opts) do
    case Keyword.get(opts, :cookie, System.get_env("SYMPHONY_COOKIE")) do
      cookie when is_binary(cookie) and cookie != "" ->
        set_cookie = Keyword.get(opts, :set_cookie, &Node.set_cookie/1)
        set_cookie.(String.to_atom(cookie))
        :ok

      _ ->
        :ok
    end
  end

  defp connect(target, opts) do
    connect = Keyword.get(opts, :connect, &Node.connect/1)
    connect.(target)
  end

  defp rpc_call(target, module, function, args, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    rpc = Keyword.get(opts, :rpc, &:rpc.call/5)
    rpc.(target, module, function, args, timeout_ms)
  end
end
