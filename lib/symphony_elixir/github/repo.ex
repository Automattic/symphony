defmodule SymphonyElixir.GitHub.Repo do
  @moduledoc false

  @spec from_url(String.t() | nil) :: String.t() | nil
  def from_url(url) when is_binary(url) do
    with {:ok, "github.com", path} <- split_url(String.trim(url)),
         [owner, repo] <- String.split(path, "/", trim: true) do
      repo =
        repo
        |> String.trim_trailing("/")
        |> String.replace_suffix(".git", "")

      "#{owner}/#{repo}"
    else
      _ -> nil
    end
  end

  def from_url(_url), do: nil

  @spec same?(String.t() | nil, String.t() | nil) :: boolean()
  def same?(left, right) when is_binary(left) and is_binary(right) do
    normalize(left) == normalize(right)
  end

  def same?(_left, _right), do: false

  defp normalize(repo) do
    repo
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> String.downcase()
  end

  defp split_url("git@" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [host, path] -> {:ok, String.downcase(host), path}
      _ -> :error
    end
  end

  defp split_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, path: "/" <> path}
      when scheme in ["http", "https", "ssh"] and is_binary(host) and is_binary(path) ->
        {:ok, String.downcase(host), path}

      _ ->
        :error
    end
  end
end
