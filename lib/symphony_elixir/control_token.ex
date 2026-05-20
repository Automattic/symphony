defmodule SymphonyElixir.ControlToken do
  @moduledoc """
  Bearer token used by `SymphonyElixir.ControlClient` to authenticate against
  the daemon's HTTP control plane (`/api/v1/control/*`).

  Lives next to `secret_key_base` and `erlang_cookie` in the Symphony state
  directory. Generated on first use and persisted with `0600` so subsequent
  daemon restarts and CLI invocations converge on the same value.
  """

  alias SymphonyElixir.Paths

  @token_bytes 32

  @spec current() :: String.t()
  def current do
    path = Paths.control_token_file()

    case read_existing(path) do
      {:ok, token} -> token
      :missing -> create(path)
    end
  end

  @spec read() :: String.t() | nil
  def read do
    case read_existing(Paths.control_token_file()) do
      {:ok, token} -> token
      :missing -> nil
    end
  end

  defp read_existing(path) do
    with {:ok, contents} <- File.read(path),
         token = String.trim(contents),
         true <- token != "" do
      {:ok, token}
    else
      _ -> :missing
    end
  end

  defp create(path) do
    token = generate()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    _ = File.chmod(dir, 0o700)
    File.write!(path, token <> "\n")
    _ = File.chmod(path, 0o600)
    token
  end

  defp generate do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
