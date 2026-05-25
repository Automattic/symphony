defmodule SymphonyElixir.ReleaseCookie do
  @moduledoc """
  Resolves and applies the Erlang distribution cookie at release boot.

  Distribution itself is only used for local remote-console/observer access; the
  control plane is HTTP (see `SymphonyElixir.ControlClient`). The cookie is still
  a shared secret that grants full code execution to any node that connects, so it
  must be unguessable and owner-only.

  The `bin/symphony` script applies this cookie via `rel/env.sh.eex` before the VM
  boots. The Burrito-packaged binary boots the BEAM directly and never sources
  `env.sh`, so for that launch path the same resolution runs here, in `runtime.exs`,
  via `:erlang.set_cookie/2`. Both paths converge on the same persisted value, so a
  daemon started either way accepts a `bin/symphony remote` shell.

  Resolution mirrors `rel/env.sh.eex`:

    * `SYMPHONY_COOKIE`, when set, is used verbatim and the state-root file is left
      untouched.
    * otherwise the cookie is read from `Paths.erlang_cookie_file/0`, requiring
      owner-only permissions, or generated and persisted with `0600` on first boot.

  The legacy static cookie `"symphony"` is rejected.
  """

  import Bitwise, only: [band: 2]

  alias SymphonyElixir.Paths

  @cookie_bytes 32
  @insecure_cookie "symphony"

  @doc """
  Resolves the cookie and applies it to the local node via `:erlang.set_cookie/2`.

  Raises if the cookie is missing, insecure, or the persisted file is not
  owner-only — failing closed, exactly as `rel/env.sh.eex` does.
  """
  @spec apply!() :: :ok
  def apply! do
    cookie = resolve!()
    # Only a distributed node has a cookie to protect; setting one on
    # nonode@nohost raises. Resolving still runs so a bad/insecure cookie fails
    # the boot regardless of distribution state.
    if Node.alive?(), do: :erlang.set_cookie(node(), String.to_atom(cookie))
    :ok
  end

  @doc """
  Returns the resolved cookie without touching the running node.
  """
  @spec resolve!() :: String.t()
  def resolve! do
    case System.get_env("SYMPHONY_COOKIE") do
      nil -> from_state_root()
      "" -> from_state_root()
      cookie -> validate!(cookie)
    end
  end

  defp from_state_root do
    path = Paths.erlang_cookie_file()

    case File.stat(path) do
      {:ok, stat} -> read_existing!(path, stat)
      {:error, :enoent} -> create!(path)
      {:error, reason} -> raise "could not read Erlang cookie #{path}: #{inspect(reason)}"
    end
  end

  defp read_existing!(path, %File.Stat{mode: mode}) do
    if band(mode, 0o077) != 0 do
      raise "#{path} must be readable only by its owner; got mode #{Integer.to_string(band(mode, 0o777), 8)}."
    end

    path
    |> File.read!()
    |> String.trim()
    |> validate!()
  end

  defp create!(path) do
    cookie = validate!(generate())
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    _ = File.chmod(dir, 0o700)
    File.write!(path, cookie <> "\n")
    _ = File.chmod(path, 0o600)
    cookie
  end

  defp validate!(cookie) do
    cond do
      cookie in [nil, ""] -> raise "Erlang distribution cookie is empty."
      cookie == @insecure_cookie -> raise ~s(Refusing to use insecure Erlang distribution cookie "#{@insecure_cookie}".)
      true -> cookie
    end
  end

  defp generate do
    @cookie_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end
end
