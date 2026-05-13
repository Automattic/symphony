defmodule SymphonyElixir.DependencyAudit do
  @moduledoc """
  Audits direct dependency manifest changes for newly introduced risky sources.
  """

  # Dialyzer collapses the Regex-backed wildcard predicates to a no_match false positive;
  # the hold branches are covered by dependency_audit_test.
  @dialyzer :no_match

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.DependencyAudit.{MixParser, NpmParser}
  alias SymphonyElixir.PathSafety

  @default_base_ref "origin/main"

  @trusted_git_patterns [
    "github.com/elixir-lang/*",
    "github.com/erlang/*",
    "github.com/erlef/*",
    "github.com/phoenixframework/*",
    "github.com/elixir-ecto/*",
    "github.com/elixir-plug/*",
    "github.com/nodejs/*",
    "github.com/rust-lang/*",
    "github.com/python/*",
    "github.com/pypa/*",
    "github.com/ruby/*",
    "github.com/rubygems/*",
    "github.com/golang/*"
  ]

  @type audit_item :: %{
          path: String.t(),
          package: String.t(),
          from: String.t() | nil,
          to: String.t(),
          reason: String.t()
        }

  @spec audit(Path.t(), keyword()) :: {:ok, []} | {:hold, [audit_item()]} | {:error, term()}
  def audit(workspace, opts \\ []) do
    settings = Keyword.get(opts, :settings) || Config.settings!()
    base_ref = Keyword.get(opts, :base_ref) || configured_base_ref(Keyword.get(opts, :repo_key))
    command_runner = Keyword.get(opts, :command_runner, &run_git/3)
    workspace = Path.expand(workspace)

    case resolve_base_ref(workspace, base_ref, command_runner) do
      {:ok, base_ref} ->
        audit_with_base_ref(workspace, base_ref, settings, command_runner, opts)

      :no_repo ->
        {:ok, []}

      {:hold, items} ->
        {:hold, items}
    end
  end

  defp audit_with_base_ref(workspace, base_ref, settings, command_runner, opts) do
    with {:ok, manifest_paths} <- changed_manifest_paths(workspace, base_ref, command_runner) do
      opts = opts |> Keyword.put(:workspace, workspace) |> Keyword.put(:command_runner, command_runner)

      holds =
        manifest_paths
        |> Enum.flat_map(&audit_manifest(workspace, &1, base_ref, settings, command_runner, opts))

      case holds do
        [] -> {:ok, []}
        items -> {:hold, items}
      end
    end
  end

  @spec approval_metadata([audit_item()]) :: map()
  def approval_metadata(items) do
    %{dependency_changes: items}
  end

  @doc false
  @spec git_pr_create_command?(term()) :: boolean()
  def git_pr_create_command?(command) when is_binary(command) do
    command
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.match?(~r/(^|\s)(gh|ghe)\s+pr\s+create(\s|$)/)
  end

  def git_pr_create_command?(_command), do: false

  defp audit_manifest(workspace, path, base_ref, settings, command_runner, opts) do
    language = language_for_path(path)
    current_path = Path.join(workspace, path)

    case File.read(current_path) do
      {:ok, current_content} ->
        base_content = base_manifest(workspace, base_ref, path, command_runner)
        audit_manifest_content(workspace, path, language, base_content, current_content, settings, opts)

      {:error, _reason} ->
        []
    end
  end

  defp audit_manifest_content(workspace, path, language, base_content, current_content, settings, opts) do
    parser = parser_for_language(language)

    case parser.parse(current_content, path: path) do
      {:ok, current_deps} ->
        case parse_base(parser, base_content, path) do
          {:ok, base_deps} ->
            current_deps
            |> dependency_deltas(base_deps)
            |> Enum.flat_map(&classify_delta(workspace, path, language, &1, settings, opts))

          {:error, reason} ->
            [manifest_hold(path, "base_manifest", base_content, current_content, "base_parser_unrecognized: #{inspect(reason)}")]
        end

      {:error, reason} ->
        [manifest_hold(path, "manifest", base_content, current_content, "parser_unrecognized: #{inspect(reason)}")]
    end
  end

  defp parse_base(_parser, nil, _path), do: {:ok, []}

  defp parse_base(parser, content, path) do
    parser.parse(content, path: path)
  end

  defp dependency_deltas(current_deps, base_deps) do
    base_by_package = Map.new(base_deps, &{&1.package, &1})

    Enum.flat_map(current_deps, &dependency_delta(&1, Map.get(base_by_package, &1.package)))
  end

  defp dependency_delta(current, nil), do: [%{kind: :added, from: nil, to: current}]

  defp dependency_delta(current, base) do
    if source_identity(base.source) == source_identity(current.source) do
      []
    else
      [%{kind: :source_changed, from: base, to: current}]
    end
  end

  defp classify_delta(workspace, path, language, %{from: from, to: %{source: source} = to}, settings, opts) do
    reason = disallowed_reason(workspace, path, language, source, settings, opts)

    case reason do
      nil ->
        []

      reason ->
        [
          %{
            path: path,
            package: to.package,
            from: dep_source_text(from),
            to: source_text(source),
            reason: reason
          }
        ]
    end
  end

  @spec disallowed_reason(Path.t(), String.t(), atom(), map(), term(), keyword()) :: String.t() | nil
  defp disallowed_reason(_workspace, _path, language, %{type: :registry, registry: registry}, settings, _opts) do
    cond do
      registry == official_registry(language) ->
        nil

      allowed_registry?(settings, registry) ->
        nil

      true ->
        "untrusted_registry"
    end
  end

  defp disallowed_reason(_workspace, _path, _language, %{type: :git, normalized: normalized}, settings, opts) do
    cond do
      allowed_git_source?(settings, normalized) ->
        nil

      allowed_same_owner_source?(normalized, opts) ->
        nil

      allowed_default_git_source?(normalized) ->
        nil

      true ->
        "untrusted_git_source"
    end
  end

  defp disallowed_reason(workspace, manifest_path, _language, %{type: :path, path: dep_path}, settings, _opts) do
    manifest_dir = Path.dirname(Path.join(workspace, manifest_path))
    expanded = Path.expand(dep_path, manifest_dir)

    cond do
      inside_workspace?(expanded, workspace) ->
        nil

      allowed_path_source?(settings, dep_path, expanded, workspace) ->
        nil

      true ->
        "outside_workspace_path"
    end
  end

  defp disallowed_reason(_workspace, _path, _language, %{type: _type}, _settings, _opts), do: "unrecognized_dependency_source"

  defp changed_manifest_paths(workspace, base_ref, command_runner) do
    with {:ok, diff_paths} <- git_lines(command_runner, workspace, ["diff", "--name-only", base_ref, "--"]),
         {:ok, untracked_paths} <- git_lines(command_runner, workspace, ["ls-files", "--others", "--exclude-standard"]) do
      paths =
        (diff_paths ++ untracked_paths)
        |> Enum.uniq()
        |> Enum.filter(&manifest_path?/1)
        |> Enum.reject(&ignored_manifest_path?/1)
        |> Enum.sort()

      {:ok, paths}
    end
  end

  defp resolve_base_ref(workspace, base_ref, command_runner) do
    case command_runner.("git", ["rev-parse", "--verify", "#{base_ref}^{commit}"], cd: workspace) do
      {_output, 0} ->
        {:ok, base_ref}

      {output, _status} when is_binary(output) ->
        if String.contains?(String.downcase(output), "not a git repository") do
          :no_repo
        else
          {:hold, [base_ref_unavailable_hold(base_ref, output)]}
        end

      {output, _status} ->
        {:hold, [base_ref_unavailable_hold(base_ref, inspect(output))]}
    end
  end

  defp base_ref_unavailable_hold(base_ref, output) do
    detail =
      output
      |> to_string()
      |> String.trim()
      |> String.slice(0, 200)

    %{
      path: "<workspace>",
      package: "base_ref",
      from: nil,
      to: base_ref,
      reason: "base_ref_unavailable: #{detail}"
    }
  end

  defp git_lines(command_runner, workspace, args) do
    case command_runner.("git", args, cd: workspace) do
      {output, 0} ->
        {:ok, output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

      {output, _status} when is_binary(output) ->
        case :binary.match(String.downcase(output), "not a git repository") do
          :nomatch -> {:error, {:git_failed, args, output}}
          {_position, _length} -> {:ok, []}
        end

      {output, status} ->
        {:error, {:git_failed, args, status, output}}
    end
  end

  defp base_manifest(workspace, base_ref, path, command_runner) do
    case command_runner.("git", ["show", "#{base_ref}:#{path}"], cd: workspace) do
      {content, 0} -> content
      {_output, _status} -> nil
    end
  end

  defp run_git(command, args, opts), do: System.cmd(command, args, opts ++ [stderr_to_stdout: true])

  defp manifest_path?(path), do: Path.basename(path) in ["mix.exs", "package.json"]

  defp ignored_manifest_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in ["deps", "_build", "node_modules"]))
  end

  defp language_for_path(path) do
    case Path.basename(path) do
      "mix.exs" -> :elixir
      "package.json" -> :javascript
    end
  end

  defp parser_for_language(:elixir), do: MixParser
  defp parser_for_language(:javascript), do: NpmParser

  defp official_registry(:elixir), do: "hex.pm"
  defp official_registry(:javascript), do: "registry.npmjs.org"

  defp allowed_registry?(settings, registry) do
    registry in allow_list(settings, :allow_registries)
  end

  defp allowed_git_source?(settings, normalized) do
    Enum.any?(allow_list(settings, :allow_git_sources), &wildcard_match?(&1, normalized))
  end

  defp allowed_path_source?(settings, dep_path, expanded, workspace) do
    Enum.any?(allow_list(settings, :allow_path_sources), fn allowed ->
      allowed_expanded = Path.expand(allowed, workspace)

      [{allowed, dep_path}, {allowed_expanded, expanded}]
      |> Enum.any?(fn {pattern, value} -> wildcard_match?(pattern, value) end)
    end)
  end

  defp allow_list(%Schema{} = settings, field) do
    settings.dependencies
    |> Map.get(field, [])
    |> normalize_allow_list()
  end

  defp allow_list(_settings, _field), do: []

  defp normalize_allow_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_allow_list(_values), do: []

  defp allowed_same_owner_source?(normalized, opts) do
    case Keyword.get(opts, :origin_url) || origin_url(opts) do
      nil ->
        false

      origin ->
        case normalize_git_url(origin) do
          %{host: "github.com", owner: owner} ->
            wildcard_match?("github.com/#{owner}/*", normalized)

          _ ->
            false
        end
    end
  end

  defp origin_url(opts) do
    workspace = Keyword.get(opts, :workspace)
    command_runner = Keyword.get(opts, :command_runner)

    case command_runner.("git", ["remote", "get-url", "origin"], cd: workspace) do
      {url, 0} -> String.trim(url)
      _ -> nil
    end
  end

  defp allowed_default_git_source?(normalized) do
    Enum.any?(@trusted_git_patterns, &wildcard_match?(&1, normalized))
  end

  defp wildcard_match?(pattern, value) do
    regex =
      pattern
      |> String.trim()
      |> Regex.escape()
      |> String.replace("\\*", "[^/]+")

    Regex.match?(~r/^#{regex}$/, value)
  end

  defp inside_workspace?(path, workspace) do
    with {:ok, canonical_path} <- PathSafety.canonicalize(path),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace) do
      canonical_path == canonical_workspace or
        String.starts_with?(canonical_path, canonical_workspace <> "/")
    else
      _ -> false
    end
  end

  @spec source_identity(map()) :: term()
  defp source_identity(%{type: :registry, registry: registry}), do: {:registry, registry}
  defp source_identity(%{type: :git, normalized: normalized}), do: {:git, normalized}
  defp source_identity(%{type: :path, path: path}), do: {:path, Path.expand(path)}
  defp source_identity(%{type: type}), do: {type}

  defp dep_source_text(nil), do: nil
  defp dep_source_text(%{source: source}), do: source_text(source)

  defp source_text(%{type: :registry, registry: registry}), do: "registry:#{registry}"
  defp source_text(%{type: :git, normalized: normalized}), do: "git:#{normalized}"
  defp source_text(%{type: :path, path: path}), do: "path:#{path}"
  defp source_text(%{type: type}), do: to_string(type)

  defp manifest_hold(path, package, from, to, reason) do
    %{
      path: path,
      package: package,
      from: if(is_binary(from), do: "manifest", else: nil),
      to: if(is_binary(to), do: "manifest", else: nil),
      reason: reason
    }
  end

  defp configured_base_ref(repo_key) do
    case Config.repo_base_branch(repo_key) do
      {:ok, branch} when is_binary(branch) and branch != "" -> "origin/#{branch}"
      _ -> @default_base_ref
    end
  end

  @doc false
  @spec normalize_git_url(term()) :: map() | nil
  def normalize_git_url(url) when is_binary(url) do
    value =
      url
      |> String.trim()
      |> String.replace_prefix("git+", "")

    cond do
      match = Regex.run(~r/^git@([^:]+):([^\/]+)\/(.+)$/, value) ->
        [_, host, owner, repo] = match
        git_parts(host, owner, repo)

      match = Regex.run(~r/^(?:https?:\/\/|ssh:\/\/git@|git:\/\/)([^\/]+)\/([^\/]+)\/(.+)$/, value) ->
        [_, host, owner, repo] = match
        git_parts(host, owner, repo)

      match = Regex.run(~r/^github:([^\/]+)\/(.+)$/, value) ->
        [_, owner, repo] = match
        git_parts("github.com", owner, repo)

      match = Regex.run(~r/^([^\/:]+(?:\.[^\/:]+)+)\/([^\/]+)\/(.+)$/, value) ->
        [_, host, owner, repo] = match
        git_parts(host, owner, repo)

      true ->
        nil
    end
  end

  def normalize_git_url(_url), do: nil

  defp git_parts(host, owner, repo) do
    repo =
      repo
      |> String.trim_trailing("/")
      |> String.replace(~r/\.git(#.*)?$/, "")
      |> String.replace(~r/#.*$/, "")

    %{
      host: String.downcase(host),
      owner: owner,
      repo: repo,
      normalized: "#{String.downcase(host)}/#{owner}/#{repo}"
    }
  end
end
