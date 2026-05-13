defmodule SymphonyElixir.HttpServerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias SymphonyElixir.HttpServer

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "symphony-http-server-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
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
end
