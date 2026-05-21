defmodule SymphonyElixir.TestSocketBaseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSocketBase

  test "validates a socket base below the test build root" do
    project_root = test_project_root()

    assert TestSocketBase.validate!("_build/test/sockets", project_root) ==
             Path.join(project_root, "_build/test/sockets")
  end

  test "rejects broad or outside socket bases" do
    project_root = test_project_root()

    assert_raise ArgumentError, ~r/must be inside _build\/test/, fn ->
      TestSocketBase.validate!("/tmp", project_root)
    end

    assert_raise ArgumentError, ~r/must be inside _build\/test/, fn ->
      TestSocketBase.validate!("_build", project_root)
    end

    assert_raise ArgumentError, ~r/must be inside _build\/test/, fn ->
      TestSocketBase.validate!("_build/test", project_root)
    end

    assert_raise ArgumentError, ~r/must be inside _build\/test/, fn ->
      TestSocketBase.validate!("../_build/test/sockets", project_root)
    end
  end

  test "prepare removes stale contents only after validating the socket base" do
    project_root = test_project_root()
    stale_path = Path.join(project_root, "_build/test/sockets/stale")
    File.mkdir_p!(Path.dirname(stale_path))
    File.write!(stale_path, "stale")

    on_exit(fn -> File.rm_rf(project_root) end)

    assert TestSocketBase.prepare!("_build/test/sockets", project_root) ==
             Path.join(project_root, "_build/test/sockets")

    refute File.exists?(stale_path)
    assert File.dir?(Path.join(project_root, "_build/test/sockets"))
  end

  test "rejects blank socket bases" do
    assert_raise ArgumentError, ~r/non-empty path/, fn ->
      TestSocketBase.validate!("")
    end
  end

  defp test_project_root do
    Path.join(System.tmp_dir!(), "symphony-test-socket-base-#{System.unique_integer([:positive])}")
  end
end
