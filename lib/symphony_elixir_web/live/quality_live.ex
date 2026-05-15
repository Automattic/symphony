defmodule SymphonyElixirWeb.QualityLive do
  @moduledoc """
  Live quality dashboard for structured agent eval logs.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Quality

  @default_date_from_days 30

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = Map.put_new(params, "date_from", default_date_from())
    {:noreply, assign(socket, :payload, Quality.dashboard_payload(params))}
  end

  defp default_date_from do
    Date.utc_today() |> Date.add(-@default_date_from_days) |> Date.to_iso8601()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell quality-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony Quality</p>
            <h1 class="hero-title">Quality Dashboard</h1>
            <p class="hero-copy">Agent run outcomes, context signals, token spend, and run-level quality evidence.</p>
          </div>

          <div class="status-stack">
            <a class="action-pill hero-action" href="/">Dashboard</a>
            <a class="action-pill hero-action" href="/learnings">Learnings</a>
            <a class="action-pill hero-action" href={runs_export_href(@payload.filters)}>JSON</a>
          </div>
        </div>
      </header>

      <section class="metric-grid dashboard-metrics quality-metrics">
        <article class="metric-card">
          <p class="metric-label">PR-opened rate</p>
          <p class="metric-value numeric"><%= format_rate(@payload.metrics.pr_opened_rate) %></p>
          <p class="metric-detail"><%= @payload.metrics.total_runs %> runs</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Avg tokens</p>
          <p class="metric-value numeric"><%= format_number(@payload.metrics.avg_tokens) %></p>
          <p class="metric-detail">total per run</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Tests-run rate</p>
          <p class="metric-value numeric"><%= format_rate(@payload.metrics.tests_run_rate) %></p>
          <p class="metric-detail">when applicable</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Error rate</p>
          <p class="metric-value numeric"><%= format_rate(@payload.metrics.error_rate) %></p>
          <p class="metric-detail">terminal runs</p>
        </article>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Filters</h2>
          </div>
        </div>

        <form class="quality-filter-form" method="get" action="/quality">
          <label class="quality-field">
            <span>Agent</span>
            <select name="agent">
              <option value="" selected={blank?(@payload.filters.agent_kind)}>All</option>
              <option value="codex" selected={@payload.filters.agent_kind == "codex"}>codex</option>
              <option value="claude" selected={@payload.filters.agent_kind == "claude"}>claude</option>
            </select>
          </label>

          <label class="quality-field">
            <span>Outcome</span>
            <select name="outcome">
              <option value="" selected={blank?(@payload.filters.outcome)}>All</option>
              <option value="pr_opened" selected={@payload.filters.outcome == "pr_opened"}>PR opened</option>
              <option value="no_changes" selected={@payload.filters.outcome == "no_changes"}>No changes</option>
              <option value="error" selected={@payload.filters.outcome == "error"}>Error</option>
            </select>
          </label>

          <label class="quality-field">
            <span>From</span>
            <input type="date" name="date_from" value={@payload.filters.date_from || ""} />
          </label>

          <label class="quality-field">
            <span>To</span>
            <input type="date" name="date_to" value={@payload.filters.date_to || ""} />
          </label>

          <button type="submit" class="quality-submit">Apply</button>
        </form>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Recent Runs</h2>
            <p class="section-copy">Last 50 matching eval logs.</p>
          </div>
        </div>

        <%= if @payload.runs == [] do %>
          <p class="empty-state">No quality eval logs match the current filters.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table quality-table">
              <colgroup>
                <col style="width: 10rem;" />
                <col style="width: 9rem;" />
                <col style="width: 11rem;" />
                <col style="width: 7rem;" />
                <col style="width: 9rem;" />
                <col style="width: 8rem;" />
                <col style="width: 8rem;" />
                <col style="width: 8rem;" />
              </colgroup>
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Outcome</th>
                  <th>Status</th>
                  <th>Agent</th>
                  <th>Tokens</th>
                  <th>Tests run</th>
                  <th>Duration</th>
                  <th>Date</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @payload.runs}>
                  <td>
                    <div class="issue-stack">
                      <span class="issue-id"><%= entry.issue_identifier || "n/a" %></span>
                      <span :if={entry.session_id} class="muted mono"><%= short_id(entry.session_id) %></span>
                    </div>
                  </td>
                  <td>
                    <span class={outcome_badge_class(entry.outcome)}><%= outcome_label(entry.outcome) %></span>
                  </td>
                  <td>
                    <span class={status_badge_class(entry.status)}><%= status_label(entry.status) %></span>
                    <span :if={entry.error} class="quality-reason" title={entry.error}><%= entry.error %></span>
                  </td>
                  <td><%= entry.agent_kind || "unknown" %></td>
                  <td class="numeric">
                    <div><%= format_int(get_in(entry, [:tokens, :total_tokens])) %></div>
                    <div class="muted token-breakdown">
                      uncached <%= format_int(get_in(entry, [:tokens, :uncached_input_tokens])) %> /
                      cached <%= format_int(get_in(entry, [:tokens, :cached_input_tokens])) %>
                    </div>
                  </td>
                  <td><%= tests_run_label(entry.tests_run) %></td>
                  <td class="numeric"><%= format_duration(entry.duration_seconds) %></td>
                  <td class="numeric"><%= entry.date || "n/a" %></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    </section>
    """
  end

  defp runs_export_href(filters) do
    query =
      filters
      |> Map.take([:agent_kind, :outcome, :date_from, :date_to])
      |> Enum.flat_map(fn
        {_key, nil} -> []
        {:agent_kind, value} -> [{"agent", value}]
        {key, value} -> [{Atom.to_string(key), value}]
      end)
      |> then(&URI.encode_query([{"export", "json"} | &1]))

    "/api/v1/runs?#{query}"
  end

  defp blank?(value), do: is_nil(value) or value == ""

  defp outcome_badge_class("pr_opened"), do: "state-badge state-badge-active"
  defp outcome_badge_class("error"), do: "state-badge state-badge-danger"
  defp outcome_badge_class("no_changes"), do: "state-badge state-badge-warning"
  defp outcome_badge_class(_outcome), do: "state-badge"

  defp outcome_label("pr_opened"), do: "PR opened"
  defp outcome_label("no_changes"), do: "No changes"
  defp outcome_label("error"), do: "Error"
  defp outcome_label(outcome) when is_binary(outcome), do: outcome
  defp outcome_label(_outcome), do: "Unknown"

  defp status_badge_class("success"), do: "state-badge state-badge-success"
  defp status_badge_class("timeout"), do: "state-badge state-badge-warning"
  defp status_badge_class("budget_exhausted"), do: "state-badge state-badge-warning"
  defp status_badge_class("failure"), do: "state-badge state-badge-danger"
  defp status_badge_class(_status), do: "state-badge"

  defp status_label("budget_exhausted"), do: "Budget exhausted"

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label(_status), do: "Unknown"

  defp tests_run_label(true), do: "Yes"
  defp tests_run_label(false), do: "No"
  defp tests_run_label(_value), do: "n/a"

  defp format_rate(nil), do: "n/a"
  defp format_rate(rate) when is_number(rate), do: "#{round(rate * 100)}%"

  defp format_number(nil), do: "n/a"
  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_int(value) when is_integer(value), do: Integer.to_string(value)
  defp format_int(_value), do: "0"

  defp format_duration(seconds) when is_integer(seconds), do: "#{seconds}s"
  defp format_duration(_seconds), do: "0s"

  defp short_id(id) when is_binary(id) and byte_size(id) > 12, do: String.slice(id, 0, 12) <> "..."
  defp short_id(id) when is_binary(id), do: id
  defp short_id(_id), do: "n/a"
end
