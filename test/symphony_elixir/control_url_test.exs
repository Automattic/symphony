defmodule SymphonyElixir.ControlUrlTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ControlUrl, Paths}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "symphony-control-url-test-#{System.unique_integer([:positive])}")

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

  test "persist/1 writes the URL with 0600 perms" do
    assert :ok = ControlUrl.persist("http://127.0.0.1:4321")
    path = Paths.control_url_file()

    assert File.read!(path) |> String.trim() == "http://127.0.0.1:4321"
    assert file_mode(path) == "600"
  end

  test "persist/1 overwrites an existing file" do
    :ok = ControlUrl.persist("http://127.0.0.1:1")
    :ok = ControlUrl.persist("http://127.0.0.1:2")

    assert ControlUrl.read() == "http://127.0.0.1:2"
  end

  test "read/0 returns nil when the file is missing" do
    assert ControlUrl.read() == nil
  end

  test "read/0 returns nil when the file is blank" do
    path = Paths.control_url_file()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "   \n")

    assert ControlUrl.read() == nil
  end

  test "read/0 returns the trimmed URL when the file is present" do
    :ok = ControlUrl.persist("http://127.0.0.1:7777")
    assert ControlUrl.read() == "http://127.0.0.1:7777"
  end

  defp file_mode(path) do
    case System.cmd("stat", ["-f", "%Lp", path], stderr_to_stdout: true) do
      {mode, 0} -> String.trim(mode)
      _ -> nil
    end
  end
end
