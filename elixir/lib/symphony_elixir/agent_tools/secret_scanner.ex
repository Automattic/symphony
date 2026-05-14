defmodule SymphonyElixir.AgentTools.SecretScanner do
  @moduledoc false

  require Logger

  alias SymphonyElixir.AuditLog

  @patterns [
    {:anthropic_api_key, ~r/\bsk-ant-[A-Za-z0-9_-]{20,}\b/},
    {:openai_api_key, ~r/\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}\b/},
    {:github_token, ~r/\bgh[pousr]_[A-Za-z0-9_]{20,}\b/},
    {:aws_access_key_id, ~r/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/},
    {:google_api_key, ~r/\bAIza[A-Za-z0-9_-]{35}\b/}
  ]

  @spec reject_if_secret_pattern(term(), map(), String.t(), String.t()) :: :ok | {:error, :secret_pattern_detected}
  def reject_if_secret_pattern(content, context, tool, field) do
    reject_if_secret_pattern(content, context, tool, field, [])
  end

  @spec reject_if_secret_pattern(term(), map(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :secret_pattern_detected}
  def reject_if_secret_pattern(content, context, tool, field, opts) when is_binary(content) do
    case detect(content) do
      nil ->
        :ok

      pattern ->
        audit_secret_pattern_rejection(context, tool, field, pattern, opts)
        {:error, :secret_pattern_detected}
    end
  end

  def reject_if_secret_pattern(_content, _context, _tool, _field, _opts), do: :ok

  @spec detect(String.t()) :: atom() | nil
  def detect(content) when is_binary(content) do
    if String.valid?(content), do: detect_valid_string(content)
  end

  def detect(_content), do: nil

  defp detect_valid_string(content) do
    Enum.find_value(@patterns, fn {name, pattern} ->
      if Regex.match?(pattern, content), do: name
    end)
  end

  defp audit_secret_pattern_rejection(context, tool, field, pattern, opts) do
    attrs = %{
      action: "rejected",
      reason: "secret_pattern_detected",
      tool: tool,
      field: field,
      secret_pattern: to_string(pattern)
    }

    result =
      case issue_from_context(context) do
        %{} = issue ->
          AuditLog.record_refused_agent_action(issue, attrs, opts)

        _missing ->
          AuditLog.record(Map.put(attrs, :event_type, "refused_agent_action"), opts)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Audit log failed to record secret-pattern rejection: #{inspect(reason)}")
    end
  end

  defp issue_from_context(%{issue: %{} = issue}), do: issue
  defp issue_from_context(%{"issue" => %{} = issue}), do: issue
  defp issue_from_context(_context), do: nil
end
