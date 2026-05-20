defmodule SymphonyElixir.ControlUrl do
  @moduledoc """
  Persists the daemon's HTTP control plane URL so the local CLI
  (`SymphonyElixir.ControlClient`) can discover where to reach it without
  guessing host/port.
  """

  alias SymphonyElixir.Paths

  @spec persist(String.t()) :: :ok | {:error, term()}
  def persist(url) when is_binary(url) do
    path = Paths.control_url_file()
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         _ <- File.chmod(dir, 0o700),
         :ok <- File.write(path, url <> "\n"),
         _ <- File.chmod(path, 0o600) do
      :ok
    end
  end

  @spec read() :: String.t() | nil
  def read do
    path = Paths.control_url_file()

    with {:ok, contents} <- File.read(path),
         url = String.trim(contents),
         true <- url != "" do
      url
    else
      _ -> nil
    end
  end
end
