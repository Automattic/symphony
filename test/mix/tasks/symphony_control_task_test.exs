defmodule Mix.Tasks.SymphonyControlTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Symphony.Pause
  alias Mix.Tasks.Symphony.Pr
  alias Mix.Tasks.Symphony.Resume
  alias Mix.Tasks.Symphony.Stop

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
end
