defmodule SymphonyElixir.ProcessTreeTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProcessTree

  test "terminates all descendants without killing the root pid" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    deps =
      fake_deps(
        %{
          100 => [101, 102],
          101 => [103],
          102 => [],
          103 => []
        },
        calls
      )

    assert :ok = ProcessTree.terminate_descendants(100, deps)

    assert calls |> Agent.get(& &1) |> Enum.sort() == [
             {:kill, 101},
             {:kill, 102},
             {:kill, 103}
           ]
  end

  test "deduplicates descendants discovered through multiple parents" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    deps =
      fake_deps(
        %{
          100 => [101, 102],
          101 => [103],
          102 => [103],
          103 => []
        },
        calls
      )

    assert :ok = ProcessTree.terminate_descendants(100, deps)

    killed_pids =
      calls
      |> Agent.get(& &1)
      |> Enum.map(fn {:kill, pid} -> pid end)
      |> Enum.sort()

    assert killed_pids == [101, 102, 103]
  end

  test "does nothing when pgrep is unavailable" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    deps =
      fake_deps(%{100 => [101]}, calls)
      |> Map.put(:find_executable, fn "pgrep" -> nil end)

    assert :ok = ProcessTree.terminate_descendants(100, deps)
    assert Agent.get(calls, & &1) == []
  end

  test "does nothing for invalid root pids" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    assert :ok = ProcessTree.terminate_descendants(0, fake_deps(%{0 => [101]}, calls))
    assert Agent.get(calls, & &1) == []
  end

  test "ignores unexpected pgrep statuses" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    deps =
      fake_deps(%{}, calls)
      |> Map.put(:cmd, fn
        "/usr/bin/pgrep", ["-P", "100"], _opts -> {"101\n", 2}
        "kill", ["-KILL", pid], _opts -> record_kill(calls, pid)
      end)

    assert :ok = ProcessTree.terminate_descendants(100, deps)
    assert Agent.get(calls, & &1) == []
  end

  test "ignores malformed pgrep output tokens" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    deps =
      fake_deps(%{}, calls)
      |> Map.put(:cmd, fn
        "/usr/bin/pgrep", ["-P", "100"], _opts -> {"101 nope -2 102abc 102\n", 0}
        "/usr/bin/pgrep", ["-P", "101"], _opts -> {"", 1}
        "/usr/bin/pgrep", ["-P", "102"], _opts -> {"", 1}
        "kill", ["-KILL", pid], _opts -> record_kill(calls, pid)
      end)

    assert :ok = ProcessTree.terminate_descendants(100, deps)

    assert calls |> Agent.get(& &1) |> Enum.sort() == [
             {:kill, 101},
             {:kill, 102}
           ]
  end

  test "swallows pgrep and kill failures" do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    pgrep_failure_deps =
      fake_deps(%{100 => [101]}, calls)
      |> Map.put(:cmd, fn
        "/usr/bin/pgrep", ["-P", "100"], _opts -> raise "pgrep unavailable"
        "kill", ["-KILL", pid], _opts -> record_kill(calls, pid)
      end)

    assert :ok = ProcessTree.terminate_descendants(100, pgrep_failure_deps)
    assert Agent.get(calls, & &1) == []

    kill_failure_deps =
      fake_deps(%{100 => [101], 101 => []}, calls)
      |> Map.put(:cmd, fn
        "/usr/bin/pgrep", ["-P", "100"], _opts -> {"101\n", 0}
        "/usr/bin/pgrep", ["-P", "101"], _opts -> {"", 1}
        "kill", ["-KILL", "101"], _opts -> raise "kill denied"
      end)

    assert :ok = ProcessTree.terminate_descendants(100, kill_failure_deps)
    assert Agent.get(calls, & &1) == []
  end

  test "reads a port os pid through injectable port info" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    port = Port.open({:spawn, "cat"}, [:binary])

    deps =
      fake_deps(%{100 => [101], 101 => []}, calls)
      |> Map.put(:port_info, fn ^port, :os_pid -> {:os_pid, 100} end)

    try do
      assert :ok = ProcessTree.terminate_port_descendants(port, deps)
      assert Agent.get(calls, & &1) == [{:kill, 101}]
    after
      close_port(port)
    end
  end

  test "ignores ports whose os pid cannot be read" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    port = Port.open({:spawn, "cat"}, [:binary])

    deps =
      fake_deps(%{100 => [101]}, calls)
      |> Map.put(:port_info, fn ^port, :os_pid -> raise "port info unavailable" end)

    try do
      assert :ok = ProcessTree.terminate_port_descendants(port, deps)
      assert Agent.get(calls, & &1) == []
    after
      close_port(port)
    end
  end

  defp fake_deps(children_by_pid, calls) do
    %{
      find_executable: fn "pgrep" -> "/usr/bin/pgrep" end,
      cmd: fn
        "/usr/bin/pgrep", ["-P", pid], _opts ->
          children =
            children_by_pid
            |> Map.get(String.to_integer(pid), [])
            |> Enum.join("\n")

          status = if children == "", do: 1, else: 0
          {children, status}

        "kill", ["-KILL", pid], _opts ->
          record_kill(calls, pid)
      end
    }
  end

  defp record_kill(calls, pid) do
    Agent.update(calls, &[{:kill, String.to_integer(pid)} | &1])
    {"", 0}
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
