defmodule SymphonyElixir.GitHub.Repo do
  @moduledoc false

  alias SymphonyElixir.GitHub.Hosts

  @spec from_url(String.t() | nil) :: String.t() | nil
  def from_url(url), do: from_url(url, [])

  @spec from_url(String.t() | nil, keyword()) :: String.t() | nil
  def from_url(url, opts) when is_binary(url) and is_list(opts) do
    case repo_parts_from_url(url, opts) do
      {_host, owner, repo} -> "#{owner}/#{repo}"
      nil -> nil
    end
  end

  def from_url(_url, _opts), do: nil

  @spec gh_repo_from_url(String.t() | nil) :: String.t() | nil
  def gh_repo_from_url(url), do: gh_repo_from_url(url, [])

  @spec gh_repo_from_url(String.t() | nil, keyword()) :: String.t() | nil
  def gh_repo_from_url(url, opts) when is_binary(url) and is_list(opts) do
    case repo_parts_from_url(url, opts) do
      {"github.com", owner, repo} -> "#{owner}/#{repo}"
      {host, owner, repo} -> "#{host}/#{owner}/#{repo}"
      nil -> nil
    end
  end

  def gh_repo_from_url(_url, _opts), do: nil

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

  defp repo_parts_from_url(url, opts) do
    with {:ok, host, path} <- split_url(String.trim(url)),
         {:ok, canonical_host} <- canonical_github_host(host, opts),
         [owner, repo] <- String.split(path, "/", trim: true) do
      repo =
        repo
        |> String.trim_trailing("/")
        |> String.replace_suffix(".git", "")

      {canonical_host, owner, repo}
    else
      _ -> nil
    end
  end

  defp canonical_github_host(host, opts) do
    Hosts.canonical_github_host(host, opts)
  rescue
    ArgumentError -> :error
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
