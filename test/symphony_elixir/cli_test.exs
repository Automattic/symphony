defmodule SymphonyElixir.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias SymphonyElixir.CLI

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  defp base_deps(overrides \\ %{}) do
    Map.merge(
      %{
        file_regular?: fn _path -> true end,
        init: fn _args -> {:ok, "Wrote symphony.yml"} end,
        set_symphony_file_path: fn _path -> :ok end,
        set_state_root: fn _path -> :ok end,
        set_state_root_from_env: fn -> :ok end,
        set_logs_root: fn _path -> :ok end,
        set_logs_root_from_env: fn -> :ok end,
        set_server_host_override: fn _host -> :ok end,
        set_server_port_override: fn _port -> :ok end,
        ensure_all_started: fn -> {:ok, [:symphony_elixir]} end
      },
      overrides
    )
  end

  test "returns the guardrails acknowledgement banner when the flag is missing" do
    parent = self()

    deps =
      base_deps(%{
        file_regular?: fn _path ->
          send(parent, :file_checked)
          true
        end,
        set_symphony_file_path: fn _path ->
          send(parent, :symphony_set)
          :ok
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert {:error, banner} = CLI.evaluate([], deps)
    assert banner =~ "Symphony is an engineering preview for operator-controlled, trusted environments."
    assert banner =~ "Codex and Claude will run without the usual guardrails."
    assert banner =~ "Agents can access provider runtime config files:"
    assert banner =~ "~/.codex/auth.json"
    assert banner =~ "~/.claude/.credentials.json"
    assert banner =~ "SymphonyElixir is not a supported product and is presented as-is."
    assert banner =~ @ack_flag
    refute_received :file_checked
    refute_received :symphony_set
    refute_received :started
  end

  test "rejects unknown positional arguments" do
    assert {:error, message} = CLI.evaluate([@ack_flag, "WORKFLOW.md"], base_deps())
    assert message =~ "Usage: symphony"
  end

  test "runs init without guardrails acknowledgement or runtime startup" do
    parent = self()

    deps =
      base_deps(%{
        init: fn args ->
          send(parent, {:init, args})
          {:ok, "Wrote /tmp/repo/symphony.yml"}
        end,
        file_regular?: fn _path ->
          send(parent, :file_checked)
          true
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    output =
      capture_io(fn ->
        assert :halt = CLI.evaluate(["init", "--force"], deps)
      end)

    assert output == "Wrote /tmp/repo/symphony.yml\n"
    assert_received {:init, ["--force"]}
    refute_received :file_checked
    refute_received :started
  end

  test "surfaces init errors verbatim without starting the runtime" do
    parent = self()

    deps =
      base_deps(%{
        init: fn _args -> {:error, "symphony.yml already exists"} end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert {:error, "symphony.yml already exists"} = CLI.evaluate(["init"], deps)
    refute_received :started
  end

  test "defaults to ./symphony.yml when --config is omitted" do
    parent = self()
    expected_path = Path.expand("symphony.yml")

    deps =
      base_deps(%{
        file_regular?: fn path ->
          send(parent, {:file_checked, path})
          true
        end,
        set_symphony_file_path: fn path ->
          send(parent, {:symphony_set, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag], deps)
    assert_received {:file_checked, ^expected_path}
    assert_received {:symphony_set, ^expected_path}
  end

  test "uses an explicit symphony config path override when provided" do
    parent = self()
    config_path = "tmp/custom/symphony.claude.yml"
    expanded_config_path = Path.expand(config_path)

    deps =
      base_deps(%{
        file_regular?: fn path ->
          send(parent, {:file_checked, path})
          path == expanded_config_path
        end,
        set_symphony_file_path: fn path ->
          send(parent, {:symphony_set, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--config", config_path], deps)
    assert_received {:file_checked, ^expanded_config_path}
    assert_received {:symphony_set, ^expanded_config_path}
  end

  test "returns not found when the symphony config does not exist" do
    deps = base_deps(%{file_regular?: fn _path -> false end})

    assert {:error, message} = CLI.evaluate([@ack_flag, "--config", "missing.yml"], deps)
    assert message =~ "Symphony config file not found:"
  end

  test "returns not found when the default symphony.yml is missing" do
    deps = base_deps(%{file_regular?: fn _path -> false end})

    assert {:error, message} = CLI.evaluate([@ack_flag], deps)
    assert message =~ "Symphony config file not found:"
    assert message =~ "symphony.yml"
  end

  test "accepts --logs-root and passes an expanded root to runtime deps" do
    parent = self()

    deps =
      base_deps(%{
        set_logs_root: fn path ->
          send(parent, {:logs_root, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--logs-root", "tmp/custom-logs"], deps)
    assert_received {:logs_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-logs")
  end

  test "accepts --state-root and passes an expanded root to runtime deps" do
    parent = self()

    deps =
      base_deps(%{
        set_state_root: fn path ->
          send(parent, {:state_root, path})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--state-root", "tmp/custom-state"], deps)
    assert_received {:state_root, expanded_path}
    assert expanded_path == Path.expand("tmp/custom-state")
  end

  test "configure applies runtime inputs without starting the application" do
    parent = self()

    deps =
      base_deps(%{
        set_state_root: fn path ->
          send(parent, {:state_root, path})
          :ok
        end,
        ensure_all_started: fn ->
          send(parent, :started)
          {:ok, [:symphony_elixir]}
        end
      })

    assert :ok = CLI.configure([@ack_flag, "--state-root", "tmp/configure-state"], deps)
    assert_received {:state_root, expanded_path}
    assert expanded_path == Path.expand("tmp/configure-state")
    refute_received :started
  end

  test "maybe_configure_burrito_runtime is a no-op outside Burrito" do
    assert :ok = CLI.maybe_configure_burrito_runtime()
  end

  test "reads root env overrides before applying flag overrides" do
    parent = self()

    deps =
      base_deps(%{
        set_state_root_from_env: fn ->
          send(parent, :state_root_from_env)
          :ok
        end,
        set_logs_root_from_env: fn ->
          send(parent, :logs_root_from_env)
          :ok
        end,
        set_state_root: fn path ->
          send(parent, {:state_root, path})
          :ok
        end,
        set_logs_root: fn path ->
          send(parent, {:logs_root, path})
          :ok
        end
      })

    assert :ok =
             CLI.evaluate(
               [@ack_flag, "--state-root", "tmp/custom-state", "--logs-root", "tmp/custom-logs"],
               deps
             )

    assert_receive :state_root_from_env
    assert_receive :logs_root_from_env
    assert_receive {:state_root, state_root}
    assert_receive {:logs_root, logs_root}
    assert state_root == Path.expand("tmp/custom-state")
    assert logs_root == Path.expand("tmp/custom-logs")
  end

  test "accepts --host and passes it to runtime deps" do
    parent = self()

    deps =
      base_deps(%{
        set_server_host_override: fn host ->
          send(parent, {:host, host})
          :ok
        end
      })

    assert :ok = CLI.evaluate([@ack_flag, "--host", "0.0.0.0"], deps)
    assert_received {:host, "0.0.0.0"}
  end

  test "returns startup error when app cannot start" do
    deps = base_deps(%{ensure_all_started: fn -> {:error, :boom} end})

    assert {:error, message} = CLI.evaluate([@ack_flag], deps)
    assert message =~ "Failed to start Symphony"
    assert message =~ ":boom"
  end

  test "returns ok when symphony.yml exists and the app starts" do
    assert :ok = CLI.evaluate([@ack_flag], base_deps())
  end
end
