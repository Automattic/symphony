defmodule SymphonyElixir.AgentTools.Linear.CommentRegistry do
  @moduledoc false

  use Agent

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> MapSet.new() end, opts)
  end

  @spec record(pid() | nil, String.t()) :: :ok
  def record(pid, comment_id) when is_pid(pid) and is_binary(comment_id) do
    Agent.update(pid, &MapSet.put(&1, comment_id))
  end

  def record(_pid, _comment_id), do: :ok

  @spec owned?(pid() | nil, String.t()) :: boolean()
  def owned?(pid, comment_id) when is_pid(pid) and is_binary(comment_id) do
    Agent.get(pid, &MapSet.member?(&1, comment_id))
  end

  def owned?(_pid, _comment_id), do: false

  @spec remove(pid() | nil, String.t()) :: :ok
  def remove(pid, comment_id) when is_pid(pid) and is_binary(comment_id) do
    Agent.update(pid, &MapSet.delete(&1, comment_id))
  end

  def remove(_pid, _comment_id), do: :ok
end
