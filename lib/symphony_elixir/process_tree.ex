defmodule SymphonyElixir.ProcessTree do
  @moduledoc """
  Best-effort helpers for cleaning up OS process trees started through Erlang ports.
  """

  @type os_pid :: pos_integer()
  @type command_result :: {String.t(), non_neg_integer()}
  @type deps :: %{
          optional(:port_info) => (port(), atom() -> term()),
          optional(:find_executable) => (String.t() -> String.t() | nil),
          optional(:cmd) => (String.t(), [String.t()], keyword() -> command_result())
        }

  @spec terminate_port_descendants(port(), deps()) :: :ok
  def terminate_port_descendants(port, deps \\ runtime_deps()) when is_port(port) do
    with {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 <-
           safe_port_info(port, :os_pid, deps) do
      terminate_descendants(os_pid, deps)
    end

    :ok
  end

  @spec terminate_descendants(integer(), deps()) :: :ok
  def terminate_descendants(root_pid, deps \\ runtime_deps()) when is_integer(root_pid) do
    root_pid
    |> collect_descendant_pids([], deps)
    |> Enum.uniq()
    |> Enum.each(&kill_pid(&1, deps))

    :ok
  end

  defp runtime_deps do
    %{
      port_info: &Port.info/2,
      find_executable: &System.find_executable/1,
      cmd: &System.cmd/3
    }
  end

  defp safe_port_info(port, key, deps) do
    deps
    |> Map.get(:port_info, &Port.info/2)
    |> then(& &1.(port, key))
  rescue
    _exception -> nil
  end

  defp collect_descendant_pids(pid, acc, deps) when is_integer(pid) and pid > 0 do
    case pgrep_children(pid, deps) do
      [] ->
        acc

      children ->
        Enum.reduce(children, acc, fn child_pid, acc ->
          collect_descendant_pids(child_pid, [child_pid | acc], deps)
        end)
    end
  end

  defp collect_descendant_pids(_pid, acc, _deps), do: acc

  defp pgrep_children(pid, deps) when is_integer(pid) do
    case find_executable("pgrep", deps) do
      nil -> []
      pgrep -> run_pgrep_children(pgrep, pid, deps)
    end
  rescue
    _exception -> []
  end

  defp find_executable(name, deps) do
    deps
    |> Map.get(:find_executable, &System.find_executable/1)
    |> then(& &1.(name))
  end

  defp run_pgrep_children(pgrep, pid, deps) do
    case run_cmd(pgrep, ["-P", to_string(pid)], [stderr_to_stdout: true], deps) do
      {output, status} when status in [0, 1] -> parse_pgrep_output(output)
      _result -> []
    end
  end

  defp parse_pgrep_output(output) do
    output
    |> String.split(["\n", " ", "\t"], trim: true)
    |> Enum.flat_map(&parse_pgrep_pid_token/1)
  end

  defp parse_pgrep_pid_token(token) do
    case Integer.parse(token) do
      {child_pid, ""} when child_pid > 0 -> [child_pid]
      _token -> []
    end
  end

  defp kill_pid(pid, deps) when is_integer(pid) and pid > 0 do
    _result = run_cmd("kill", ["-KILL", to_string(pid)], [stderr_to_stdout: true], deps)
    :ok
  rescue
    _exception -> :ok
  end

  defp run_cmd(command, args, opts, deps) do
    deps
    |> Map.get(:cmd, &System.cmd/3)
    |> then(& &1.(command, args, opts))
  end
end
