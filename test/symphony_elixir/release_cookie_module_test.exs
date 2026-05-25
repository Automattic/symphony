defmodule SymphonyElixir.ReleaseCookieTest.Module do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias SymphonyElixir.Paths
  alias SymphonyElixir.ReleaseCookie

  @app :symphony_elixir

  setup do
    tmp = Path.join(System.tmp_dir!(), "symphony-release-cookie-mod-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Paths.set_state_root(tmp)
    System.delete_env("SYMPHONY_COOKIE")
    System.delete_env("SYMPHONY_STATE_ROOT")

    on_exit(fn ->
      Application.delete_env(@app, :state_root_override)
      System.delete_env("SYMPHONY_COOKIE")
      File.rm_rf(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "generates, persists owner-only, and reuses the cookie" do
    cookie = ReleaseCookie.resolve!()
    path = Paths.erlang_cookie_file()

    assert cookie =~ ~r/^[0-9a-f]{64}$/
    assert File.read!(path) == cookie <> "\n"
    assert band(File.stat!(path).mode, 0o777) == 0o600
    assert ReleaseCookie.resolve!() == cookie
  end

  test "honors SYMPHONY_COOKIE without consulting the state-root file" do
    System.put_env("SYMPHONY_COOKIE", "operator_cookie")

    assert ReleaseCookie.resolve!() == "operator_cookie"
    refute File.exists?(Paths.erlang_cookie_file())
  end

  test "refuses the legacy static cookie from the environment" do
    System.put_env("SYMPHONY_COOKIE", "symphony")

    assert_raise RuntimeError, ~r/insecure Erlang distribution cookie/, fn -> ReleaseCookie.resolve!() end
  end

  test "refuses the legacy static cookie from the file" do
    path = Paths.erlang_cookie_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "symphony\n")
    File.chmod!(path, 0o600)

    assert_raise RuntimeError, ~r/insecure Erlang distribution cookie/, fn -> ReleaseCookie.resolve!() end
  end

  test "refuses an empty persisted cookie" do
    path = Paths.erlang_cookie_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "   \n")
    File.chmod!(path, 0o600)

    assert_raise RuntimeError, ~r/cookie is empty/, fn -> ReleaseCookie.resolve!() end
  end

  test "refuses a group- or world-readable persisted cookie" do
    path = Paths.erlang_cookie_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "safe_cookie\n")
    File.chmod!(path, 0o644)

    assert_raise RuntimeError, ~r/must be readable only by its owner/, fn -> ReleaseCookie.resolve!() end
  end

  test "apply!/0 resolves and returns :ok without raising on a non-distributed node" do
    refute Node.alive?()
    assert :ok = ReleaseCookie.apply!()
    # Resolution still persisted a cookie even though there was no node to set it on.
    assert File.read!(Paths.erlang_cookie_file()) =~ ~r/^[0-9a-f]{64}\n$/
  end

  test "apply!/0 sets the resolved cookie on a distributed node" do
    case :net_kernel.start([:"symphony-cookie-test@127.0.0.1", :longnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    original = :erlang.get_cookie()

    on_exit(fn ->
      :erlang.set_cookie(node(), original)
      :net_kernel.stop()
    end)

    assert Node.alive?()
    assert :ok = ReleaseCookie.apply!()
    assert Atom.to_string(:erlang.get_cookie()) == ReleaseCookie.resolve!()
  end

  test "apply!/0 still fails closed on an insecure cookie" do
    System.put_env("SYMPHONY_COOKIE", "symphony")
    assert_raise RuntimeError, ~r/insecure Erlang distribution cookie/, fn -> ReleaseCookie.apply!() end
  end
end
