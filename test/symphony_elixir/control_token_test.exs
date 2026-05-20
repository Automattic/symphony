defmodule SymphonyElixir.ControlTokenTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ControlToken, Paths}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "symphony-control-token-test-#{System.unique_integer([:positive])}")

    previous_override = Application.get_env(:symphony_elixir, :state_root_override)
    Paths.set_state_root(tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      case previous_override do
        nil -> Application.delete_env(:symphony_elixir, :state_root_override)
        value -> Application.put_env(:symphony_elixir, :state_root_override, value)
      end
    end)

    {:ok, tmp: tmp}
  end

  test "creates the token file with 0600 perms when missing", %{tmp: tmp} do
    token = ControlToken.current()
    path = Paths.control_token_file()

    assert is_binary(token)
    assert String.length(token) > 0
    assert File.read!(path) |> String.trim() == token
    assert file_mode(path) == "600"
    assert file_mode(tmp) == "700"
  end

  test "reuses an existing persisted token verbatim" do
    path = Paths.control_token_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "preexisting-token-value\n")
    File.chmod!(path, 0o600)

    assert ControlToken.current() == "preexisting-token-value"
  end

  test "regenerates when the persisted file is blank" do
    path = Paths.control_token_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "   \n")
    File.chmod!(path, 0o600)

    token = ControlToken.current()
    refute token == ""
    assert File.read!(path) |> String.trim() == token
  end

  test "returns the same token across calls" do
    first = ControlToken.current()
    second = ControlToken.current()
    assert first == second
  end

  test "read/0 returns nil when no token has been persisted" do
    assert ControlToken.read() == nil
  end

  test "read/0 returns the persisted token without generating one" do
    path = Paths.control_token_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "preexisting\n")
    File.chmod!(path, 0o600)

    assert ControlToken.read() == "preexisting"
  end

  test "read/0 treats blank files as missing" do
    path = Paths.control_token_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "\n")

    assert ControlToken.read() == nil
  end

  defp file_mode(path) do
    case System.cmd("stat", ["-f", "%Lp", path], stderr_to_stdout: true) do
      {mode, 0} -> String.trim(mode)
      _ -> nil
    end
  end
end
