defmodule SymphonyElixir.QualityGate.OpenAI do
  @moduledoc """
  OpenAI Chat Completions API client for `SymphonyElixir.QualityGate`.
  """

  @behaviour SymphonyElixir.QualityGate.Provider

  alias SymphonyElixir.QualityGate.Prompt
  alias SymphonyElixir.QualityGate.Response
  alias SymphonyElixir.Secret

  @endpoint "https://api.openai.com/v1/chat/completions"
  @default_max_tokens 256
  @default_timeout_ms 30_000

  @impl true
  def score(issue, %{model: model, api_key: api_key} = settings) when is_binary(model) do
    case Secret.unwrap(api_key) do
      api_key when is_binary(api_key) ->
        %{
          system: Prompt.system_instructions(),
          user: Prompt.user_prompt(issue),
          max_tokens: @default_max_tokens
        }
        |> review(%{settings | api_key: Secret.wrap(api_key)})
        |> case do
          {:ok, text} -> Response.parse(text)
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :missing_provider_credentials}
    end
  end

  def score(_issue, _settings), do: {:error, :missing_provider_credentials}

  @spec review(map(), SymphonyElixir.QualityGate.Provider.settings()) ::
          {:ok, String.t()} | {:error, term()}
  def review(%{system: system, user: user} = request, %{model: model, api_key: api_key} = settings)
      when is_binary(system) and is_binary(user) and is_binary(model) do
    case Secret.unwrap(api_key) do
      api_key when is_binary(api_key) ->
        payload = %{
          "model" => model,
          "max_tokens" => Map.get(request, :max_tokens, @default_max_tokens),
          "response_format" => %{"type" => "json_object"},
          "messages" => [
            %{"role" => "system", "content" => system},
            %{"role" => "user", "content" => user}
          ]
        }

        headers = [
          {"authorization", "Bearer " <> api_key},
          {"content-type", "application/json"}
        ]

        timeout_ms = Map.get(settings, :timeout_ms, @default_timeout_ms)
        request_fun = Map.get(settings, :request_fun) || (&default_post/3)

        case request_fun.(payload, headers, timeout_ms) do
          {:ok, %{status: 200, body: body}} -> {:ok, extract_text(body)}
          {:ok, %{status: status, body: body}} -> {:error, {:provider_http_status, status, body}}
          {:error, reason} -> {:error, {:provider_request_failed, reason}}
        end

      _ ->
        {:error, :missing_provider_credentials}
    end
  end

  def review(_request, _settings), do: {:error, :missing_provider_credentials}

  defp default_post(payload, headers, timeout_ms) do
    Req.post(@endpoint,
      headers: headers,
      json: payload,
      receive_timeout: timeout_ms,
      connect_options: [timeout: timeout_ms]
    )
  end

  defp extract_text(%{"choices" => [%{"message" => %{"content" => text}} | _]})
       when is_binary(text),
       do: text

  defp extract_text(_body), do: ""
end
