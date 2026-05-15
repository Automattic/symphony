defmodule SymphonyElixir.SecretTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.Notifications.Channel
  alias SymphonyElixir.Config.Schema.Tracker
  alias SymphonyElixir.Secret

  test "inspect filters wrapped values" do
    assert inspect(%Secret{value: "abc"}) == "#Secret<[FILTERED]>"
    assert to_string(Secret.wrap("abc")) == "abc"
    assert to_string(%Secret{}) == ""
  end

  test "wrap, unwrap, and presence helpers handle passthrough and nil values" do
    secret = Secret.wrap("abc")

    assert Secret.wrap(secret) == secret
    assert Secret.wrap(nil) == nil
    assert Secret.unwrap(secret) == "abc"
    assert Secret.unwrap("abc") == "abc"
    assert Secret.unwrap(nil) == nil
    assert Secret.present?(secret)
    assert Secret.present?("abc")
    refute Secret.present?(nil)
  end

  test "nested state inspect does not include raw secret bytes" do
    token = "linear-secret-token"

    state = %{
      tracker: %Tracker{api_key: Secret.wrap(token)},
      channel: %Channel{
        webhook_url: Secret.wrap("https://hooks.example/#{token}"),
        headers: %{"Authorization" => Secret.wrap("Bearer #{token}")}
      },
      provider: %{api_key: Secret.wrap(token)}
    }

    formatted = inspect(state)
    tracker = inspect(state.tracker)
    channel = inspect(state.channel)

    refute formatted =~ token
    assert formatted =~ "#Secret<[FILTERED]>"
    assert tracker =~ "#SymphonyElixir.Config.Schema.Tracker<"
    refute tracker =~ "api_key:"
    refute channel =~ "headers:"
    refute channel =~ "webhook_url:"
  end
end
