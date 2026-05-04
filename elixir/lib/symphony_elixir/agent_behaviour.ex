defmodule SymphonyElixir.AgentBehaviour do
  @moduledoc false

  @type session :: map()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback stop_session(session()) :: :ok
end
