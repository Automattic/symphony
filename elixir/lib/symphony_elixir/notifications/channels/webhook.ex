defmodule SymphonyElixir.Notifications.Channels.Webhook do
  @moduledoc false

  alias SymphonyElixir.Notifications.{Event, Formatter}
  alias SymphonyElixir.Secret

  @default_timeout_ms 5_000

  @spec deliver(map(), Event.t()) :: :ok | {:retry, non_neg_integer()} | {:error, term()}
  def deliver(channel, event), do: deliver(channel, event, [])

  @spec deliver(map(), Event.t(), keyword()) :: :ok | {:retry, non_neg_integer()} | {:error, term()}
  def deliver(%{url: url} = channel, %Event{} = event, opts) do
    case Secret.unwrap(url) do
      url when is_binary(url) ->
        payload = Formatter.webhook_payload(event, redact_titles: Keyword.get(opts, :redact_titles, false))
        headers = channel_headers(channel)
        post_json(url, payload, headers, opts)

      _ ->
        {:error, :missing_webhook_url}
    end
  end

  def deliver(_channel, _event, _opts), do: {:error, :missing_webhook_url}

  defp post_json(url, payload, headers, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    request_opts = [json: payload, headers: headers, receive_timeout: timeout_ms, redirect: false]

    case request_fun(opts).(url, payload, headers, timeout_ms, request_opts) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_status, status, body}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status, nil}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp request_fun(opts) do
    configured_request_fun = Keyword.get(opts, :request_fun)

    fn url, payload, headers, timeout_ms, request_opts ->
      case configured_request_fun do
        nil -> Req.post(url, request_opts)
        request_fun when is_function(request_fun, 5) -> request_fun.(url, payload, headers, timeout_ms, request_opts)
        request_fun when is_function(request_fun, 4) -> request_fun.(url, payload, headers, timeout_ms)
      end
    end
  end

  defp channel_headers(%{headers: headers}) when is_map(headers) do
    Enum.map(headers, fn {key, value} -> {key, Secret.unwrap(value) || ""} end)
  end

  defp channel_headers(_channel), do: []
end
