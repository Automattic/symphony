defmodule SymphonyElixir.Routing.ResolverTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Routing.Resolver

  describe "resolve/2" do
    test "returns the matched repo for a unique team-only route" do
      web = repo("web", team: "RSM")
      api = repo("api", team: "API")
      issue = issue(team: %{key: "RSM", name: "Radical Speed Month"})

      assert Resolver.resolve(issue, [web, api]) == {:matched, web}
    end

    test "returns a conflict when multiple repos match" do
      backend = repo("backend", team: "RSM", labels: ["backend"])
      api = repo("api", team: "RSM", labels: ["api"])
      issue = issue(team: %{key: "RSM"}, labels: ["backend", "api"])

      assert Resolver.resolve(issue, [backend, api]) == {:conflict, [backend, api]}
    end

    test "returns unmatched when no repos match" do
      issue = issue(team: %{key: "RSM"})

      assert Resolver.resolve(issue, [repo("api", team: "API")]) == :unmatched
    end

    test "matches team plus projects with any-of semantics" do
      repo = repo("web", team: "RSM", projects: ["Project Alpha", "Project Beta"])

      matching_issue = issue(team: %{key: "RSM"}, project: %{id: "project-1", name: "Project Beta"})
      other_project_issue = issue(team: %{key: "RSM"}, project: %{id: "project-2", name: "Project Gamma"})

      assert Resolver.resolve(matching_issue, [repo]) == {:matched, repo}
      assert Resolver.resolve(other_project_issue, [repo]) == :unmatched
      assert Resolver.resolve(issue(team: %{key: "RSM"}), [repo]) == :unmatched
    end

    test "matches team plus labels with AND semantics" do
      repo = repo("web", team: "RSM", labels: ["Backend", "API"])

      matching_issue = issue(team: %{key: "RSM"}, labels: ["api", "backend", "urgent"])
      missing_label_issue = issue(team: %{key: "RSM"}, labels: ["api"])

      assert Resolver.resolve(matching_issue, [repo]) == {:matched, repo}
      assert Resolver.resolve(missing_label_issue, [repo]) == :unmatched
    end

    test "matches team plus assignee by id, name, or email" do
      id_repo = repo("by-id", team: "RSM", assignee: "user-1")
      name_repo = repo("by-name", team: "RSM", assignee: "Chi Hsuan")
      email_repo = repo("by-email", team: "RSM", assignee: "chi@example.com")

      assert Resolver.resolve(issue(team: %{key: "RSM"}, assignee_id: "user-1"), [id_repo]) ==
               {:matched, id_repo}

      assert Resolver.resolve(%{team: %{key: "RSM"}, assignee: %{name: "Chi Hsuan"}}, [name_repo]) ==
               {:matched, name_repo}

      assert Resolver.resolve(%{team: %{key: "RSM"}, assignee: %{email: "chi@example.com"}}, [email_repo]) ==
               {:matched, email_repo}
    end

    test "matches all selectors together" do
      repo =
        repo("web",
          team: "RSM",
          projects: ["project-1"],
          labels: ["backend", "agent-ready"],
          assignee: "user-1"
        )

      issue =
        issue(
          team: %{key: "RSM"},
          project: %{id: "project-1", name: "Project Alpha"},
          labels: ["agent-ready", "backend", "triaged"],
          assignee_id: "user-1"
        )

      assert Resolver.resolve(issue, [repo]) == {:matched, repo}
    end
  end

  describe "matches?/2" do
    test "supports string-keyed repo entries and nested match maps" do
      issue = issue(team: %{name: "Radical Speed Month"}, labels: ["backend"])

      assert Resolver.matches?(issue, %{"name" => "web", "match" => %{"team" => "Radical Speed Month", "labels" => ["backend"]}})
    end

    test "supports scalar project values and non-string label values" do
      issue = %{team: "RSM", project: "project-1", labels: ["backend"]}
      repo = %{"name" => "web", "match" => %{"team" => "RSM", "projects" => "project-1", "labels" => [:Backend]}}

      assert Resolver.matches?(issue, repo)
    end

    test "returns false for invalid routes" do
      refute Resolver.matches?(issue(team: %{key: "RSM"}), repo("missing-team"))
      refute Resolver.matches?(issue(team: %{key: "RSM"}), :not_a_repo)
    end
  end

  describe "validate_repos/1" do
    test "accepts distinct match rules" do
      assert :ok =
               Resolver.validate_repos([
                 repo("web", team: "RSM", labels: ["web"]),
                 repo("api", team: "RSM", labels: ["api"]),
                 repo("docs", team: "DOCS")
               ])
    end

    test "rejects repos without a team" do
      web = repo("web", labels: ["web"])

      assert {:error, errors} = Resolver.validate_repos([web])
      assert Enum.any?(errors, &match?({:missing_team, ^web}, &1))
    end

    test "rejects blank team values and malformed nested match rules" do
      blank_team = repo("blank", team: " ")
      malformed_match = %{name: "malformed", match: :bad}

      assert {:error, errors} = Resolver.validate_repos([blank_team, malformed_match])
      assert Enum.any?(errors, &match?({:missing_team, ^blank_team}, &1))
      assert Enum.any?(errors, &match?({:missing_team, ^malformed_match}, &1))
    end

    test "rejects identical match rules across repos" do
      web = repo("web", team: "RSM", projects: ["P2", "P1"], labels: ["Backend", "API"], assignee: "user-1")
      api = repo("api", team: "RSM", projects: ["P1", "P2"], labels: ["api", "backend"], assignee: "user-1")

      assert {:error, errors} = Resolver.validate_repos([web, api])

      assert Enum.any?(errors, fn
               {:identical_match_rules, repos} -> repos == [web, api]
               _error -> false
             end)
    end

    test "rejects multiple team-only catch-all repos for the same team" do
      web = repo("web", team: "RSM")
      api = repo("api", team: "RSM")

      assert {:error, errors} = Resolver.validate_repos([web, api])

      assert Enum.any?(errors, fn
               {:ambiguous_team_catch_all, "RSM", repos} -> repos == [web, api]
               _error -> false
             end)
    end

    test "requires an explicit default when a team catch-all shares a team with specific repos" do
      catch_all = repo("default", team: "RSM")
      api = repo("api", team: "RSM", labels: ["api"])

      assert {:error, errors} = Resolver.validate_repos([catch_all, api])

      assert Enum.any?(errors, fn
               {:ambiguous_team_catch_all, "RSM", repos} -> repos == [catch_all]
               _error -> false
             end)

      assert :ok = Resolver.validate_repos([Map.put(catch_all, :default, true), api])
    end

    test "rejects more than one default repo per team" do
      web = repo("web", team: "RSM", labels: ["web"], default: true)
      api = repo("api", team: "RSM", labels: ["api"], default: true)

      assert {:error, errors} = Resolver.validate_repos([web, api])

      assert Enum.any?(errors, fn
               {:multiple_defaults, "RSM", repos} -> repos == [web, api]
               _error -> false
             end)
    end
  end

  describe "validate_repos!/1" do
    test "returns ok for valid repo rules" do
      assert Resolver.validate_repos!([repo("web", team: "RSM")]) == :ok
    end

    test "raises on invalid repo rules" do
      assert_raise ArgumentError, ~r/invalid routing repos/, fn ->
        Resolver.validate_repos!([repo("web")])
      end
    end
  end

  defp repo(name, attrs \\ []) do
    attrs
    |> Map.new()
    |> Map.put(:name, name)
  end

  defp issue(attrs) do
    struct!(Issue, attrs)
  end
end
