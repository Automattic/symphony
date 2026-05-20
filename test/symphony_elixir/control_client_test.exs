defmodule SymphonyElixir.ControlClientTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{ControlClient, Paths}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "symphony-control-client-test-#{System.unique_integer([:positive])}")

    previous_state_override = Application.get_env(:symphony_elixir, :state_root_override)
    previous_url_env = System.get_env("SYMPHONY_CONTROL_URL")
    previous_token_env = System.get_env("SYMPHONY_CONTROL_TOKEN")

    Paths.set_state_root(tmp)
    System.delete_env("SYMPHONY_CONTROL_URL")
    System.delete_env("SYMPHONY_CONTROL_TOKEN")

    on_exit(fn ->
      File.rm_rf(tmp)

      case previous_state_override do
        nil -> Application.delete_env(:symphony_elixir, :state_root_override)
        value -> Application.put_env(:symphony_elixir, :state_root_override, value)
      end

      restore("SYMPHONY_CONTROL_URL", previous_url_env)
      restore("SYMPHONY_CONTROL_TOKEN", previous_token_env)
    end)

    {:ok, tmp: tmp}
  end

  defp stub_post(parent, status, body) do
    fn url, payload, token ->
      send(parent, {:posted, url, payload, token})
      {:ok, status, body}
    end
  end

  defp default_opts(parent, status \\ 200, body \\ %{"ok" => true}) do
    [
      prefer_local?: false,
      control_url: "http://127.0.0.1:9999",
      control_token: "test-token",
      http_post: stub_post(parent, status, body)
    ]
  end

  test "pause_dispatch POSTs the reason and atomizes the JSON response" do
    parent = self()
    opts = default_opts(parent, 200, %{"paused" => true, "reason" => "deploy"})

    assert {:ok, %{paused: true, reason: "deploy"}} =
             ControlClient.pause_dispatch("deploy", opts)

    assert_received {:posted, "http://127.0.0.1:9999/api/v1/control/pause", %{reason: "deploy"}, "test-token"}
  end

  test "pause_dispatch sends an empty body when reason is nil" do
    parent = self()

    assert {:ok, _} = ControlClient.pause_dispatch(nil, default_opts(parent))
    assert_received {:posted, _url, %{}, _token}
  end

  test "resume_dispatch POSTs to the resume endpoint" do
    parent = self()

    assert {:ok, _} = ControlClient.resume_dispatch(default_opts(parent))

    assert_received {:posted, "http://127.0.0.1:9999/api/v1/control/resume", %{}, _token}
  end

  test "stop_running POSTs the issue identifier" do
    parent = self()

    assert {:ok, _} = ControlClient.stop_running("RSM-1", default_opts(parent))

    assert_received {:posted, "http://127.0.0.1:9999/api/v1/control/stop", %{issue_identifier: "RSM-1"}, _token}
  end

  test "dispatch_pr forwards target and intent" do
    parent = self()

    opts = default_opts(parent, 200, %{"pull_request_url" => "https://example/pr/1"})

    assert {:ok, %{pull_request_url: "https://example/pr/1"}} =
             ControlClient.dispatch_pr("https://example/pr/1", [intent: "fix CI"], opts)

    assert_received {:posted, _url, %{target: "https://example/pr/1", intent: "fix CI"}, _token}
  end

  test "dispatch_pr omits intent when blank" do
    parent = self()

    assert {:ok, _} = ControlClient.dispatch_pr("123", [intent: "  "], default_opts(parent))
    assert_received {:posted, _url, %{target: "123"} = body, _token}
    refute Map.has_key?(body, :intent)
  end

  test "maps HTTP 503 to :unavailable" do
    parent = self()

    assert :unavailable =
             ControlClient.resume_dispatch(default_opts(parent, 503, %{"error" => %{"code" => "x"}}))
  end

  test "maps HTTP 422 to {:error, {:invalid_request, body}}" do
    parent = self()
    body = %{"error" => %{"code" => "invalid_request"}}

    assert {:error, {:invalid_request, ^body}} =
             ControlClient.stop_running("RSM-?", default_opts(parent, 422, body))
  end

  test "maps HTTP 401 to {:error, {:unauthorized, body}}" do
    parent = self()

    assert {:error, {:unauthorized, _}} =
             ControlClient.resume_dispatch(default_opts(parent, 401, %{}))
  end

  test "maps transport errors to {:error, {:connection_failed, reason}}" do
    poster = fn _url, _body, _token -> {:error, :econnrefused} end

    assert {:error, {:connection_failed, :econnrefused}} =
             ControlClient.resume_dispatch(
               prefer_local?: false,
               control_url: "http://127.0.0.1:1",
               control_token: "t",
               http_post: poster
             )
  end

  test "returns {:error, :control_token_unavailable} when no token can be resolved" do
    poster = fn _url, _body, _token -> flunk("HTTP should not be called") end

    assert {:error, :control_token_unavailable} =
             ControlClient.resume_dispatch(
               prefer_local?: false,
               control_url: "http://127.0.0.1:1",
               http_post: poster
             )
  end

  test "uses SYMPHONY_CONTROL_URL env when no explicit URL is given" do
    parent = self()
    System.put_env("SYMPHONY_CONTROL_URL", "http://from-env:1234")

    assert {:ok, _} =
             ControlClient.resume_dispatch(
               prefer_local?: false,
               control_token: "t",
               http_post: stub_post(parent, 200, %{})
             )

    assert_received {:posted, "http://from-env:1234/api/v1/control/resume", _body, _token}
  end

  test "uses SYMPHONY_CONTROL_TOKEN env when no explicit token is given" do
    parent = self()
    System.put_env("SYMPHONY_CONTROL_TOKEN", "from-env-token")

    assert {:ok, _} =
             ControlClient.resume_dispatch(
               prefer_local?: false,
               control_url: "http://127.0.0.1:9999",
               http_post: stub_post(parent, 200, %{})
             )

    assert_received {:posted, _url, _body, "from-env-token"}
  end

  test "keeps unknown response keys as binaries so a hostile endpoint cannot exhaust the atom table" do
    parent = self()
    novel_key = "definitely_not_an_existing_atom_#{System.unique_integer([:positive])}"
    body = %{"paused" => true, novel_key => "value"}

    assert {:ok, result} = ControlClient.pause_dispatch("x", default_opts(parent, 200, body))

    assert result[:paused] == true
    assert result[novel_key] == "value"
    assert_raise ArgumentError, fn -> String.to_existing_atom(novel_key) end
  end

  test "falls back to ControlUrl/ControlToken persisted files when env is unset" do
    parent = self()
    File.mkdir_p!(Paths.state_root())
    File.write!(Paths.control_url_file(), "http://persisted:5555\n")
    File.write!(Paths.control_token_file(), "persisted-token\n")

    assert {:ok, _} =
             ControlClient.resume_dispatch(
               prefer_local?: false,
               http_post: stub_post(parent, 200, %{})
             )

    assert_received {:posted, "http://persisted:5555/api/v1/control/resume", _body, "persisted-token"}
  end

  defp restore(name, nil), do: System.delete_env(name)
  defp restore(name, value), do: System.put_env(name, value)
end
