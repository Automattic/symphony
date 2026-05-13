defmodule SymphonyElixir.Secret do
  @moduledoc """
  Runtime wrapper for secret values that must not be exposed by `inspect/2`.
  """

  defstruct [:value]

  @opaque t :: %__MODULE__{value: String.t()}

  @spec wrap(String.t() | t() | nil) :: t() | nil
  def wrap(%__MODULE__{} = secret), do: secret
  def wrap(value) when is_binary(value), do: %__MODULE__{value: value}
  def wrap(nil), do: nil

  @spec unwrap(String.t() | t() | nil) :: String.t() | nil
  def unwrap(%__MODULE__{value: value}) when is_binary(value), do: value
  def unwrap(value) when is_binary(value), do: value
  def unwrap(nil), do: nil

  @spec present?(String.t() | t() | nil) :: boolean()
  def present?(value), do: is_binary(unwrap(value))
end

defimpl Inspect, for: SymphonyElixir.Secret do
  def inspect(_secret, _opts), do: "#Secret<[FILTERED]>"
end

defimpl String.Chars, for: SymphonyElixir.Secret do
  def to_string(%{value: value}) when is_binary(value), do: value
  def to_string(_secret), do: ""
end
