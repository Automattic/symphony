defmodule SymphonyElixir.QualityGate.OpenAITest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.QualityGate.OpenAI

  describe "score/2" do
    test "posts to chat/completions and parses the assistant message JSON" do
      test_pid = self()

      request_fun = fn payload, headers, _timeout ->
        send(test_pid, {:request, payload, headers})

        {:ok,
         %{
           status: 200,
           body: %{
             "choices" => [
               %{
                 "message" => %{
                   "role" => "assistant",
                   "content" => ~s({"score": 5, "reason": "borderline"})
                 }
               }
             ]
           }
         }}
      end

      assert {:ok, %{score: 5, reason: "borderline"}} =
               OpenAI.score(issue("RSM-2"), %{
                 model: "gpt-4o-mini",
                 api_key: "sk-test",
                 request_fun: request_fun
               })

      assert_received {:request, payload, headers}
      assert payload["model"] == "gpt-4o-mini"
      assert payload["response_format"] == %{"type" => "json_object"}

      assert [
               %{"role" => "system", "content" => system},
               %{"role" => "user", "content" => user}
             ] = payload["messages"]

      assert is_binary(system)
      assert user =~ "RSM-2"
      assert {"authorization", "Bearer sk-test"} in headers
    end

    test "surfaces non-200 responses as provider_http_status" do
      request_fun = fn _payload, _headers, _timeout ->
        {:ok, %{status: 500, body: %{"error" => "boom"}}}
      end

      assert {:error, {:provider_http_status, 500, _body}} =
               OpenAI.score(issue("RSM-2"), %{
                 model: "gpt-4o-mini",
                 api_key: "sk-test",
                 request_fun: request_fun
               })
    end

    test "errors out when the model returns prose instead of JSON" do
      request_fun = fn _payload, _headers, _timeout ->
        {:ok,
         %{
           status: 200,
           body: %{
             "choices" => [
               %{"message" => %{"content" => "I cannot score this issue."}}
             ]
           }
         }}
      end

      assert {:error, _reason} =
               OpenAI.score(issue("RSM-2"), %{
                 model: "gpt-4o-mini",
                 api_key: "sk-test",
                 request_fun: request_fun
               })
    end

    test "returns provider_request_failed on HTTP errors" do
      request_fun = fn _payload, _headers, _timeout -> {:error, :nxdomain} end

      assert {:error, {:provider_request_failed, :nxdomain}} =
               OpenAI.score(issue("RSM-2"), %{
                 model: "gpt-4o-mini",
                 api_key: "sk-test",
                 request_fun: request_fun
               })
    end

    test "tolerates a body without the choices field" do
      request_fun = fn _payload, _headers, _timeout ->
        {:ok, %{status: 200, body: %{"id" => "chat-1"}}}
      end

      assert {:error, :empty_response} =
               OpenAI.score(issue("RSM-2"), %{
                 model: "gpt-4o-mini",
                 api_key: "sk-test",
                 request_fun: request_fun
               })
    end

    test "falls back to credentials error when api_key is missing" do
      assert {:error, :missing_provider_credentials} =
               OpenAI.score(issue("RSM-2"), %{model: "gpt-4o-mini", api_key: nil})
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
