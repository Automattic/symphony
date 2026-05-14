defmodule SymphonyElixir.WorkspaceSafeGitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Workspace

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-safe-git-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    on_exit(fn -> File.rm_rf(test_root) end)

    {:ok, test_root: test_root}
  end

  test "safe_git applies defensive config overrides and env", %{test_root: test_root} do
    fake_git = Path.join(test_root, "fake-git")
    trace = Path.join(test_root, "trace")

    File.write!(fake_git, """
    #!/bin/sh
    {
      printf 'ARGV:%s\\n' "$*"
      printf 'GIT_CONFIG_GLOBAL:%s\\n' "$GIT_CONFIG_GLOBAL"
      printf 'GIT_CONFIG_SYSTEM:%s\\n' "$GIT_CONFIG_SYSTEM"
      printf 'GIT_OPTIONAL_LOCKS:%s\\n' "$GIT_OPTIONAL_LOCKS"
    } > "#{trace}"
    """)

    File.chmod!(fake_git, 0o755)

    assert {_output, 0} =
             Workspace.safe_git(fake_git, ["status"],
               env: [
                 {"GIT_CONFIG_GLOBAL", "/tmp/hostile-global"},
                 {"GIT_CONFIG_SYSTEM", "/tmp/hostile-system"},
                 {"GIT_OPTIONAL_LOCKS", "1"}
               ]
             )

    output = File.read!(trace)
    assert output =~ "-c core.sshCommand=ssh"
    assert output =~ "-c core.fsmonitor="
    assert output =~ "-c core.hooksPath="
    assert output =~ "-c protocol.ext.allow=never"
    assert output =~ "-c protocol.file.allow=user"
    assert output =~ "ARGV:"
    assert output =~ " status"
    assert output =~ "GIT_CONFIG_GLOBAL:/dev/null"
    assert output =~ "GIT_CONFIG_SYSTEM:/dev/null"
    assert output =~ "GIT_OPTIONAL_LOCKS:0"
  end

  test "safe_git does not execute repo-local core.fsmonitor", %{test_root: test_root} do
    repo = Path.join(test_root, "repo")
    proof = Path.join(test_root, "SYMPHONY_PWNED")

    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    git!(repo, ["config", "user.name", "Test User"])
    git!(repo, ["config", "user.email", "test@example.com"])
    File.write!(Path.join(repo, "README.md"), "safe git\n")
    git!(repo, ["add", "README.md"])
    git!(repo, ["commit", "-m", "initial"])
    git!(repo, ["config", "core.fsmonitor", "sh -c 'touch \"#{proof}\"'"])

    File.rm(proof)

    assert {_output, 0} = Workspace.safe_git(["-C", repo, "status", "--short"])
    refute File.exists?(proof)
  end

  defp git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed with #{status}: #{output}")
    end
  end
end
