defmodule SymphonyElixirWeb.ControlApiController do
  @moduledoc """
  HTTP control plane for the Symphony daemon: pause, resume, stop, and
  PR dispatch. Used by `bin/symphony pr` and the `mix symphony.*` tasks
  via `SymphonyElixir.ControlClient`.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.Endpoint

  @spec pause(Conn.t(), map()) :: Conn.t()
  def pause(conn, params) do
    reason = string_param(params["reason"])
    respond(conn, Orchestrator.pause_dispatch(orchestrator(conn), reason))
  end

  @spec resume(Conn.t(), map()) :: Conn.t()
  def resume(conn, _params) do
    respond(conn, Orchestrator.resume_dispatch(orchestrator(conn)))
  end

  @spec stop(Conn.t(), map()) :: Conn.t()
  def stop(conn, %{"issue_identifier" => identifier}) when is_binary(identifier) and identifier != "" do
    respond(conn, Orchestrator.stop_running(orchestrator(conn), identifier))
  end

  def stop(conn, _params) do
    error_response(conn, 422, "invalid_request", "issue_identifier is required")
  end

  @spec dispatch_pr(Conn.t(), map()) :: Conn.t()
  def dispatch_pr(conn, %{"target" => target} = params) when is_binary(target) and target != "" do
    opts =
      case string_param(params["intent"]) do
        nil -> []
        intent -> [intent: intent]
      end

    respond(conn, Orchestrator.dispatch_pr(orchestrator(conn), target, opts))
  end

  def dispatch_pr(conn, _params) do
    error_response(conn, 422, "invalid_request", "target is required")
  end

  defp respond(conn, {:ok, payload}) when is_map(payload), do: json(conn, payload)

  defp respond(conn, :unavailable),
    do: error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")

  defp respond(conn, {:error, reason}) when reason in [:invalid_issue_id, :invalid_pr_target],
    do: error_response(conn, 422, "invalid_request", Atom.to_string(reason))

  defp respond(conn, {:error, reason}),
    do: error_response(conn, 500, "orchestrator_error", inspect(reason))

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator(conn) do
    Map.get(conn.assigns, :orchestrator) || Endpoint.config(:orchestrator) || Orchestrator
  end

  defp string_param(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_param(_), do: nil
end
