defmodule SymphonyElixir.HttpServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.HttpServer

  @allow_remote_bind_env "SYMPHONY_ALLOW_REMOTE_BIND"

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "symphony-http-server-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    allow_remote_bind = System.get_env(@allow_remote_bind_env)

    on_exit(fn ->
      restore_env(@allow_remote_bind_env, allow_remote_bind)
      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  describe "start_link/1 remote bind guard" do
    test "allows IPv4 loopback binds" do
      start_supervised!({HttpServer, [host: "127.0.0.1", port: 0]})

      assert is_integer(HttpServer.bound_port())
    end

    test "allows IPv6 loopback binds" do
      start_supervised!({HttpServer, [host: "::1", port: 0]})

      assert is_integer(HttpServer.bound_port())
    end

    test "refuses non-loopback binds without an explicit override" do
      System.delete_env(@allow_remote_bind_env)

      assert {:error, message} = HttpServer.start_link(host: "0.0.0.0", port: 0)

      assert message =~ ~s(refusing to bind HTTP server to non-loopback host "0.0.0.0")
      assert message =~ "the dashboard has no built-in auth"
      assert message =~ "SYMPHONY_ALLOW_REMOTE_BIND=1"
      assert HttpServer.bound_port() == nil
    end

    test "allows non-loopback binds with an explicit override" do
      System.put_env(@allow_remote_bind_env, "1")

      start_supervised!({HttpServer, [host: "0.0.0.0", port: 0]})

      assert is_integer(HttpServer.bound_port())
    end
  end

  describe "migrate_legacy_secret_key_base/2" do
    test "moves the legacy file when only the old path exists", %{tmp: tmp} do
      old_path = Path.join([tmp, "legacy", "secret_key_base"])
      new_path = Path.join([tmp, "state", "secret_key_base"])
      File.mkdir_p!(Path.dirname(old_path))
      File.write!(old_path, "legacy-key")

      assert :ok = HttpServer.migrate_legacy_secret_key_base(old_path, new_path)
      assert File.read!(new_path) == "legacy-key"
      refute File.exists?(old_path)
    end

    test "does not overwrite the new file when both files exist", %{tmp: tmp} do
      old_path = Path.join([tmp, "legacy", "secret_key_base"])
      new_path = Path.join([tmp, "state", "secret_key_base"])
      File.mkdir_p!(Path.dirname(old_path))
      File.mkdir_p!(Path.dirname(new_path))
      File.write!(old_path, "legacy-key")
      File.write!(new_path, "current-key")

      assert :ok = HttpServer.migrate_legacy_secret_key_base(old_path, new_path)
      assert File.read!(new_path) == "current-key"
      assert File.read!(old_path) == "legacy-key"
    end

    test "is a no-op when the old file is missing", %{tmp: tmp} do
      old_path = Path.join([tmp, "legacy", "secret_key_base"])
      new_path = Path.join([tmp, "state", "secret_key_base"])

      assert :ok = HttpServer.migrate_legacy_secret_key_base(old_path, new_path)
      refute File.exists?(new_path)
    end

    test "is a no-op when old and new paths are equal", %{tmp: tmp} do
      same_path = Path.join([tmp, "shared", "secret_key_base"])
      File.mkdir_p!(Path.dirname(same_path))
      File.write!(same_path, "stable-key")

      assert :ok = HttpServer.migrate_legacy_secret_key_base(same_path, same_path)
      assert File.read!(same_path) == "stable-key"
    end

    test "logs a warning and returns :ok when mkdir_p fails", %{tmp: tmp} do
      old_path = Path.join([tmp, "legacy", "secret_key_base"])
      File.mkdir_p!(Path.dirname(old_path))
      File.write!(old_path, "legacy-key")

      blocking_file = Path.join(tmp, "blocker")
      File.write!(blocking_file, "x")
      new_path = Path.join([blocking_file, "state", "secret_key_base"])

      log =
        capture_log(fn ->
          assert :ok = HttpServer.migrate_legacy_secret_key_base(old_path, new_path)
        end)

      assert log =~ "failed to migrate secret_key_base"
      assert File.read!(old_path) == "legacy-key"
      refute File.exists?(new_path)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
