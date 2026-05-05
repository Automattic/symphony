defmodule SymphonyElixir.QualityGate.Provider do
  @moduledoc """
  LLM provider boundary for `SymphonyElixir.QualityGate`.

  An implementation receives a single Linear issue plus the resolved provider
  settings and returns a numeric agent-readiness score with a short reason
  string. The score must be an integer in the inclusive range 1..10.
  """

  alias SymphonyElixir.Linear.Issue

  @type settings :: %{
          required(:provider) => String.t(),
          required(:model) => String.t(),
          required(:api_key) => String.t(),
          optional(:timeout_ms) => pos_integer()
        }

  @type score_result :: %{
          required(:score) => 1..10,
          required(:reason) => String.t()
        }

  @callback score(Issue.t(), settings()) :: {:ok, score_result()} | {:error, term()}
end
