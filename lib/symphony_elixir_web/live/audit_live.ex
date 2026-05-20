defmodule SymphonyElixirWeb.AuditLive do
  @moduledoc """
  Live audit timeline for local append-only audit records.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.AuditLog
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :verify_result, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :payload, Presenter.audit_payload(params, orchestrator(), snapshot_timeout_ms()))}
  end

  @impl true
  def handle_event("verify-chain", _params, socket) do
    date = socket.assigns.payload.filters.date_to || socket.assigns.payload.filters.date_from

    result =
      case AuditLog.verify_chain(date) do
        :ok -> %{status: :ok, message: "Chain verified for #{date}."}
        {:error, {:break_at, record_id}} -> %{status: :error, message: "Chain break at #{record_id}."}
      end

    {:noreply, assign(socket, :verify_result, result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell audit-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Audit</p>
            <h1 class="hero-title">Audit Timeline</h1>
            <p class="hero-copy">Filtered local audit records, chain verification, and NDJSON export.</p>
          </div>

          <div class="status-stack">
            <a class="action-pill hero-action" href="/">Dashboard</a>
            <a class="action-pill hero-action" href="/quality">Quality</a>
            <a class="action-pill hero-action" href={audit_export_href(@payload.filters)}>NDJSON</a>
          </div>
        </div>
      </header>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Filters</h2>
          </div>
        </div>

        <form class="quality-filter-form audit-filter-form" method="get" action="/audit">
          <label class="quality-field">
            <span>Repo</span>
            <select name="repo">
              <option value="" selected={blank?(@payload.filters.repo)}>All</option>
              <option :for={repo <- @payload.repos} value={repo} selected={@payload.filters.repo == repo}><%= repo %></option>
            </select>
          </label>

          <label class="quality-field">
            <span>Issue</span>
            <input type="text" name="issue" value={@payload.filters.issue || ""} />
          </label>

          <label class="quality-field">
            <span>Type</span>
            <input type="text" name="type" value={@payload.filters.event_type || ""} list="audit-event-types" />
            <datalist id="audit-event-types">
              <option :for={event_type <- @payload.event_types} value={event_type}></option>
            </datalist>
          </label>

          <label class="quality-field">
            <span>Run</span>
            <input type="text" name="run_id" value={@payload.filters.run_id || ""} />
          </label>

          <label class="quality-field">
            <span>From</span>
            <input type="date" name="from" value={@payload.filters.date_from || ""} />
          </label>

          <label class="quality-field">
            <span>To</span>
            <input type="date" name="to" value={@payload.filters.date_to || ""} />
          </label>

          <label class="quality-field audit-checkbox-field">
            <span>Since last poll</span>
            <input type="hidden" name="since_last_poll" value="0" />
            <input type="checkbox" name="since_last_poll" value="1" checked={Map.get(@payload.filters, :since_last_poll?)} />
          </label>

          <button type="submit" class="quality-submit">Apply</button>
        </form>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Timeline</h2>
            <p :if={@payload.truncated?} class="section-copy">Showing the first 200 records. Narrow filters or export NDJSON for the full slice.</p>
          </div>
          <div class="link-actions">
            <button type="button" class="secondary" phx-click="verify-chain">Verify Chain</button>
            <a class="action-pill" href={audit_export_href(@payload.filters)}>Export</a>
          </div>
        </div>

        <p :if={@verify_result} class={verify_result_class(@verify_result)}>
          <%= @verify_result.message %>
        </p>

        <p :if={@payload.error} class="ops-control-error">
          <%= @payload.error.code %>: <%= @payload.error.message %>
        </p>

        <%= if @payload.events == [] and is_nil(@payload.error) do %>
          <p class="empty-state">No audit events match the current filters.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table audit-table">
              <colgroup>
                <col style="width: 12rem;" />
                <col style="width: 10rem;" />
                <col style="width: 9rem;" />
                <col style="width: 11rem;" />
                <col />
              </colgroup>
              <thead>
                <tr>
                  <th>Timestamp</th>
                  <th>Type</th>
                  <th>Issue</th>
                  <th>Run</th>
                  <th>Payload</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={event <- @payload.events}>
                  <td class="mono"><%= event.timestamp || "n/a" %></td>
                  <td><span class="state-badge"><%= event.event_type || "unknown" %></span></td>
                  <td>
                    <div class="issue-stack">
                      <span class="issue-id"><%= event.issue || "n/a" %></span>
                      <.repo_chip repo={event.repo_key} />
                    </div>
                  </td>
                  <td class="mono"><%= short_id(event.run_id) %></td>
                  <td>
                    <div class="audit-preview"><%= event.preview %></div>
                    <details class="quality-reason-details audit-record-details">
                      <summary class="quality-reason-summary">Full record</summary>
                      <pre class="quality-reason-pre"><%= event.record_json %></pre>
                    </details>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  defp audit_export_href(filters) do
    filters
    |> Map.take([:repo, :issue, :event_type, :run_id, :date_from, :date_to, :since])
    |> Enum.flat_map(fn
      {_key, nil} -> []
      {:event_type, value} -> [{"type", value}]
      {:date_from, value} -> [{"from", value}]
      {:date_to, value} -> [{"to", value}]
      {:since, value} -> [{"since", value}]
      {key, value} -> [{Atom.to_string(key), value}]
    end)
    |> then(fn params ->
      params =
        if Map.get(filters, :since_last_poll?) do
          [{"since_last_poll", "1"} | params]
        else
          params
        end

      "/api/v1/audit?" <> URI.encode_query([{"download", "1"} | params])
    end)
  end

  defp repo_chip(assigns) do
    ~H"""
    <span :if={@repo} class="repo-chip" title={@repo} aria-label={"Repository #{@repo}"}>
      <span class="repo-chip-text"><%= @repo %></span>
    </span>
    """
  end

  defp blank?(value), do: is_nil(value) or value == ""

  defp short_id(id) when is_binary(id), do: if(byte_size(id) > 12, do: String.slice(id, 0, 12) <> "...", else: id)
  defp short_id(_id), do: "n/a"

  defp verify_result_class(%{status: :ok}), do: "audit-verify-result audit-verify-ok"
  defp verify_result_class(_result), do: "audit-verify-result audit-verify-error"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
