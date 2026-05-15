defmodule SymphonyElixir.DependencyAudit.NpmParser do
  @moduledoc false

  alias SymphonyElixir.DependencyAudit

  @dependency_sections ["dependencies", "devDependencies"]

  @spec parse(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def parse(content, opts \\ []) when is_binary(content) do
    path = Keyword.get(opts, :path, "package.json")

    with {:ok, decoded} <- Jason.decode(content),
         true <- is_map(decoded) do
      deps =
        @dependency_sections
        |> Enum.flat_map(&dependencies_from_section(decoded, &1, path))

      {:ok, deps}
    else
      false -> {:error, :package_json_not_object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dependencies_from_section(package_json, section, path) do
    case Map.get(package_json, section) do
      deps when is_map(deps) ->
        Enum.map(deps, fn {package, spec} ->
          %{package: package, path: path, source: source_from_spec(spec)}
        end)

      nil ->
        []

      _other ->
        [%{package: "__#{section}__", path: path, source: %{type: :unknown, raw: section}}]
    end
  end

  defp source_from_spec(spec) when is_binary(spec) do
    cond do
      git_spec?(spec) ->
        git_source(spec)

      String.starts_with?(spec, "file:") ->
        %{type: :path, path: String.replace_prefix(spec, "file:", "")}

      url_spec?(spec) ->
        registry_from_url(spec)

      true ->
        %{type: :registry, registry: "registry.npmjs.org", requirement: spec}
    end
  end

  defp source_from_spec(_spec), do: %{type: :unknown, raw: "non_string_spec"}

  defp git_spec?(spec) do
    String.starts_with?(spec, ["git+", "git://", "git@", "github:"]) or
      String.contains?(spec, "github.com")
  end

  defp url_spec?(spec), do: String.match?(spec, ~r/^https?:\/\//)

  defp git_source(spec) do
    case DependencyAudit.normalize_git_url(spec) do
      nil -> %{type: :unknown, raw: spec}
      parts -> parts |> Map.take([:host, :owner, :repo, :normalized]) |> Map.merge(%{type: :git, url: spec})
    end
  end

  defp registry_from_url(spec) do
    case URI.parse(spec) do
      %URI{host: host} when is_binary(host) and host != "" ->
        %{type: :registry, registry: String.downcase(host), requirement: spec}

      _uri ->
        %{type: :unknown, raw: spec}
    end
  end
end
