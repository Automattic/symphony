defmodule SymphonyElixir.AgentEnvTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentEnv

  describe "build/1" do
    test "passes whitelisted vars through as charlist tuples" do
      env = %{
        "PATH" => "/usr/bin:/bin",
        "HOME" => "/home/symphony",
        "USER" => "symphony",
        "LANG" => "en_US.UTF-8"
      }

      result = AgentEnv.build(env)

      assert {~c"PATH", ~c"/usr/bin:/bin"} in result
      assert {~c"HOME", ~c"/home/symphony"} in result
      assert {~c"USER", ~c"symphony"} in result
      assert {~c"LANG", ~c"en_US.UTF-8"} in result
    end

    test "always sets SYMPHONY_AGENT_RUNTIME=1" do
      result = AgentEnv.build(%{})

      assert {~c"SYMPHONY_AGENT_RUNTIME", ~c"1"} in result
    end

    test "strips provider and tracker API keys by mapping them to false" do
      env = %{
        "LINEAR_API_KEY" => "lin_api_secret",
        "ANTHROPIC_API_KEY" => "sk-ant-secret",
        "OPENAI_API_KEY" => "sk-secret",
        "AWS_SECRET_ACCESS_KEY" => "aws-secret"
      }

      result = AgentEnv.build(env)

      assert {~c"LINEAR_API_KEY", false} in result
      assert {~c"ANTHROPIC_API_KEY", false} in result
      assert {~c"OPENAI_API_KEY", false} in result
      assert {~c"AWS_SECRET_ACCESS_KEY", false} in result
    end

    test "passes GH_TOKEN and GITHUB_TOKEN so the agent can run gh pr create" do
      env = %{"GH_TOKEN" => "gho_abc", "GITHUB_TOKEN" => "ghp_xyz"}

      result = AgentEnv.build(env)

      assert {~c"GH_TOKEN", ~c"gho_abc"} in result
      assert {~c"GITHUB_TOKEN", ~c"ghp_xyz"} in result
    end

    test "passes SSH_AUTH_SOCK so git push over SSH keeps working" do
      env = %{"SSH_AUTH_SOCK" => "/tmp/ssh-1234/agent.567"}

      result = AgentEnv.build(env)

      assert {~c"SSH_AUTH_SOCK", ~c"/tmp/ssh-1234/agent.567"} in result
    end

    test "does not list a whitelisted var when the source env does not set it" do
      result = AgentEnv.build(%{})

      keys = Enum.map(result, fn {name, _value} -> name end)

      refute ~c"GH_TOKEN" in keys
      refute ~c"GITHUB_TOKEN" in keys
      refute ~c"SSH_AUTH_SOCK" in keys
      refute ~c"PATH" in keys
    end

    test "returns charlist names and charlist-or-false values (Port.open env shape)" do
      env = %{"PATH" => "/usr/bin", "SECRET" => "leak"}

      result = AgentEnv.build(env)

      Enum.each(result, fn {name, value} ->
        assert is_list(name), "expected charlist name, got #{inspect(name)}"

        assert value == false or is_list(value),
               "expected charlist or false, got #{inspect(value)}"
      end)
    end

    test "preserves an existing SYMPHONY_AGENT_RUNTIME marker rather than stripping it" do
      env = %{"SYMPHONY_AGENT_RUNTIME" => "0"}

      result = AgentEnv.build(env)

      refute {~c"SYMPHONY_AGENT_RUNTIME", false} in result
      assert {~c"SYMPHONY_AGENT_RUNTIME", ~c"1"} in result
    end
  end

  describe "runtime marker accessors" do
    test "runtime_marker_name/0 returns SYMPHONY_AGENT_RUNTIME" do
      assert AgentEnv.runtime_marker_name() == "SYMPHONY_AGENT_RUNTIME"
    end

    test "runtime_marker_value/0 returns \"1\"" do
      assert AgentEnv.runtime_marker_value() == "1"
    end
  end

  describe "build/0" do
    test "reads from the real process env and strips an injected secret" do
      key = "SYMPHONY_AGENT_ENV_TEST_SECRET_#{System.unique_integer([:positive])}"
      System.put_env(key, "should-not-leak")

      try do
        result = AgentEnv.build()

        assert {String.to_charlist(key), false} in result
        assert {~c"SYMPHONY_AGENT_RUNTIME", ~c"1"} in result
      after
        System.delete_env(key)
      end
    end
  end
end
