defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, URLUtils}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000
  @default_control_confirm_timeout_ms 10_000
  @dashboard_pause_reason "Paused from dashboard"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:pending_control, nil)
      |> assign(:pending_control_token, nil)
      |> assign(:control_error, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  def handle_info({:observability_updated, %{repo_key: repo_key}}, socket) do
    if matching_repo_key?(repo_key) do
      reload_dashboard(socket)
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    reload_dashboard(socket)
  end

  def handle_info({:disarm_control, token}, %{assigns: %{pending_control_token: token}} = socket) do
    {:noreply, disarm_control(socket)}
  end

  def handle_info({:disarm_control, _token}, socket), do: {:noreply, socket}

  defp reload_dashboard(socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:control_error, nil)
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("arm-pause", _params, socket) do
    {:noreply, arm_control(socket, :pause)}
  end

  def handle_event("pause-dispatch", _params, socket) do
    result = SymphonyElixir.Orchestrator.pause_dispatch(orchestrator(), @dashboard_pause_reason)
    {:noreply, reload_after_control(socket, result)}
  end

  def handle_event("arm-resume", _params, socket) do
    {:noreply, arm_control(socket, :resume)}
  end

  def handle_event("resume-dispatch", _params, socket) do
    result = SymphonyElixir.Orchestrator.resume_dispatch(orchestrator())
    {:noreply, reload_after_control(socket, result)}
  end

  def handle_event("arm-stop", %{"issue-id" => issue_id}, socket) do
    {:noreply, arm_control(socket, {:stop, issue_id})}
  end

  def handle_event("stop-running", %{"issue-id" => issue_id}, socket) do
    result = SymphonyElixir.Orchestrator.stop_running(orchestrator(), issue_id)
    {:noreply, reload_after_control(socket, result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
            <a class="action-pill" href="/quality">Quality Dashboard →</a>
            <a class="action-pill" href="/learnings">Learnings →</a>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class={["ops-control-card", !@payload.dispatch_state.active? && "ops-control-card-paused"]}>
          <div class="ops-control-main">
            <div class="ops-control-copy">
              <span class={if @payload.dispatch_state.active?, do: "state-badge state-badge-active", else: "state-badge state-badge-warning"}>
                Dispatch <%= if @payload.dispatch_state.active?, do: "active", else: "paused" %>
              </span>
              <%= if !@payload.dispatch_state.active? do %>
                <ul class="ops-control-blockers">
                  <%= for blocker <- @payload.dispatch_state.blockers do %>
                    <li class={"ops-control-blocker ops-control-blocker-#{blocker.kind}"}>
                      <strong><%= blocker_label(blocker) %></strong>
                      <span class="muted"><%= blocker_detail(blocker) %></span>
                    </li>
                  <% end %>
                </ul>
              <% end %>
              <%= if @control_error do %>
                <p class="ops-control-error"><%= @control_error %></p>
              <% end %>
            </div>

            <div class="ops-control-actions">
              <%= if @payload.pause.paused do %>
                <%= if @pending_control == :resume do %>
                  <button type="button" phx-click="resume-dispatch">Confirm Resume</button>
                <% else %>
                  <button type="button" class="secondary" phx-click="arm-resume">Resume Dispatch</button>
                <% end %>
              <% else %>
                <%= if @pending_control == :pause do %>
                  <button type="button" class="danger-button" phx-click="pause-dispatch">Confirm Pause</button>
                <% else %>
                  <button type="button" class="secondary pause-dispatch-button" phx-click="arm-pause">Pause Dispatch</button>
                <% end %>
              <% end %>
            </div>
          </div>
        </section>

        <section class="metric-grid dashboard-metrics">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">active</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Watching</p>
            <p class="metric-value numeric"><%= @payload.counts.watching %></p>
            <p class="metric-detail">waiting</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">backoff</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_compact_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              <%= format_compact_int(@payload.codex_totals.input_tokens) %> in / <%= format_compact_int(@payload.codex_totals.output_tokens) %> out
            </p>
            <p class="metric-detail numeric">
              <%= format_compact_int(@payload.codex_totals.uncached_input_tokens) %> uncached / <%= format_compact_int(@payload.codex_totals.cached_input_tokens) %> cached
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Daily tokens</p>
            <p class="metric-value numeric"><%= format_budget_usage(@payload.budget.daily_used, @payload.budget.daily_limit) %></p>
            <p class="metric-detail"><%= daily_budget_detail(@payload.budget) %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Issue budget</p>
            <p class="metric-value numeric"><%= format_budget_limit(@payload.budget.per_issue_limit) %></p>
            <p class="metric-detail">per issue</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">completed + active</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Rate limits</h2>
              <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Running sessions</h2>
              <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
            </div>
          </div>

          <%= if @payload.running == [] do %>
            <p class="empty-state">No active sessions.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-running">
                <colgroup>
                  <col style="width: 9rem;" />
                  <col style="width: 7.5rem;" />
                  <col style="width: 7rem;" />
                  <col style="width: 8rem;" />
                  <col />
                  <col style="width: 9rem;" />
                  <col style="width: 6.5rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 7rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Session</th>
                    <th>Runtime / turns</th>
                    <th>Codex update</th>
                    <th>Tokens</th>
                    <th>Self-review</th>
                    <th>Links</th>
                    <th>Control</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.running}>
                    <td>
                      <div class="issue-stack">
                        <%= if entry.url do %>
                          <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer"><%= entry.issue_identifier %></a>
                        <% else %>
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td>
                      <div class="session-stack">
                        <%= if entry.session_id do %>
                          <button
                            type="button"
                            class="subtle-button session-copy-btn"
                            aria-label="Copy ID"
                            data-label={String.slice(entry.session_id, 0, 8) <> "…"}
                            data-copy={entry.session_id}
                            title={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied ✓'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1400);"
                          >
                            <%= String.slice(entry.session_id, 0, 8) %>…
                          </button>
                        <% else %>
                          <span class="muted">—</span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                    <td>
                      <div class="detail-stack">
                        <span
                          class="event-text"
                          title={entry.last_message || to_string(entry.last_event || "n/a")}
                        ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                        <span class="muted event-meta">
                          <%= if entry.last_event_at do %>
                            <span class="numeric"><%= format_event_at(entry.last_event_at, @now) %></span>
                          <% end %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="token-stack numeric">
                        <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                        <%= if issue_budget_limited?(@payload.budget.per_issue_limit) do %>
                          <span class="muted">Budget: <%= format_issue_budget_remaining(entry.tokens.total_tokens, @payload.budget.per_issue_limit) %> left</span>
                        <% end %>
                        <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                        <span class="muted">Uncached <%= format_int(entry.tokens.uncached_input_tokens) %> / Cached <%= format_int(entry.tokens.cached_input_tokens) %></span>
                      </div>
                    </td>
                    <td>
                      <%= if entry.self_review do %>
                        <span class={self_review_badge_class(entry.self_review)} title={self_review_badge_title(entry.self_review)}>
                          <%= self_review_badge_label(entry.self_review) %>
                        </span>
                        <%= if entry.self_review.round == 2 do %>
                          <p class="muted event-meta">after correction</p>
                        <% end %>
                      <% else %>
                        <span class="muted">—</span>
                      <% end %>
                    </td>
                    <td class="links-cell">
                      <div class="link-actions">
                        <a class="action-pill" href={transcript_path(entry)}>Transcript</a>
                        <a class="action-pill" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                      </div>
                    </td>
                    <td class="links-cell">
                      <%= if pending_stop?(@pending_control, entry.issue_id) do %>
                        <button
                          type="button"
                          class="subtle-button danger-subtle-button"
                          phx-click="stop-running"
                          phx-value-issue-id={entry.issue_id}
                        >
                          Confirm Stop
                        </button>
                      <% else %>
                        <button
                          type="button"
                          class="subtle-button danger-subtle-button"
                          phx-click="arm-stop"
                          phx-value-issue-id={entry.issue_id}
                        >
                          Stop
                        </button>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Watching</h2>
              <p class="section-copy">Recently handled issues waiting outside active and terminal workflow states.</p>
            </div>
          </div>

          <%= if @payload.watching == [] do %>
            <p class="empty-state">No watched issues.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-watching">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 9rem;" />
                  <col style="width: 13rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>State</th>
                    <th>Last run</th>
                    <th>Links</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.watching}>
                    <td>
                      <div class="issue-stack">
                        <%= if entry.url do %>
                          <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer"><%= entry.issue_identifier %></a>
                        <% else %>
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(entry.state)}>
                        <%= entry.state %>
                      </span>
                    </td>
                    <td class="numeric"><%= format_last_run(entry, @now) %></td>
                    <td class="links-cell">
                      <div class="link-actions">
                        <%= if entry.pull_request_url do %>
                          <a class="action-pill" href={entry.pull_request_url} target="_blank" rel="noreferrer">PR</a>
                        <% end %>
                        <a class="action-pill" href={transcript_path(entry)}>Transcript</a>
                        <a class="action-pill" href={"/api/v1/#{entry.issue_identifier}"}>JSON</a>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Retry queue</h2>
              <p class="section-copy">Issues waiting for the next retry window.</p>
            </div>
          </div>

          <%= if @payload.retrying == [] do %>
            <p class="empty-state">No queued retries</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 680px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Attempt</th>
                    <th>Due at</th>
                    <th>Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.retrying}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                      </div>
                    </td>
                    <td><%= entry.attempt %></td>
                    <td class="mono"><%= entry.due_at || "n/a" %></td>
                    <td><%= entry.error || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Awaiting clarification</h2>
              <p class="section-copy">Quality-gate holds waiting for clearer issue context.</p>
            </div>
          </div>

          <%= if @payload.awaiting_clarification == [] do %>
            <p class="empty-state">No issues awaiting clarification</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-quality">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 7rem;" />
                  <col style="width: 7rem;" />
                  <col />
                  <col style="width: 12rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Round</th>
                    <th>Score</th>
                    <th>Reason</th>
                    <th>Updated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.awaiting_clarification}>
                    <td>
                      <%= if entry.url do %>
                        <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer"><%= entry.issue_identifier %></a>
                      <% else %>
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                      <% end %>
                    </td>
                    <td class="numeric"><%= format_optional_int(entry.rounds_asked) %></td>
                    <td class="numeric"><%= format_optional_int(entry.score) %></td>
                    <td>
                      <span class="event-text" title={entry.reason || "n/a"}><%= entry.reason || "n/a" %></span>
                    </td>
                    <td class="mono"><%= entry.updated_at || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Skipped (quality gate)</h2>
              <p class="section-copy">Issues rejected by the quality gate before dispatch.</p>
            </div>
          </div>

          <%= if @payload.skipped == [] do %>
            <p class="empty-state">No issues skipped this session</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-quality">
                <colgroup>
                  <col style="width: 12rem;" />
                  <col style="width: 8rem;" />
                  <col style="width: 7rem;" />
                  <col />
                  <col style="width: 12rem;" />
                </colgroup>
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Result</th>
                    <th>Score</th>
                    <th>Detail</th>
                    <th>Updated</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={entry <- @payload.skipped}>
                    <td>
                      <%= if entry.url do %>
                        <a class="issue-id" href={entry.url} target="_blank" rel="noreferrer"><%= entry.issue_identifier %></a>
                      <% else %>
                        <span class="issue-id"><%= entry.issue_identifier %></span>
                      <% end %>
                    </td>
                    <td>
                      <span class={quality_gate_badge_class(entry)}>
                        <%= quality_gate_kind_label(entry) %>
                      </span>
                    </td>
                    <td class="numeric"><%= format_optional_int(entry.score) %></td>
                    <td>
                      <span class="event-text" title={quality_gate_detail(entry)}>
                        <%= quality_gate_detail(entry) %>
                      </span>
                    </td>
                    <td class="mono"><%= entry.updated_at || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp reload_after_control(socket, result) do
    socket
    |> assign(:payload, load_payload())
    |> disarm_control()
    |> assign(:control_error, control_error(result))
  end

  defp arm_control(socket, control) do
    token = make_ref()
    Process.send_after(self(), {:disarm_control, token}, control_confirm_timeout_ms())

    socket
    |> assign(:pending_control, control)
    |> assign(:pending_control_token, token)
  end

  defp disarm_control(socket) do
    socket
    |> assign(:pending_control, nil)
    |> assign(:pending_control_token, nil)
  end

  defp control_error({:ok, _payload}), do: nil
  defp control_error(:unavailable), do: "Orchestrator unavailable"
  defp control_error({:error, reason}), do: "Control failed: #{inspect(reason)}"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp control_confirm_timeout_ms do
    Application.get_env(:symphony_elixir, :dashboard_control_confirm_timeout_ms, @default_control_confirm_timeout_ms)
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_last_run(%{last_ran_at: last_ran_at}, now) do
    case seconds_since(last_ran_at, now) do
      seconds when is_integer(seconds) -> format_ago(seconds)
      _ -> "n/a"
    end
  end

  defp format_last_run(%{seconds_since_last_run: seconds}, _now) when is_integer(seconds) do
    format_ago(seconds)
  end

  defp format_last_run(_entry, _now), do: "n/a"

  defp seconds_since(timestamp, %DateTime{} = now) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> DateTime.diff(now, parsed, :second) |> max(0)
      _ -> nil
    end
  end

  defp seconds_since(_timestamp, _now), do: nil

  defp format_ago(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp format_ago(_seconds), do: "n/a"

  defp format_event_at(nil, _now), do: nil

  defp format_event_at(timestamp, now) when is_binary(timestamp) do
    case seconds_since(timestamp, now) do
      seconds when is_integer(seconds) -> format_ago(seconds)
      _ -> String.slice(timestamp, 11, 8)
    end
  end

  defp format_event_at(_timestamp, _now), do: nil

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_budget_usage(used, limit) when is_integer(limit) and limit > 0 do
    "#{format_compact_int(used)} / #{format_compact_int(limit)}"
  end

  defp format_budget_usage(used, _limit), do: format_compact_int(used)

  defp format_budget_limit(limit) when is_integer(limit) and limit > 0, do: format_compact_int(limit)
  defp format_budget_limit(_limit), do: "Unlimited"

  defp issue_budget_limited?(limit), do: is_integer(limit) and limit > 0

  defp format_issue_budget_remaining(used, limit) when is_integer(used) and is_integer(limit) and limit > 0 do
    limit
    |> Kernel.-(max(used, 0))
    |> max(0)
    |> format_compact_int()
  end

  defp format_issue_budget_remaining(_used, _limit), do: "n/a"

  defp daily_budget_detail(%{daily_paused: true}), do: "paused"

  defp daily_budget_detail(%{daily_remaining: remaining}) when is_integer(remaining) do
    "#{format_compact_int(remaining)} left"
  end

  defp daily_budget_detail(_budget), do: "no limit"

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp format_compact_int(value) when is_integer(value) do
    abs_value = abs(value)

    cond do
      abs_value >= 1_000_000_000 -> format_compact_number(value, 1_000_000_000, "B")
      abs_value >= 1_000_000 -> format_compact_number(value, 1_000_000, "M")
      abs_value >= 1_000 -> format_compact_number(value, 1_000, "K")
      true -> Integer.to_string(value)
    end
  end

  defp format_compact_int(_value), do: "n/a"

  defp blocker_label(%{kind: :manual}), do: "Manually paused"
  defp blocker_label(%{kind: :budget}), do: "Daily token budget exhausted"

  defp blocker_label(%{kind: :missing_api_key, provider: provider}),
    do: "Missing #{provider |> to_string() |> String.upcase()} API key"

  defp blocker_detail(%{kind: :manual, reason: reason, since: since}) do
    [reason, since && "since #{since}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" — ")
  end

  defp blocker_detail(%{kind: :budget, used: used, limit: limit, resets_on: resets_on}) do
    "#{format_compact_int(used)} / #{format_compact_int(limit)} (resets #{resets_on})"
  end

  defp blocker_detail(%{kind: :missing_api_key}),
    do: "set the env var and restart symphony"

  defp format_compact_number(value, divisor, suffix) do
    value
    |> Kernel./(divisor)
    |> :erlang.float_to_binary(decimals: 1)
    |> trim_trailing_decimal_zero()
    |> Kernel.<>(suffix)
  end

  defp trim_trailing_decimal_zero(value) do
    String.replace_suffix(value, ".0", "")
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp self_review_badge_class(%{fail_open_category: category}) when is_binary(category),
    do: "state-badge state-badge-warning"

  defp self_review_badge_class(%{verdict: "request_changes"}),
    do: "state-badge state-badge-danger"

  defp self_review_badge_class(%{verdict: "approve"}),
    do: "state-badge state-badge-active"

  defp self_review_badge_class(_), do: "state-badge"

  defp self_review_badge_label(%{fail_open_category: category}) when is_binary(category),
    do: "Fail-open"

  defp self_review_badge_label(%{verdict: "request_changes", findings_count: count}),
    do: "#{count} finding#{if count == 1, do: "", else: "s"}"

  defp self_review_badge_label(%{verdict: "approve"}), do: "Approved"
  defp self_review_badge_label(_), do: "—"

  defp self_review_badge_title(%{fail_open_category: category}) when is_binary(category),
    do: "Self-review fell open: #{category}"

  defp self_review_badge_title(%{verdict: "request_changes", finding_categories: categories}) do
    "Blocking findings: " <> Enum.join(categories || [], ", ")
  end

  defp self_review_badge_title(%{verdict: "approve"}), do: "Self-review approved"
  defp self_review_badge_title(_), do: ""

  defp format_optional_int(value) when is_integer(value), do: Integer.to_string(value)
  defp format_optional_int(_value), do: "n/a"

  defp quality_gate_badge_class(%{kind: "error"}), do: "state-badge state-badge-danger"
  defp quality_gate_badge_class(_entry), do: "state-badge state-badge-warning"

  defp quality_gate_kind_label(%{kind: "error"}), do: "Error"
  defp quality_gate_kind_label(%{kind: "scored"}), do: "Scored"
  defp quality_gate_kind_label(%{kind: kind}) when is_binary(kind), do: String.capitalize(kind)
  defp quality_gate_kind_label(_entry), do: "Skipped"

  defp quality_gate_detail(%{kind: "error", error: error}) when is_binary(error) and error != "", do: error
  defp quality_gate_detail(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp quality_gate_detail(_entry), do: "n/a"

  defp pending_stop?({:stop, issue_id}, issue_id), do: true
  defp pending_stop?(_pending_control, _issue_id), do: false

  defp transcript_path(entry) do
    URLUtils.transcript_path(Map.get(entry, :repo_key) || current_repo_key(), Map.get(entry, :issue_identifier)) || "#"
  end

  defp matching_repo_key?(nil), do: true
  defp matching_repo_key?(repo_key), do: repo_key == current_repo_key()

  defp current_repo_key do
    case Config.repo_key() do
      {:ok, repo_key} -> repo_key
      {:error, _reason} -> nil
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
