defmodule SymphonyElixir.GitHub.HostsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Hosts

  test "public GitHub hosts are allowed and canonicalized" do
    assert Hosts.allowed_github_hosts() == ["github.com", "www.github.com"]
    assert Hosts.github_host?("github.com")
    assert Hosts.github_host?("WWW.GITHUB.COM")
    assert Hosts.canonical_github_host("www.github.com") == {:ok, "github.com"}
    assert Hosts.canonical_github_host("github.com") == {:ok, "github.com"}
  end

  test "configured enterprise hosts are normalized and allowed" do
    write_workflow_file!(Workflow.workflow_file_path(),
      github: %{enterprise_hosts: [" GITHUB.EXAMPLE.COM ", "github.example.com"]}
    )

    assert Hosts.allowed_github_hosts() == ["github.com", "www.github.com", "github.example.com"]
    assert Hosts.github_host?("github.example.com")
    assert Hosts.canonical_github_host("GITHUB.EXAMPLE.COM") == {:ok, "github.example.com"}
  end

  test "explicit enterprise host options avoid reading runtime config" do
    assert Hosts.allowed_github_hosts(github_enterprise_hosts: ["GHE.EXAMPLE.test"]) == [
             "github.com",
             "www.github.com",
             "ghe.example.test"
           ]

    assert Hosts.github_host?("ghe.example.test", github_enterprise_hosts: ["GHE.EXAMPLE.test"])
    assert Hosts.canonical_github_host("ghe.example.test", github_enterprise_hosts: ["GHE.EXAMPLE.test"]) == {:ok, "ghe.example.test"}
  end

  test "non-allowlisted and non-binary hosts are rejected" do
    refute Hosts.github_host?("github.evil.tld")
    refute Hosts.github_host?("www.github.com.evil.tld")
    refute Hosts.github_host?(nil)
    assert Hosts.canonical_github_host("github.evil.tld") == :error
    assert Hosts.canonical_github_host(nil) == :error
  end
end
