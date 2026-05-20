defmodule SymphonyElixir.DependencyAuditTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config
  alias SymphonyElixir.DependencyAudit
  alias SymphonyElixir.DependencyAudit.{MixParser, NpmParser}

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-dependency-audit-#{System.unique_integer([:positive])}"
      )

    repo = Path.join(test_root, "repo")
    File.mkdir_p!(repo)
    init_repo!(repo)

    on_exit(fn -> File.rm_rf(test_root) end)

    {:ok, repo: repo}
  end

  test "allows a new Hex dependency from the official registry", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    write_mix!(repo, ~s({:jason, "~> 1.4"},\n      {:plug, "~> 1.15"}))

    assert {:ok, []} = DependencyAudit.audit(repo, audit_opts())
  end

  test "allows new package json registry dependencies", %{repo: repo} do
    write_package_json!(repo, %{"dependencies" => %{}})
    commit_base!(repo)

    write_package_json!(repo, %{"dependencies" => %{"helper" => "^1.0.0"}})

    assert {:ok, []} = DependencyAudit.audit(repo)
  end

  test "uses configured repo base branch when base_ref is omitted", %{repo: repo} do
    write_workflow_file!(Workflow.workflow_file_path(),
      repos: [
        %{
          "name" => "default",
          "path" => Path.dirname(Workflow.workflow_file_path()),
          "workflow" => Path.basename(Workflow.workflow_file_path()),
          "team" => "Test",
          "base_branch" => "develop"
        }
      ]
    )

    write_package_json!(repo, %{"dependencies" => %{}})
    commit_base!(repo)
    git!(repo, ["update-ref", "refs/remotes/origin/develop", "HEAD"])

    File.write!(Path.join(repo, "README.md"), "changed\n")

    assert {:ok, []} = DependencyAudit.audit(repo, settings: Config.settings!())
  end

  test "git audit commands ignore malicious repo fsmonitor config", %{repo: repo} do
    write_package_json!(repo, %{"dependencies" => %{}})
    commit_base!(repo)

    proof = Path.join(repo, "SYMPHONY_PWNED")
    git!(repo, ["config", "core.fsmonitor", "sh -c 'touch \"#{proof}\"'"])
    write_package_json!(repo, %{"dependencies" => %{"helper" => "^1.0.0"}})

    assert {:ok, []} = DependencyAudit.audit(repo)
    refute File.exists?(proof)
  end

  test "allows a new same-owner GitHub dependency", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    write_mix!(repo, ~s({:jason, "~> 1.4"},\n      {:helper, git: "https://github.com/acme/helper.git"}))

    assert {:ok, []} =
             DependencyAudit.audit(repo, audit_opts(origin_url: "git@github.com:acme/app.git"))
  end

  test "holds a new untrusted git dependency", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    write_mix!(repo, ~s({:jason, "~> 1.4"},\n      {:helper, git: "https://github.com/attacker/helper.git"}))

    assert {:hold, [%{path: "mix.exs", package: "helper", reason: "untrusted_git_source"}]} =
             DependencyAudit.audit(repo, audit_opts(origin_url: "git@github.com:acme/app.git"))
  end

  test "does not gate an existing untrusted git dependency unchanged from base", %{repo: repo} do
    write_mix!(repo, ~s({:helper, git: "https://github.com/attacker/helper.git"}))
    commit_base!(repo)

    File.write!(Path.join(repo, "README.md"), "changed\n")

    assert {:ok, []} = DependencyAudit.audit(repo, audit_opts())
  end

  test "ignores dependency manifest removals", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    File.rm!(Path.join(repo, "mix.exs"))

    assert {:ok, []} = DependencyAudit.audit(repo, audit_opts())
  end

  test "ignores source-identical git, path, and unknown entries while auditing other deltas", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "apps/shared"))

    write_mix!(repo, ~s({:helper, git: "https://github.com/attacker/helper.git"},\n      {:shared, path: "apps/shared"}))

    write_package_json!(repo, %{
      "dependencies" => %{
        "odd" => %{"version" => "1.0.0"}
      }
    })

    commit_base!(repo)

    write_mix!(repo, ~s({:helper, git: "https://github.com/attacker/helper.git"},\n      {:shared, path: "apps/shared"},\n      {:jason, "~> 1.4"}))

    write_package_json!(repo, %{
      "dependencies" => %{
        "odd" => %{"version" => "1.0.0"},
        "safe" => "^1.0.0"
      }
    })

    assert {:ok, []} = DependencyAudit.audit(repo, audit_opts())
  end

  test "allows a version bump within the same registry", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    write_mix!(repo, ~s({:jason, "~> 1.5"}))

    assert {:ok, []} = DependencyAudit.audit(repo, audit_opts())
  end

  test "holds a package json git dependency from an untrusted owner", %{repo: repo} do
    write_package_json!(repo, %{"dependencies" => %{"left-pad" => "^1.3.0"}})
    commit_base!(repo)

    write_package_json!(repo, %{
      "dependencies" => %{
        "left-pad" => "^1.3.0",
        "helper" => "git+https://github.com/attacker/helper"
      }
    })

    assert {:hold, [%{path: "package.json", package: "helper", reason: "untrusted_git_source"}]} =
             DependencyAudit.audit(repo, audit_opts())
  end

  test "holds package json dependencies with unrecognized source syntax", %{repo: repo} do
    write_package_json!(repo, %{"dependencies" => %{}})
    commit_base!(repo)

    write_package_json!(repo, %{"dependencies" => %{"odd" => %{"version" => "1.0.0"}}})

    assert {:hold, [%{path: "package.json", package: "odd", reason: "unrecognized_dependency_source", to: "unknown"}]} =
             DependencyAudit.audit(repo, audit_opts())
  end

  test "holds when mix parser cannot statically recognize deps syntax", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    File.write!(Path.join(repo, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project
      def project, do: []
      def application, do: []
      defp deps, do: external_deps()
    end
    """)

    assert {:hold, [%{path: "mix.exs", package: "manifest", reason: reason}]} =
             DependencyAudit.audit(repo, audit_opts())

    assert reason =~ "parser_unrecognized"
  end

  test "user dependency allow-lists extend defaults", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    File.mkdir_p!(Path.join(repo, "../shared-lib"))

    write_mix!(
      repo,
      ~s({:private_dep, "~> 1.0", repo: "private-hex.internal"},\n      {:internal, git: "https://git.internal.example/team/internal.git"},\n      {:shared, path: "../shared-lib"})
    )

    settings = %{
      Config.settings!()
      | dependencies: %{
          Config.settings!().dependencies
          | allow_registries: ["private-hex.internal"],
            allow_git_sources: ["git.internal.example/*/*"],
            allow_path_sources: ["../shared-lib"]
        }
    }

    assert {:ok, []} = DependencyAudit.audit(repo, audit_opts(settings: settings))
  end

  test "holds untrusted registries and outside workspace paths", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    write_mix!(repo, ~s({:private_dep, "~> 1.0", repo: "evil.hex"},\n      {:outside, path: "../outside"}))

    assert {:hold, holds} = DependencyAudit.audit(repo, audit_opts())
    assert Enum.any?(holds, &match?(%{package: "private_dep", reason: "untrusted_registry", to: "registry:evil.hex"}, &1))
    assert Enum.any?(holds, &match?(%{package: "outside", reason: "outside_workspace_path", to: "path:../outside"}, &1))
  end

  test "reports previous registry, path, and unknown sources for source changes", %{repo: repo} do
    File.mkdir_p!(Path.join(repo, "apps/shared"))

    write_mix!(repo, ~s({:registry_dep, "~> 1.0"},\n      {:path_dep, path: "apps/shared"}))

    write_package_json!(repo, %{
      "dependencies" => %{
        "odd" => %{"version" => "1.0.0"}
      }
    })

    commit_base!(repo)

    write_mix!(repo, ~s({:registry_dep, git: "https://github.com/attacker/registry-dep.git"},\n      {:path_dep, git: "https://github.com/attacker/path-dep.git"}))

    write_package_json!(repo, %{
      "dependencies" => %{
        "odd" => "git+https://github.com/attacker/odd.git"
      }
    })

    assert {:hold, holds} = DependencyAudit.audit(repo, audit_opts())

    assert Enum.any?(
             holds,
             &match?(%{package: "registry_dep", from: "registry:hex.pm", reason: "untrusted_git_source"}, &1)
           )

    assert Enum.any?(holds, &match?(%{package: "path_dep", from: "path:apps/shared"}, &1))
    assert Enum.any?(holds, &match?(%{package: "odd", from: "unknown"}, &1))
  end

  test "allows workspace-local paths and default upstream GitHub owners", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    File.mkdir_p!(Path.join(repo, "apps/shared"))

    write_mix!(
      repo,
      ~s({:shared, path: "apps/shared"},\n      {:plug, git: "https://github.com/elixir-plug/plug.git"})
    )

    assert {:ok, []} = DependencyAudit.audit(repo, audit_opts())
  end

  test "holds path deps that resolve outside the workspace via symlinks", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    outside = Path.join(Path.dirname(repo), "outside-lib")
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(repo, "apps"))
    File.ln_s!(outside, Path.join(repo, "apps/shared"))

    write_mix!(repo, ~s({:jason, "~> 1.4"},\n      {:shared, path: "apps/shared"}))

    assert {:hold, [%{path: "mix.exs", package: "shared", reason: "outside_workspace_path"}]} =
             DependencyAudit.audit(repo, audit_opts())
  end

  test "holds when the base manifest cannot be parsed", %{repo: repo} do
    File.write!(Path.join(repo, "mix.exs"), "defmodule Broken do")
    commit_base!(repo)

    write_mix!(repo, ~s({:jason, "~> 1.4"}))

    assert {:hold, [%{package: "base_manifest", reason: reason}]} =
             DependencyAudit.audit(repo, audit_opts())

    assert reason =~ "base_parser_unrecognized"
  end

  test "handles newly tracked manifests without a base version", %{repo: repo} do
    File.write!(Path.join(repo, "README.md"), "base\n")
    commit_base!(repo)

    write_mix!(repo, ~s({:jason, "~> 1.4"}))

    assert {:ok, []} = DependencyAudit.audit(repo, audit_opts())
  end

  test "treats non-git workspaces as a no-op" do
    assert {:ok, []} =
             DependencyAudit.audit("/tmp/not-a-repo",
               settings: Config.settings!(),
               command_runner: fn
                 "git", _args, _opts -> {"fatal: not a git repository", 128}
               end
             )
  end

  test "holds when the workspace is a git repo but the base ref is unresolvable" do
    assert {:hold, [hold]} =
             DependencyAudit.audit("/tmp/repo",
               settings: Config.settings!(),
               base_ref: "origin/main",
               command_runner: fn
                 "git", ["rev-parse", "--verify", "origin/main^{commit}"], _opts ->
                   {"fatal: ambiguous argument 'origin/main^{commit}': unknown revision", 128}
               end
             )

    assert %{package: "base_ref", to: "origin/main", from: nil} = hold
    assert hold.reason =~ "base_ref_unavailable"
    assert hold.reason =~ "unknown revision"
  end

  test "holds when the rev-parse output is non-binary" do
    assert {:hold, [%{package: "base_ref", reason: reason}]} =
             DependencyAudit.audit("/tmp/repo",
               settings: Config.settings!(),
               base_ref: "origin/main",
               command_runner: fn
                 "git", ["rev-parse", "--verify", _ref], _opts -> {:bad_output, 1}
               end
             )

    assert reason =~ "base_ref_unavailable"
  end

  test "surfaces git diff failures while resolving manifest changes" do
    assert {:error, {:git_failed, ["diff", "--name-only", "origin/main", "--"], "fatal: other"}} =
             DependencyAudit.audit("/tmp/repo",
               settings: Config.settings!(),
               base_ref: "origin/main",
               command_runner: fn
                 "git", ["rev-parse", "--verify", _ref], _opts -> {"abc123\n", 0}
                 "git", ["diff", "--name-only", "origin/main", "--"], _opts -> {"fatal: other", 2}
               end
             )
  end

  test "treats git manifest path checks from a non-repo workspace as empty" do
    assert {:ok, []} =
             DependencyAudit.audit("/tmp/repo",
               settings: Config.settings!(),
               base_ref: "origin/main",
               command_runner: fn
                 "git", ["rev-parse", "--verify", _ref], _opts -> {"abc123\n", 0}
                 "git", _args, _opts -> {"fatal: not a git repository", 128}
               end
             )
  end

  test "surfaces non-binary git output while resolving manifest changes" do
    assert {:error, {:git_failed, ["diff", "--name-only", "origin/main", "--"], 2, :bad_output}} =
             DependencyAudit.audit("/tmp/repo",
               settings: Config.settings!(),
               base_ref: "origin/main",
               command_runner: fn
                 "git", ["rev-parse", "--verify", _ref], _opts -> {"abc123\n", 0}
                 "git", ["diff", "--name-only", "origin/main", "--"], _opts -> {:bad_output, 2}
               end
             )
  end

  test "surfaces structured non-binary git diff failures while resolving manifest changes" do
    assert {:error, {:git_failed, ["diff", "--name-only", "origin/main", "--"], 2, {:bad_output, 2}}} =
             DependencyAudit.audit("/tmp/repo",
               settings: Config.settings!(),
               base_ref: "origin/main",
               command_runner: fn
                 "git", ["rev-parse", "--verify", _ref], _opts -> {"abc123\n", 0}
                 "git", ["diff", "--name-only", "origin/main", "--"], _opts -> {{:bad_output, 2}, 2}
               end
             )
  end

  test "fails closed when settings are malformed", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    write_mix!(repo, ~s({:private_dep, "~> 1.0", repo: "private.hex"}))

    assert {:hold, [%{reason: "untrusted_registry"}]} =
             DependencyAudit.audit(repo, audit_opts(settings: %{}))

    settings = %{
      Config.settings!()
      | dependencies: %{Config.settings!().dependencies | allow_registries: nil}
    }

    assert {:hold, [%{reason: "untrusted_registry"}]} =
             DependencyAudit.audit(repo, audit_opts(settings: settings))
  end

  test "does not trust same-owner sources for non-GitHub origins", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    write_mix!(repo, ~s({:helper, git: "https://github.com/acme/helper.git"}))

    assert {:hold, [%{reason: "untrusted_git_source"}]} =
             DependencyAudit.audit(repo, audit_opts(origin_url: "git@gitlab.com:acme/app.git"))
  end

  test "resolves same-owner GitHub sources from the origin remote", %{repo: repo} do
    write_mix!(repo, ~s({:jason, "~> 1.4"}))
    commit_base!(repo)

    write_mix!(repo, ~s({:helper, git: "https://github.com/acme/helper.git"}))

    assert {:ok, []} =
             DependencyAudit.audit(
               repo,
               audit_opts(
                 command_runner: fn
                   "git", ["remote", "get-url", "origin"], _opts -> {"git@github.com:acme/app.git\n", 0}
                   command, args, opts -> System.cmd(command, args, opts ++ [stderr_to_stdout: true])
                 end
               )
             )
  end

  test "recognizes PR creation command forms and ignores other command values" do
    assert DependencyAudit.git_pr_create_command?("gh pr create --fill")
    assert DependencyAudit.git_pr_create_command?("env FOO=1 ghe pr create")
    refute DependencyAudit.git_pr_create_command?("gh issue create")
    refute DependencyAudit.git_pr_create_command?([:not, :a, :command])
  end

  test "normalizes supported git URL forms" do
    assert %{normalized: "github.com/acme/tool"} = DependencyAudit.normalize_git_url("github:acme/tool")
    assert %{normalized: "git.internal.example/team/tool"} = DependencyAudit.normalize_git_url("git.internal.example/team/tool.git")
    assert is_nil(DependencyAudit.normalize_git_url("not-a-git-url"))
    assert is_nil(DependencyAudit.normalize_git_url(nil))
  end

  test "mix parser fails closed for unsupported source syntax" do
    assert {:error, :deps_function_not_found} = MixParser.parse("defmodule Demo.MixProject do\nend")

    assert {:error, :unsupported_dependency_syntax} =
             MixParser.parse("""
             defmodule Demo.MixProject do
               defp deps, do: [:jason]
             end
             """)

    assert {:error, {:unsupported_dependency, :jason}} =
             MixParser.parse("""
             defmodule Demo.MixProject do
               defp deps, do: [{:jason, [:not_keyword]}]
             end
             """)

    assert {:ok, [%{source: %{type: :registry, registry: "hex.pm"}}]} =
             MixParser.parse("""
             defmodule Demo.MixProject do
               defp deps, do: [{:jason, only: :test}]
             end
             """)

    assert {:ok, [%{source: %{type: :registry, registry: "hex.pm"}}]} =
             MixParser.parse("""
             defmodule Demo.MixProject do
               defp deps, do: [{:jason, "~> 1.4", repo: :hexpm}]
             end
             """)

    assert {:ok, [%{source: %{type: :unknown, raw: "not-a-url"}}]} =
             MixParser.parse("""
             defmodule Demo.MixProject do
               defp deps, do: [{:jason, git: "not-a-url"}]
             end
             """)
  end

  test "npm parser fails closed for unsupported package json forms" do
    assert {:error, :package_json_not_object} = NpmParser.parse("[]")
    assert {:error, %Jason.DecodeError{}} = NpmParser.parse("{")

    assert {:ok, deps} =
             NpmParser.parse("""
             {
               "dependencies": {
                 "local": "file:../local",
                 "remote": "https://registry.example.test/remote/-/remote-1.0.0.tgz",
                 "bad_url": "https:///missing-host",
                 "bad": {"version": "1.0.0"}
               },
               "devDependencies": "bad"
             }
             """)

    assert Enum.any?(deps, &match?(%{package: "local", source: %{type: :path, path: "../local"}}, &1))

    assert Enum.any?(
             deps,
             &match?(%{package: "remote", source: %{type: :registry, registry: "registry.example.test"}}, &1)
           )

    assert Enum.any?(deps, &match?(%{package: "bad", source: %{type: :unknown, raw: "non_string_spec"}}, &1))
    assert Enum.any?(deps, &match?(%{package: "bad_url", source: %{type: :unknown, raw: "https:///missing-host"}}, &1))

    assert Enum.any?(
             deps,
             &match?(%{package: "__devDependencies__", source: %{type: :unknown, raw: "devDependencies"}}, &1)
           )

    assert {:ok, [%{source: %{type: :unknown, raw: "github:"}}]} =
             NpmParser.parse(~s({"dependencies":{"bad":"github:"}}))
  end

  defp audit_opts(extra \\ []) do
    Keyword.merge([base_ref: "origin/main", settings: Config.settings!()], extra)
  end

  defp init_repo!(repo) do
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
  end

  defp commit_base!(repo) do
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "base"])
    git!(repo, ["update-ref", "refs/remotes/origin/main", "HEAD"])
  end

  defp write_mix!(repo, deps) do
    File.write!(Path.join(repo, "mix.exs"), """
    defmodule Demo.MixProject do
      use Mix.Project
      def project, do: []
      def application, do: []
      defp deps do
        [
          #{deps}
        ]
      end
    end
    """)
  end

  defp write_package_json!(repo, content) do
    File.write!(Path.join(repo, "package.json"), Jason.encode!(content, pretty: true))
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
