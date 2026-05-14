defmodule SymphonyElixir.SensitivePath do
  @moduledoc """
  Shared detection for obvious secret paths and filenames.
  """

  @sensitive_path_prefixes ["~/.ssh/", "~/.aws/", "~/.config/gh/"]
  @sensitive_path_segments ["/.ssh/", "/.aws/", "/.config/gh/"]
  @sensitive_basename_prefixes [".env"]
  @sensitive_basename_suffixes [".pem", ".key"]

  @doc false
  @spec denied_secret_path([String.t()]) :: String.t() | nil
  def denied_secret_path(tokens) when is_list(tokens) do
    Enum.find_value(tokens, fn token ->
      token
      |> option_value()
      |> secret_path()
    end)
  end

  def denied_secret_path(_tokens), do: nil

  @doc false
  @spec secret_path(String.t()) :: String.t() | nil
  def secret_path(token) when is_binary(token) do
    normalized = token |> String.trim() |> String.trim_trailing(":")

    cond do
      String.starts_with?(normalized, @sensitive_path_prefixes) ->
        normalized

      String.contains?(normalized, @sensitive_path_segments) ->
        normalized

      sensitive_basename?(normalized) ->
        normalized

      true ->
        nil
    end
  end

  def secret_path(_token), do: nil

  @doc false
  @spec sensitive_basename?(Path.t()) :: boolean()
  def sensitive_basename?(path) when is_binary(path) do
    basename = path |> String.trim() |> String.trim_trailing(":") |> Path.basename()

    String.starts_with?(basename, @sensitive_basename_prefixes) or
      String.ends_with?(String.downcase(basename), @sensitive_basename_suffixes)
  end

  def sensitive_basename?(_path), do: false

  defp option_value(token) when is_binary(token) do
    case String.split(token, "=", parts: 2) do
      [_option, value] -> value
      [value] -> value
    end
  end

  defp option_value(token), do: token
end
