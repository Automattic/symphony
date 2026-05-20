defmodule SymphonyElixirWeb.AuditController do
  @moduledoc """
  NDJSON API for filtered audit events.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.AuditLog

  @ndjson_content_type "application/x-ndjson"

  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, params) do
    query_opts = audit_query_opts(params)

    case paginated_stream(query_opts, params) do
      {:ok, stream, next_cursor} ->
        conn
        |> put_resp_content_type(@ndjson_content_type)
        |> maybe_put_download_header(params)
        |> maybe_put_next_cursor(next_cursor)
        |> stream_ndjson(stream)

      {:error, reason} ->
        error_response(conn, 400, "invalid_audit_filter", inspect(reason))
    end
  end

  defp paginated_stream(query_opts, params) do
    case parse_limit(Map.get(params, "limit")) do
      {:ok, nil} ->
        with {:ok, stream} <- AuditLog.query(query_opts) do
          {:ok, stream, nil}
        end

      {:ok, limit} ->
        with {:ok, stream} <- AuditLog.query(Keyword.put(query_opts, :limit, limit + 1)) do
          events = Enum.to_list(stream)
          {page, overflow} = Enum.split(events, limit)
          {:ok, page, page_next_cursor(page, overflow)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp audit_query_opts(params) do
    [
      issue: Map.get(params, "issue"),
      issue_id: Map.get(params, "issue_id"),
      issue_identifier: Map.get(params, "issue_identifier"),
      repo: Map.get(params, "repo"),
      event_type: Map.get(params, "type") || Map.get(params, "event_type"),
      run_id: Map.get(params, "run_id"),
      from: Map.get(params, "from") || Map.get(params, "date_from"),
      to: Map.get(params, "to") || Map.get(params, "date_to"),
      since: Map.get(params, "since"),
      cursor: Map.get(params, "cursor")
    ]
  end

  defp parse_limit(nil), do: {:ok, nil}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, :invalid_limit}
    end
  end

  defp next_cursor(event) when is_map(event) do
    date = Map.get(event, "date")
    record_hash = Map.get(event, "record_hash")

    if is_binary(date) and is_binary(record_hash), do: "#{date}:#{record_hash}", else: nil
  end

  defp page_next_cursor(_page, []), do: nil
  defp page_next_cursor(page, _overflow), do: page |> List.last() |> next_cursor()

  defp maybe_put_download_header(conn, %{"download" => value}) when value in ["1", "true", "ndjson"] do
    put_resp_header(conn, "content-disposition", ~s(attachment; filename="symphony-audit.ndjson"))
  end

  defp maybe_put_download_header(conn, _params), do: conn

  defp maybe_put_next_cursor(conn, nil), do: conn

  defp maybe_put_next_cursor(conn, cursor) do
    put_resp_header(conn, "x-next-cursor", cursor)
  end

  defp stream_ndjson(conn, stream) do
    conn = send_chunked(conn, 200)

    Enum.reduce_while(stream, conn, fn event, conn ->
      {:ok, conn} = chunk(conn, Jason.encode!(event) <> "\n")
      {:cont, conn}
    end)
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end
end
