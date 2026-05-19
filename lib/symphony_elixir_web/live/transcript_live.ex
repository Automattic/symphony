defmodule SymphonyElixirWeb.TranscriptLive do
  @moduledoc """
  Live transcript stream for a single running Symphony issue.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  require Logger

  alias SymphonyElixir.{Config, StatusDashboard}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @raw_limit 2_400
  @summary_limit 600
  @error_messages %{
    issue_not_found: "No running issue matched this identifier.",
    snapshot_unavailable: "The orchestrator snapshot is unavailable."
  }

  @impl true
  def mount(%{"identifier" => issue_identifier} = params, _session, socket) do
    repo_key = Map.get(params, "repo_key") || current_repo_key()
    payload = Presenter.transcript_payload(repo_key, issue_identifier, orchestrator(), snapshot_timeout_ms())

    socket =
      case payload do
        {:ok, payload} ->
          {entries, last_agent_text_entry, last_command_progress_entry, next_seq} = coalesce_entries(payload.events)

          socket
          |> assign(:error, nil)
          |> assign(:issue, payload)
          |> assign(:repo_key, payload.repo_key)
          |> assign(:issue_id, payload.issue_id)
          |> assign(:issue_identifier, payload.issue_identifier)
          |> assign(:event_count, length(entries))
          |> assign(:next_sequence, next_seq)
          |> assign(:last_agent_text_entry, last_agent_text_entry)
          |> assign(:last_command_progress_entry, last_command_progress_entry)
          |> stream(:events, entries)

        {:error, reason} ->
          socket
          |> assign(:error, error_message(reason))
          |> assign(:issue, nil)
          |> assign(:repo_key, repo_key)
          |> assign(:issue_id, nil)
          |> assign(:issue_identifier, issue_identifier)
          |> assign(:event_count, 0)
          |> assign(:next_sequence, 1)
          |> assign(:last_agent_text_entry, nil)
          |> assign(:last_command_progress_entry, nil)
          |> stream(:events, [])
      end

    if connected?(socket) and is_nil(socket.assigns.error) do
      subscribe_transcript()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info({:transcript_event, %{repo_key: repo_key, issue_id: issue_id} = event}, socket) do
    if repo_key == socket.assigns.repo_key and issue_id == socket.assigns.issue_id do
      handle_transcript_event(event, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_info({:transcript_event, event}, socket) when is_map(event) do
    handle_transcript_event(event, socket)
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp handle_transcript_event(event, socket) do
    kind = event_kind(event)
    last = socket.assigns.last_agent_text_entry
    last_progress = socket.assigns.last_command_progress_entry

    cond do
      kind == "agent-text" and not is_nil(last) ->
        new_text = agent_text(event) || ""
        merged = %{last | summary: last.summary <> new_text}

        {:noreply,
         socket
         |> assign(:last_agent_text_entry, merged)
         |> assign(:last_command_progress_entry, nil)
         |> stream_insert(:events, merged)}

      command_progress_event?(event) and not is_nil(last_progress) ->
        merged = merge_command_progress_entry(last_progress, event)

        {:noreply,
         socket
         |> assign(:last_agent_text_entry, nil)
         |> assign(:last_command_progress_entry, merged)
         |> stream_insert(:events, merged)}

      true ->
        sequence = socket.assigns.next_sequence
        entry = transcript_entry(event, sequence)
        last_agent = if kind == "agent-text", do: entry, else: nil
        last_progress = if command_progress_event?(event), do: entry, else: nil

        {:noreply,
         socket
         |> assign(:event_count, socket.assigns.event_count + 1)
         |> assign(:next_sequence, sequence + 1)
         |> assign(:last_agent_text_entry, last_agent)
         |> assign(:last_command_progress_entry, last_progress)
         |> stream_insert(:events, entry)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell transcript-shell">
      <header class="section-card transcript-header">
        <div>
          <p class="eyebrow">Live Transcript</p>
          <h1 class="section-title transcript-title"><%= @issue_identifier %></h1>
        </div>

        <a class="subtle-button transcript-back" href="/">Dashboard</a>
      </header>

      <%= if @error do %>
        <section class="error-card">
          <h2 class="error-title">Transcript unavailable</h2>
          <p class="error-copy"><%= @error %></p>
        </section>
      <% else %>
        <section class="metric-grid transcript-summary">
          <article class="metric-card">
            <p class="metric-label">State</p>
            <p class="metric-detail"><%= @issue.state %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Session</p>
            <p class="metric-detail mono"><%= @issue.session_id || "n/a" %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Turns</p>
            <p class="metric-value numeric"><%= @issue.turn_count %></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Tokens</p>
            <p class="metric-detail numeric">
              <%= format_int(@issue.tokens.total_tokens) %>
              <span class="muted">total</span>
            </p>
          </article>
        </section>

        <section id="transcript-card" class="section-card transcript-card" phx-hook="TranscriptFilter">
          <div class="section-header">
            <div>
              <h2 class="section-title">Events</h2>
              <p class="section-copy"><%= @event_count %> buffered and live events for this issue.</p>
            </div>

            <div class="transcript-filter-group" role="group" aria-label="Event type filters">
              <button type="button" class="transcript-filter-button" data-transcript-filter="all" aria-pressed="false">All</button>
              <button type="button" class="transcript-filter-button" data-transcript-filter="agent-text" aria-pressed="true">Agent</button>
              <button type="button" class="transcript-filter-button" data-transcript-filter="tool-call" aria-pressed="false">Tool call</button>
              <button type="button" class="transcript-filter-button" data-transcript-filter="tool-result" aria-pressed="false">Tool result</button>
              <button type="button" class="transcript-filter-button" data-transcript-filter="session" aria-pressed="false">Session</button>
              <button type="button" class="transcript-filter-button" data-transcript-filter="error" aria-pressed="true">Error</button>
              <button type="button" class="transcript-filter-button" data-transcript-filter="event" aria-pressed="false">Event</button>
            </div>
          </div>

          <%= if @event_count == 0 do %>
            <p class="empty-state">No transcript events have arrived yet.</p>
          <% end %>

          <div
            id="transcript-events"
            class="transcript-list"
            phx-update="stream"
            data-transcript-events=""
            data-filter-active="true"
            data-filter-agent-text="true"
            data-filter-error="true"
          >
            <article
              :for={{dom_id, entry} <- @streams.events}
              id={dom_id}
              class={"transcript-event transcript-event-#{entry.kind}"}
            >
              <div class="transcript-event-rail">
                <span class="transcript-event-index numeric"><%= entry.sequence %></span>
              </div>

              <div class="transcript-event-body">
                <div class="transcript-event-header">
                  <span class="transcript-event-kind"><%= entry.label %></span>
                  <span :if={entry.name not in ["notification", "unknown"]} class="transcript-event-name"><%= entry.name %></span>
                  <span :if={entry.timestamp} class="muted mono numeric"><%= entry.timestamp %></span>
                </div>

                <p class="transcript-event-summary"><%= entry.summary %></p>

                <details class="transcript-raw">
                  <summary>Raw event</summary>
                  <pre><%= entry.raw %></pre>
                </details>
              </div>
            </article>
          </div>
        </section>
      <% end %>
    </section>
    """
  end

  defp transcript_entry(event, sequence) do
    kind = event_kind(event)
    progress_count = command_progress_dot_count(event)

    %{
      id: "event-#{sequence}",
      sequence: sequence,
      kind: kind,
      label: event_label(kind),
      name: event_name(event),
      timestamp: event_timestamp(event),
      summary: progress_summary(progress_count) || event_summary(event, kind),
      progress_count: progress_count,
      raw: event |> inspect(pretty: true, limit: :infinity) |> truncate(@raw_limit)
    }
  end

  defp event_kind(event) do
    event_text = event_name(event) |> String.downcase()
    method = event_method(event) |> downcase_value()
    item_type = event_item_type(event) |> downcase_value()

    cond do
      error_event?(event_text, method) ->
        "error"

      tool_result_event?(event_text, method, item_type) ->
        "tool-result"

      tool_call_event?(method, item_type) ->
        "tool-call"

      agent_text_event?(method) ->
        "agent-text"

      session_event?(event_text, method) ->
        "session"

      true ->
        "event"
    end
  end

  defp event_label("agent-text"), do: "Agent"
  defp event_label("tool-call"), do: "Tool call"
  defp event_label("tool-result"), do: "Tool result"
  defp event_label("session"), do: "Session"
  defp event_label("error"), do: "Error"
  defp event_label(_kind), do: "Event"

  defp error_event?(event_text, method) do
    String.contains?(event_text, "error") or String.contains?(event_text, "failed") or
      String.contains?(method, "error") or String.contains?(method, "failed") or
      event_text in ["tool_call_failed", "unsupported_tool_call"]
  end

  defp tool_result_event?(event_text, method, item_type) do
    event_text in ["tool_call_completed", "tool_result"] or
      String.ends_with?(method, "tool_call_end") or
      String.contains?(method, "item/tool/result") or
      (method in ["item/completed"] and item_type in ["commandexecution", "filechange"]) or
      String.contains?(method, "exec_command_end") or String.contains?(method, "output_delta") or
      String.contains?(method, "outputdelta")
  end

  defp tool_call_event?(method, item_type) do
    String.contains?(method, "item/tool/call") or String.ends_with?(method, "tool_call_begin") or
      String.contains?(method, "exec_command_begin") or String.contains?(method, "commandexecution/requestapproval") or
      String.contains?(method, "filechange/requestapproval") or String.contains?(method, "tool/requestuserinput") or
      (method in ["item/started"] and item_type in ["commandexecution", "filechange"])
  end

  defp agent_text_event?(method) do
    String.contains?(method, "agent_message") or String.contains?(method, "agentmessage")
  end

  defp session_event?(event_text, method) do
    String.contains?(event_text, "session") or String.contains?(event_text, "turn") or
      String.contains?(method, "token_count") or String.contains?(method, "tokenusage") or
      String.starts_with?(method, "thread/") or String.starts_with?(method, "turn/")
  end

  defp event_name(event) do
    event
    |> map_value(["event", :event])
    |> case do
      nil -> event_method(event) || "unknown"
      name -> to_string(name)
    end
  end

  defp event_summary(event, "tool-call") do
    name = tool_name(event)
    args = tool_arguments(event)

    cond do
      is_binary(name) and args != nil -> "#{name} #{inline_inspect(args)}"
      is_binary(name) -> name
      true -> humanized_summary(event)
    end
  end

  defp event_summary(event, "agent-text") do
    agent_text(event) || humanized_summary(event)
  end

  defp event_summary(event, "tool-result") do
    case tool_result_text(event) do
      nil -> humanized_summary(event)
      text -> truncate(text, @summary_limit)
    end
  end

  defp event_summary(event, _kind), do: humanized_summary(event)

  defp tool_result_text(event) do
    map_path(event, [:payload, "params", "text"]) ||
      map_path(event, [:payload, :params, :text]) ||
      map_path(event, [:payload, "params", :text]) ||
      map_path(event, [:payload, :params, "text"]) ||
      map_path(event, ["payload", "params", "text"])
  end

  defp humanized_summary(event) do
    event
    |> summarize_for_status_dashboard()
    |> StatusDashboard.humanize_codex_message()
    |> truncate(@summary_limit)
  end

  defp summarize_for_status_dashboard(event) do
    %{
      event: map_value(event, ["event", :event]),
      message: map_value(event, ["payload", :payload]) || map_value(event, ["raw", :raw]) || event,
      timestamp: map_value(event, ["timestamp", :timestamp])
    }
  end

  defp event_timestamp(event) do
    case map_value(event, ["timestamp", :timestamp]) do
      %DateTime{} = datetime -> datetime |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 8)
      timestamp when is_binary(timestamp) -> String.slice(timestamp, 11, 8)
      _ -> nil
    end
  end

  defp event_method(event) do
    map_path(event, [:payload, "method"]) ||
      map_path(event, [:payload, :method]) ||
      map_path(event, [:payload, :payload, "method"]) ||
      map_path(event, [:payload, :payload, :method]) ||
      map_path(event, [:payload, "payload", "method"]) ||
      map_path(event, [:payload, "payload", :method]) ||
      map_path(event, ["payload", "method"]) ||
      map_path(event, ["payload", "payload", "method"])
  end

  defp event_item_type(event) do
    item =
      map_path(event, [:payload, "params", "item"]) ||
        map_path(event, [:payload, :params, :item]) ||
        map_path(event, ["payload", "params", "item"]) ||
        map_path(event, [:payload, "payload", "params", "item"]) ||
        map_path(event, [:payload, :payload, "params", "item"])

    map_value(item, ["type", :type])
  end

  defp tool_name(event) do
    tool_params(event)
    |> case do
      nil -> nil
      params -> map_value(params, ["tool", :tool, "name", :name])
    end
  end

  defp tool_arguments(event) do
    tool_params(event)
    |> case do
      nil -> nil
      params -> map_value(params, ["arguments", :arguments])
    end
  end

  defp tool_params(event) do
    map_path(event, [:payload, "params"]) ||
      map_path(event, [:payload, :params]) ||
      map_path(event, [:payload, :payload, "params"]) ||
      map_path(event, [:payload, :payload, :params]) ||
      map_path(event, [:payload, "payload", "params"]) ||
      map_path(event, [:payload, "payload", :params]) ||
      map_path(event, ["payload", "params"]) ||
      map_path(event, ["payload", "payload", "params"])
  end

  defp agent_text(event) do
    map_path(event, [:payload, "params", "msg", "content"]) ||
      map_path(event, [:payload, :params, :msg, :content]) ||
      map_path(event, [:payload, "params", "delta"]) ||
      map_path(event, [:payload, :params, :delta]) ||
      map_path(event, [:payload, "payload", "params", "msg", "content"]) ||
      map_path(event, [:payload, :payload, "params", "msg", "content"])
  end

  defp command_progress_event?(event), do: is_integer(command_progress_dot_count(event))

  defp merge_command_progress_entry(entry, event) do
    progress_count = Map.get(entry, :progress_count, 0) + command_progress_dot_count(event)

    %{entry | progress_count: progress_count, summary: progress_summary(progress_count)}
  end

  defp command_progress_dot_count(event) do
    method = event_method(event) |> downcase_value()

    if command_output_delta_method?(method) do
      event
      |> command_output_delta()
      |> dot_progress_count()
    end
  end

  defp command_output_delta_method?("item/commandexecution/outputdelta"), do: true
  defp command_output_delta_method?("exec_command_output_delta"), do: true
  defp command_output_delta_method?(method), do: String.contains?(method, "commandexecution/outputdelta")

  defp command_output_delta(event) do
    map_path(event, [:payload, "params", "outputDelta"]) ||
      map_path(event, [:payload, :params, :outputDelta]) ||
      map_path(event, [:payload, "payload", "params", "outputDelta"]) ||
      map_path(event, [:payload, :payload, "params", "outputDelta"]) ||
      map_path(event, ["payload", "params", "outputDelta"]) ||
      map_path(event, ["payload", "payload", "params", "outputDelta"])
  end

  defp dot_progress_count(value) when is_binary(value) do
    compact = String.replace(value, ~r/\s+/, "")

    if compact != "" and String.match?(compact, ~r/^\.+$/) do
      String.length(compact)
    end
  end

  defp dot_progress_count(_value), do: nil

  defp progress_summary(nil), do: nil
  defp progress_summary(1), do: "command output streaming: 1 progress dot"
  defp progress_summary(count), do: "command output streaming: #{count} progress dots"

  defp inline_inspect(value) do
    value
    |> inspect(pretty: false, limit: 20)
    |> truncate(220)
  end

  defp downcase_value(value) when is_binary(value), do: String.downcase(value)
  defp downcase_value(value) when is_atom(value), do: value |> Atom.to_string() |> String.downcase()
  defp downcase_value(nil), do: ""
  defp downcase_value(value), do: value |> inspect() |> String.downcase()

  defp truncate(value, limit) when is_binary(value) and is_integer(limit) do
    if String.length(value) > limit do
      String.slice(value, 0, limit) <> "..."
    else
      value
    end
  end

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp map_path(value, []), do: value

  defp map_path(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, next} -> map_path(next, rest)
      :error -> nil
    end
  end

  defp map_path(_value, _path), do: nil

  defp map_value(value, keys) when is_map(value) do
    Enum.find_value(keys, fn key -> Map.get(value, key) end)
  end

  defp map_value(_value, _keys), do: nil

  defp coalesce_entries(events) do
    {entries_rev, last_agent, last_progress, seq} =
      Enum.reduce(events, {[], nil, nil, 1}, &coalesce_entry/2)

    {Enum.reverse(entries_rev), last_agent, last_progress, seq}
  end

  defp coalesce_entry(event, {acc_rev, last_agent, last_progress, seq}) do
    kind = event_kind(event)

    cond do
      kind == "agent-text" and not is_nil(last_agent) ->
        new_text = agent_text(event) || ""
        merged = %{last_agent | summary: last_agent.summary <> new_text}
        {[merged | tl(acc_rev)], merged, nil, seq}

      kind == "agent-text" ->
        entry = transcript_entry(event, seq)
        {[entry | acc_rev], entry, nil, seq + 1}

      command_progress_event?(event) and not is_nil(last_progress) ->
        merged = merge_command_progress_entry(last_progress, event)
        {[merged | tl(acc_rev)], nil, merged, seq}

      true ->
        entry = transcript_entry(event, seq)
        {[entry | acc_rev], nil, command_progress_entry(event, entry), seq + 1}
    end
  end

  defp command_progress_entry(event, entry) do
    if command_progress_event?(event), do: entry
  end

  defp error_message(reason), do: Map.get(@error_messages, reason, "An unexpected error occurred.")

  defp subscribe_transcript do
    case ObservabilityPubSub.subscribe_transcript() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to subscribe to transcript stream: #{inspect(reason)}")
        :ok
    end
  end

  defp current_repo_key, do: Config.repo_key_or_nil()

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
