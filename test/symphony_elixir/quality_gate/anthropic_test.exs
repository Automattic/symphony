defmodule SymphonyElixir.QualityGate.AnthropicTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QualityGate.Anthropic

  describe "score/2" do
    test "posts to the Messages API and parses a JSON object response" do
      test_pid = self()

      request_fun = fn payload, headers, _timeout ->
        send(test_pid, {:request, payload, headers})

        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [
               %{"type" => "text", "text" => ~s({"score": 8, "reason": "clear"})}
             ]
           }
         }}
      end

      assert {:ok, %{score: 8, reason: "clear"}} =
               Anthropic.score(issue("ACME-1"), %{
                 model: "claude-haiku-4-5-20251001",
                 api_key: "secret-key",
                 request_fun: request_fun
               })

      assert_received {:request, payload, headers}
      assert payload["model"] == "claude-haiku-4-5-20251001"
      assert is_binary(payload["system"])
      assert [%{"role" => "user", "content" => user}] = payload["messages"]
      assert user =~ "ACME-1"
      assert {"x-api-key", "secret-key"} in headers
      assert {"anthropic-version", "2023-06-01"} in headers
    end

    test "returns provider_http_status on non-200 responses" do
      request_fun = fn _payload, _headers, _timeout ->
        {:ok, %{status: 401, body: %{"error" => "unauthorized"}}}
      end

      assert {:error, {:provider_http_status, 401, _body}} =
               Anthropic.score(issue("ACME-1"), %{
                 model: "claude-haiku-4-5-20251001",
                 api_key: "key",
                 request_fun: request_fun
               })
    end

    test "returns provider_request_failed when the HTTP layer errors" do
      request_fun = fn _payload, _headers, _timeout -> {:error, :timeout} end

      assert {:error, {:provider_request_failed, :timeout}} =
               Anthropic.score(issue("ACME-1"), %{
                 model: "claude-haiku-4-5-20251001",
                 api_key: "key",
                 request_fun: request_fun
               })
    end

    test "falls back to credentials error when api_key is missing" do
      assert {:error, :missing_provider_credentials} =
               Anthropic.score(issue("ACME-1"), %{model: "claude-haiku", api_key: nil})
    end

    test "ignores non-text content blocks and surfaces empty text as a parse error" do
      request_fun = fn _payload, _headers, _timeout ->
        {:ok,
         %{
           status: 200,
           body: %{
             "content" => [
               %{"type" => "image", "source" => %{}}
             ]
           }
         }}
      end

      assert {:error, :empty_response} =
               Anthropic.score(issue("ACME-1"), %{
                 model: "claude-haiku-4-5-20251001",
                 api_key: "key",
                 request_fun: request_fun
               })
    end

    test "tolerates a body without the content field" do
      request_fun = fn _payload, _headers, _timeout ->
        {:ok, %{status: 200, body: %{"unexpected" => true}}}
      end

      assert {:error, :empty_response} =
               Anthropic.score(issue("ACME-1"), %{
                 model: "claude-haiku-4-5-20251001",
                 api_key: "key",
                 request_fun: request_fun
               })
    end
  end

  defp issue(id) do
    %Issue{
      id: id,
      identifier: id,
      title: "title",
      description: "desc",
      state: "Todo",
      labels: []
    }
  end
end
