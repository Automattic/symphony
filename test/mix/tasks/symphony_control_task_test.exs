defmodule Mix.Tasks.SymphonyControlTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Pause
  alias Mix.Tasks.Symphony.Pr
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

    @spec dispatch_pr(String.t(), keyword()) :: {:ok, map()}
    def dispatch_pr(target, opts) do
      send(Application.fetch_env!(:symphony_elixir, :control_task_test_recipient), {:dispatch_pr, target, opts})
      Application.fetch_env!(:symphony_elixir, :control_task_test_result)
    end
  end

  setup do
    Mix.Task.reenable("symphony.pause")
    Mix.Task.reenable("symphony.pr")
    Mix.Task.reenable("symphony.resume")
    Mix.Task.reenable("symphony.stop")

    previous_cookie_env = System.get_env("SYMPHONY_COOKIE")
    previous_state_root = Application.get_env(:symphony_elixir, :state_root_override)

    System.delete_env("SYMPHONY_COOKIE")
    Application.put_env(:symphony_elixir, :control_client, FakeControlClient)
    Application.put_env(:symphony_elixir, :control_task_test_recipient, self())

    on_exit(fn ->
      restore_env("SYMPHONY_COOKIE", previous_cookie_env)
      restore_app_env(:state_root_override, previous_state_root)
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

  test "pause task reports when an already-paused reason is preserved" do
    Application.put_env(:symphony_elixir, :control_task_test_result, {:ok, %{paused: true, reason: "deploy"}})

    output =
      capture_io(fn ->
        assert :ok = Pause.run(["incident"])
      end)

    assert output =~ "Dispatch already paused: deploy; requested reason ignored"
    assert_receive {:pause, "incident"}
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

  test "pr task sends target and intent through the control client" do
    Application.put_env(
      :symphony_elixir,
      :control_task_test_result,
      {:ok, %{pull_request_url: "https://github.com/example/repo/pull/123"}}
    )

    output =
      capture_io(fn ->
        assert :ok = Pr.run(["123", "--intent", "address review comments"])
      end)

    assert output =~ "Dispatched PR run: https://github.com/example/repo/pull/123"
    assert_receive {:dispatch_pr, "123", [intent: "address review comments"]}
  end

  test "pr task omits blank intent and falls back to target in output" do
    Application.put_env(:symphony_elixir, :control_task_test_result, {:ok, %{}})

    output =
      capture_io(fn ->
        assert :ok = Pr.run(["123", "--intent", " "])
      end)

    assert output =~ "Dispatched PR run: 123"
    assert_receive {:dispatch_pr, "123", []}
  end

  test "pr task reports usage errors" do
    assert_raise Mix.Error, ~r/Usage: mix symphony\.pr/, fn ->
      Pr.run([])
    end
  end

  test "pr task reports unavailable orchestrator" do
    Application.put_env(:symphony_elixir, :control_task_test_result, :unavailable)

    assert_raise Mix.Error, "Orchestrator unavailable", fn ->
      Pr.run(["123"])
    end
  end

  test "pr task reports dispatch failures" do
    Application.put_env(:symphony_elixir, :control_task_test_result, {:error, :boom})

    assert_raise Mix.Error, "PR dispatch failed: :boom", fn ->
      Pr.run(["123"])
    end
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

  test "control client can dispatch PR runs over rpc" do
    target = :"symphony@127.0.0.1"

    result =
      ControlClient.dispatch_pr("123", [intent: "fix CI"],
        prefer_local?: false,
        target_node: target,
        node_alive?: fn -> false end,
        node_start: fn _local_node, :longnames -> {:ok, self()} end,
        connect: fn ^target -> true end,
        rpc: fn ^target, SymphonyElixir.Orchestrator, :dispatch_pr, ["123", [intent: "fix CI"]], 15_000 ->
          {:ok, %{pull_request_url: "https://github.com/example/repo/pull/123"}}
        end
      )

    assert {:ok, %{pull_request_url: "https://github.com/example/repo/pull/123"}} = result
  end

  test "control client uses SYMPHONY_COOKIE when present" do
    target = :"symphony@127.0.0.1"
    parent = self()
    System.put_env("SYMPHONY_COOKIE", "operator_cookie")

    result =
      ControlClient.pause_dispatch("overnight",
        prefer_local?: false,
        target_node: target,
        node_alive?: fn -> false end,
        node_start: fn _local_node, :longnames -> {:ok, self()} end,
        set_cookie: fn cookie ->
          send(parent, {:cookie, cookie})
          true
        end,
        connect: fn ^target -> true end,
        rpc: fn ^target, SymphonyElixir.Orchestrator, :pause_dispatch, ["overnight"], 15_000 ->
          {:ok, %{paused: true, reason: "overnight"}}
        end
      )

    assert {:ok, %{paused: true, reason: "overnight"}} = result
    assert_receive {:cookie, :operator_cookie}
  end

  test "control client falls back to persisted release cookie" do
    target = :"symphony@127.0.0.1"
    parent = self()
    tmp = Path.join(System.tmp_dir!(), "symphony-control-cookie-test-#{System.unique_integer([:positive])}")
    cookie_path = Path.join(tmp, "erlang_cookie")

    File.mkdir_p!(tmp)
    File.write!(cookie_path, "persisted_cookie\n")
    SymphonyElixir.Paths.set_state_root(tmp)

    on_exit(fn -> File.rm_rf(tmp) end)

    result =
      ControlClient.pause_dispatch("overnight",
        prefer_local?: false,
        target_node: target,
        node_alive?: fn -> false end,
        node_start: fn _local_node, :longnames -> {:ok, self()} end,
        set_cookie: fn cookie ->
          send(parent, {:cookie, cookie})
          true
        end,
        connect: fn ^target -> true end,
        rpc: fn ^target, SymphonyElixir.Orchestrator, :pause_dispatch, ["overnight"], 15_000 ->
          {:ok, %{paused: true, reason: "overnight"}}
        end
      )

    assert {:ok, %{paused: true, reason: "overnight"}} = result
    assert_receive {:cookie, :persisted_cookie}
  end

  test "control client does not set a cookie when neither env nor persisted cookie exists" do
    target = :"symphony@127.0.0.1"
    parent = self()
    tmp = Path.join(System.tmp_dir!(), "symphony-control-cookie-test-#{System.unique_integer([:positive])}")

    SymphonyElixir.Paths.set_state_root(tmp)

    on_exit(fn -> File.rm_rf(tmp) end)

    result =
      ControlClient.pause_dispatch("overnight",
        prefer_local?: false,
        target_node: target,
        node_alive?: fn -> false end,
        node_start: fn _local_node, :longnames -> {:ok, self()} end,
        set_cookie: fn cookie ->
          send(parent, {:cookie, cookie})
          true
        end,
        connect: fn ^target -> true end,
        rpc: fn ^target, SymphonyElixir.Orchestrator, :pause_dispatch, ["overnight"], 15_000 ->
          {:ok, %{paused: true, reason: "overnight"}}
        end
      )

    assert {:ok, %{paused: true, reason: "overnight"}} = result
    refute_received {:cookie, _cookie}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_app_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
