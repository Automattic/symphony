defmodule SymphonyElixirWeb.Plugs.BearerTokenTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias SymphonyElixirWeb.Plugs.BearerToken

  @token "secret-token-value"

  defmodule FakeToken do
    def value, do: "secret-token-value"
  end

  defp call(headers) do
    conn = conn(:post, "/api/v1/control/pause")

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc ->
        put_req_header(acc, name, value)
      end)

    BearerToken.call(conn, BearerToken.init(token: &FakeToken.value/0))
  end

  test "passes the connection through when the bearer token matches" do
    conn = call([{"authorization", "Bearer #{@token}"}])

    refute conn.halted
    assert conn.status in [nil, 200]
  end

  test "tolerates extra spaces between scheme and token" do
    conn = call([{"authorization", "Bearer    #{@token}"}])
    refute conn.halted
  end

  test "rejects requests without an Authorization header with 401" do
    conn = call([])

    assert conn.halted
    assert conn.status == 401
    assert json_body(conn)["error"]["code"] == "unauthorized"
  end

  test "rejects requests with a non-Bearer scheme with 401" do
    conn = call([{"authorization", "Basic #{Base.encode64("user:pass")}"}])

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects requests carrying the wrong token with 401" do
    conn = call([{"authorization", "Bearer not-the-right-token"}])

    assert conn.halted
    assert conn.status == 401
  end

  test "init defaults the token resolver to SymphonyElixir.ControlToken.current/0" do
    opts = BearerToken.init([])
    assert opts[:token] == (&SymphonyElixir.ControlToken.current/0)
  end

  defp json_body(conn) do
    Jason.decode!(conn.resp_body)
  end
end
