defmodule SymphonyElixir.QualityGate.Anthropic do
  @moduledoc """
  Anthropic Messages API client for `SymphonyElixir.QualityGate`.
  """

  @behaviour SymphonyElixir.QualityGate.Provider

  alias SymphonyElixir.QualityGate.Prompt
  alias SymphonyElixir.QualityGate.Response

  @endpoint "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @default_max_tokens 256
  @default_timeout_ms 30_000

  @impl true
  def score(issue, %{model: model, api_key: api_key} = settings)
      when is_binary(model) and is_binary(api_key) do
    payload = %{
      "model" => model,
      "max_tokens" => @default_max_tokens,
      "system" => Prompt.system_instructions(),
      "messages" => [
        %{"role" => "user", "content" => Prompt.user_prompt(issue)}
      ]
    }

    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]

    timeout_ms = Map.get(settings, :timeout_ms, @default_timeout_ms)
    request_fun = Map.get(settings, :request_fun) || (&default_post/3)

    case request_fun.(payload, headers, timeout_ms) do
      {:ok, %{status: 200, body: body}} -> Response.parse(extract_text(body))
      {:ok, %{status: status, body: body}} -> {:error, {:provider_http_status, status, body}}
      {:error, reason} -> {:error, {:provider_request_failed, reason}}
    end
  end

  def score(_issue, _settings), do: {:error, :missing_provider_credentials}

  defp default_post(payload, headers, timeout_ms) do
    Req.post(@endpoint,
      headers: headers,
      json: payload,
      receive_timeout: timeout_ms,
      connect_options: [timeout: timeout_ms]
    )
  end

  defp extract_text(%{"content" => content}) when is_list(content) do
    Enum.map_join(content, "", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp extract_text(_body), do: ""
end
