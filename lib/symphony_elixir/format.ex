defmodule SymphonyElixir.Format do
  @moduledoc false

  @spec format_count(term()) :: String.t()
  def format_count(nil), do: "0"

  def format_count(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> group_thousands()
  end

  def format_count(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {number, ""} -> group_thousands(Integer.to_string(number))
      _ -> value
    end
  end

  def format_count(value), do: to_string(value)

  @spec truncate(term(), non_neg_integer()) :: term()
  def truncate(value, max) when is_binary(value) and byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  def truncate(value, _max) when is_binary(value), do: value
  def truncate(value, _max), do: value

  defp group_thousands(value) when is_binary(value) do
    sign = if String.starts_with?(value, "-"), do: "-", else: ""
    unsigned = if sign == "", do: value, else: String.slice(value, 1, String.length(value) - 1)

    grouped =
      unsigned
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

    sign <> grouped
  end
end
