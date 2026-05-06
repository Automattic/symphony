defmodule Mix.Tasks.SymphonyControlTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Pause
  alias Mix.Tasks.Symphony.Resume
  alias Mix.Tasks.Symphony.Stop
  alias SymphonyElixir.ControlClient

  defmodule FakeControlClient do
    @spec pause_dispatch(String.t()) :: {:ok, map()}
    def pause_dispatch(reason) do
      send(Application.fetch_env!(:symphony_elixir, :control_task_test_recipient), {:pause, reason})
      Application.fetch_env!(:symphony_elixir, :control_task_test_result)
    end

    @spec resume_dispatch() :: {:ok, map()}
    def resume_dispatch do
      send(Application.fetch_env!(:symphony_elixir, :control_task_test_recipient), :resume)
      Application.fetch_env!(:symphony_elixir, :control_task_test_result)
    end

    @spec stop_running(String.t()) :: {:ok, map()}
    def stop_running(issue_id_or_identifier) do
      send(Application.fetch_env!(:symphony_elixir, :control_task_test_recipient), {:stop, issue_id_or_identifier})
      Application.fetch_env!(:symphony_elixir, :control_task_test_result)
    end
  end

  setup do
    Mix.Task.reenable("symphony.pause")
    Mix.Task.reenable("symphony.resume")
    Mix.Task.reenable("symphony.stop")

    Application.put_env(:symphony_elixir, :control_client, FakeControlClient)
    Application.put_env(:symphony_elixir, :control_task_test_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :control_client)
      Application.delete_env(:symphony_elixir, :control_task_test_recipient)
      Application.delete_env(:symphony_elixir, :control_task_test_result)
    end)

    :ok
  end

  test "pause task sends the reason through the control client" do
    Application.put_env(:symphony_elixir, :control_task_test_result, {:ok, %{paused: true, reason: "deploy"}})

    output =
      capture_io(fn ->
        assert :ok = Pause.run(["deploy"])
      end)

    assert output =~ "Dispatch paused: deploy"
    assert_receive {:pause, "deploy"}
  end

  test "resume task clears the pause through the control client" do
    Application.put_env(:symphony_elixir, :control_task_test_result, {:ok, %{paused: false}})

    output =
      capture_io(fn ->
        assert :ok = Resume.run([])
      end)

    assert output =~ "Dispatch resumed"
    assert_receive :resume
  end

  test "stop task sends the issue identifier through the control client" do
    Application.put_env(
      :symphony_elixir,
      :control_task_test_result,
      {:ok, %{stopped: true, issue_id: "issue-1", issue_identifier: "RSM-1"}}
    )

    output =
      capture_io(fn ->
        assert :ok = Stop.run(["RSM-1"])
      end)

    assert output =~ "Stopped running issue: RSM-1"
    assert_receive {:stop, "RSM-1"}
  end

  test "control client calls a running node over rpc when no local orchestrator is present" do
    target = :"symphony@127.0.0.1"
    parent = self()

    result =
      ControlClient.pause_dispatch("overnight",
        prefer_local?: false,
        target_node: target,
        node_alive?: fn -> false end,
        node_start: fn local_node, :longnames ->
          send(parent, {:node_start, local_node})
          {:ok, self()}
        end,
        connect: fn ^target ->
          send(parent, {:connect, target})
          true
        end,
        rpc: fn ^target, SymphonyElixir.Orchestrator, :pause_dispatch, ["overnight"], 15_000 ->
          send(parent, :rpc_called)
          {:ok, %{paused: true, reason: "overnight"}}
        end
      )

    assert {:ok, %{paused: true, reason: "overnight"}} = result
    assert_receive {:node_start, local_node}
    assert local_node |> Atom.to_string() |> String.starts_with?("symphony_ctl_")
    assert_receive {:connect, ^target}
    assert_receive :rpc_called
  end
end
