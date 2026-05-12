defmodule Mix.Tasks.Symphony.Audit do
  @moduledoc """
  Print audit events for an issue and inclusive date range as NDJSON.
  """

  use Mix.Task

  alias SymphonyElixir.{AuditLog, Paths}

  @shortdoc "Print Symphony audit events for an issue"
  @switches [from: :string, to: :string, logs_root: :string, state_root: :string]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    case {positional, invalid} do
      {[issue_id], []} ->
        maybe_set_audit_root(opts)
        print_events(issue_id, opts)

      _ ->
        Mix.raise(usage())
    end
  end

  defp maybe_set_audit_root(opts) do
    case Keyword.get(opts, :state_root) do
      nil -> maybe_set_legacy_logs_root(opts)
      state_root -> set_state_root(state_root)
    end
  end

  defp maybe_set_legacy_logs_root(opts) do
    case Keyword.get(opts, :logs_root) do
      nil -> :ok
      logs_root -> AuditLog.set_dir(AuditLog.default_dir(Path.expand(logs_root)))
    end
  end

  defp set_state_root(state_root) do
    :ok = Paths.set_state_root(Path.expand(state_root))
    AuditLog.set_dir(Paths.audit_dir())
  end

  defp print_events(issue_id, opts) do
    today = Date.utc_today()
    from_date = Keyword.get(opts, :from, Date.to_iso8601(today))
    to_date = Keyword.get(opts, :to, from_date)

    case AuditLog.list_events(issue_id, from_date, to_date) do
      {:ok, events} ->
        Enum.each(events, fn event ->
          Mix.shell().info(Jason.encode!(event))
        end)

      {:error, reason} ->
        Mix.raise("Unable to read audit events: #{inspect(reason)}")
    end
  end

  defp usage do
    "Usage: mix symphony.audit ISSUE_ID [--from YYYY-MM-DD] [--to YYYY-MM-DD] [--state-root PATH] [--logs-root PATH]"
  end
end
