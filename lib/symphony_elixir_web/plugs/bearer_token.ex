defmodule SymphonyElixirWeb.Plugs.BearerToken do
  @moduledoc """
  Rejects requests whose `Authorization: Bearer <token>` header does not match
  the daemon's persisted control token. Used by the `/api/v1/control/*`
  endpoints so the CLI (`bin/symphony pr`, `mix symphony.{pause,resume,stop}`)
  can authenticate without distributed Erlang.
  """

  @behaviour Plug

  import Plug.Conn

  alias Plug.Conn
  alias SymphonyElixir.ControlToken

  @spec init(keyword()) :: keyword()
  def init(opts) do
    Keyword.put_new(opts, :token, &ControlToken.current/0)
  end

  @spec call(Conn.t(), keyword()) :: Conn.t()
  def call(%Conn{} = conn, opts) do
    expected = resolve_expected(Keyword.fetch!(opts, :token))

    case extract_bearer(conn) do
      {:ok, presented} ->
        if Plug.Crypto.secure_compare(presented, expected) do
          conn
        else
          reject(conn)
        end

      :error ->
        reject(conn)
    end
  end

  # Resolve the expected token. The default production resolver
  # (`&ControlToken.current/0`) hits the state-root on disk, so cache its
  # result for the BEAM's lifetime — the token is immutable per daemon run.
  # Custom resolvers (tests, future rotation) stay dynamic.
  defp resolve_expected(token) when is_binary(token), do: token

  defp resolve_expected(resolver) when is_function(resolver, 0) do
    if resolver == (&ControlToken.current/0) do
      cached_default_token()
    else
      resolver.()
    end
  end

  defp cached_default_token do
    case :persistent_term.get(__MODULE__, :unresolved) do
      :unresolved ->
        token = ControlToken.current()
        :persistent_term.put(__MODULE__, token)
        token

      cached ->
        cached
    end
  end

  defp extract_bearer(conn) do
    with [value] <- get_req_header(conn, "authorization"),
         [scheme, rest] <- String.split(value, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         token = String.trim_leading(rest),
         true <- token != "" do
      {:ok, token}
    else
      _ -> :error
    end
  end

  defp reject(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: %{code: "unauthorized", message: "Invalid or missing bearer token"}}))
    |> halt()
  end
end
