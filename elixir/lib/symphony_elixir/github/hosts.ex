defmodule SymphonyElixir.GitHub.Hosts do
  @moduledoc false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema

  @public_hosts ["github.com", "www.github.com"]

  @doc false
  @spec github_host?(term()) :: boolean()
  def github_host?(host), do: github_host?(host, [])

  @spec github_host?(term(), keyword()) :: boolean()
  def github_host?(host, opts) when is_binary(host) and is_list(opts) do
    match?({:ok, _host}, canonical_github_host(host, opts))
  end

  def github_host?(_host, _opts), do: false

  @doc false
  @spec canonical_github_host(term()) :: {:ok, String.t()} | :error
  def canonical_github_host(host), do: canonical_github_host(host, [])

  @spec canonical_github_host(term(), keyword()) :: {:ok, String.t()} | :error
  def canonical_github_host(host, opts) when is_binary(host) and is_list(opts) do
    normalized = normalize_host(host)

    cond do
      normalized in @public_hosts ->
        {:ok, canonical_public_host(normalized)}

      normalized in configured_enterprise_hosts(opts) ->
        {:ok, normalized}

      true ->
        :error
    end
  end

  def canonical_github_host(_host, _opts), do: :error

  @doc false
  @spec allowed_github_hosts() :: [String.t()]
  def allowed_github_hosts, do: allowed_github_hosts([])

  @spec allowed_github_hosts(keyword()) :: [String.t()]
  def allowed_github_hosts(opts) do
    (@public_hosts ++ configured_enterprise_hosts(opts))
    |> Schema.normalize_domain_list()
    |> Enum.uniq()
  end

  defp canonical_public_host("www.github.com"), do: "github.com"
  defp canonical_public_host(host), do: host

  defp configured_enterprise_hosts(opts) do
    opts
    |> operator_configured_ghe_hosts()
    |> Schema.normalize_domain_list()
  end

  defp operator_configured_ghe_hosts(opts) do
    case Keyword.fetch(opts, :github_enterprise_hosts) do
      {:ok, hosts} -> hosts
      :error -> settings_enterprise_hosts()
    end
  end

  defp settings_enterprise_hosts do
    Config.settings!().github.enterprise_hosts
  end

  defp normalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.downcase()
  end
end
