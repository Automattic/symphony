defmodule SymphonyElixir.GitHub.RepoTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.GitHub.Repo

  test "extracts owner and repo from supported GitHub origin URLs" do
    assert Repo.from_url("git@github.com:acme/symphony.git") == "acme/symphony"
    assert Repo.from_url("https://github.com/acme/symphony.git") == "acme/symphony"
    assert Repo.from_url("ssh://git@github.com/acme/symphony/") == "acme/symphony"
  end

  test "rejects missing malformed and non-GitHub URLs" do
    assert Repo.from_url(nil) == nil
    assert Repo.from_url("git@github.com-acme/symphony.git") == nil
    assert Repo.from_url("https://example.com/acme/symphony.git") == nil
    assert Repo.from_url("not a url") == nil
  end

  test "compares normalized repo targets" do
    assert Repo.same?(" Acme/Symphony.git ", "acme/symphony/")
    refute Repo.same?("acme/symphony", "other/symphony")
    refute Repo.same?(nil, "acme/symphony")
  end
end
