defmodule SymphonyElixir.Notifications.Channels.Slack do
  @moduledoc false

  alias SymphonyElixir.Notifications.{Event, Formatter}

  @default_timeout_ms 5_000
  @default_retry_after_ms 1_000

  @spec deliver(map(), Event.t()) :: :ok | {:retry, non_neg_integer()} | {:error, term()}
  def deliver(channel, event), do: deliver(channel, event, [])

  @spec deliver(map(), Event.t(), keyword()) :: :ok | {:retry, non_neg_integer()} | {:error, term()}
  def deliver(%{webhook_url: url}, %Event{} = event, opts) when is_binary(url) do
    payload = Formatter.slack_payload(event, redact_titles: Keyword.get(opts, :redact_titles, false))
    post_json(url, payload, [], opts)
  end

  def deliver(_channel, _event, _opts), do: {:error, :missing_slack_webhook_url}

  defp post_json(url, payload, headers, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    case request_fun(opts).(url, payload, headers, timeout_ms) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 429} = response} ->
        {:retry, retry_after_ms(response)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status, nil}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp request_fun(opts) do
    Keyword.get(opts, :request_fun, fn url, payload, headers, timeout_ms ->
      Req.post(url, json: payload, headers: headers, receive_timeout: timeout_ms)
    end)
  end

  defp retry_after_ms(response) do
    response
    |> response_header("retry-after")
    |> parse_retry_after_ms()
  end

  defp response_header(%{headers: headers}, header_name) when is_list(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == header_name, do: value

      _ ->
        nil
    end)
  end

  defp response_header(%{headers: headers}, header_name) when is_map(headers) do
    Map.get(headers, header_name) ||
      Map.get(headers, "Retry-After") ||
      Map.get(headers, String.capitalize(header_name))
  end

  defp response_header(_response, _header_name), do: nil

  defp parse_retry_after_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _ -> @default_retry_after_ms
    end
  end

  defp parse_retry_after_ms(value) when is_integer(value) and value >= 0, do: value * 1_000
  defp parse_retry_after_ms(_value), do: @default_retry_after_ms
end
