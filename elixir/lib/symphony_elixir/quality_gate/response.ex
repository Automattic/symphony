defmodule SymphonyElixir.QualityGate.Response do
  @moduledoc """
  Parses LLM scoring responses into a normalized `%{score, reason}` shape.

  Tolerates code fences, leading/trailing prose, and stray whitespace by
  isolating the first JSON object in the text before decoding.
  """

  @doc """
  Parse a raw text response and return either `{:ok, %{score, reason}}` or
  `{:error, reason}`.

  The score is coerced to an integer in the inclusive range 1..10. Any value
  outside that range, missing fields, or malformed JSON yields an error
  tuple suitable for the orchestrator's `on_error` handling.
  """
  @spec parse(String.t() | nil) ::
          {:ok, %{score: 1..10, reason: String.t()}} | {:error, term()}
  def parse(nil), do: {:error, :empty_response}
  def parse(""), do: {:error, :empty_response}

  def parse(text) when is_binary(text) do
    with {:ok, json} <- isolate_json_object(text),
         {:ok, decoded} <- decode_json(json),
         {:ok, score} <- coerce_score(Map.get(decoded, "score")),
         {:ok, reason} <- coerce_reason(Map.get(decoded, "reason")) do
      {:ok, %{score: score, reason: reason}}
    end
  end

  defp isolate_json_object(text) do
    text
    |> String.replace(~r/```(?:json)?\s*/i, "")
    |> String.replace("```", "")
    |> String.trim()
    |> case do
      "" ->
        {:error, :empty_response}

      cleaned ->
        case extract_object(cleaned) do
          nil -> {:error, :no_json_object}
          json -> {:ok, json}
        end
    end
  end

  defp extract_object(text) do
    case :binary.match(text, "{") do
      :nomatch -> nil
      {start, _len} -> extract_object(text, start)
    end
  end

  defp extract_object(text, start) do
    do_scan(text, start, start, 0, false, nil)
  end

  defp do_scan(text, _start, index, _depth, _in_string?, _escape?)
       when index >= byte_size(text),
       do: nil

  defp do_scan(text, start, index, depth, in_string?, escape?) do
    text
    |> :binary.part(index, 1)
    |> step_scan(text, start, index, depth, in_string?, escape?)
  end

  defp step_scan("\\", text, start, index, depth, true, escape?),
    do: do_scan(text, start, index + 1, depth, true, !escape?)

  defp step_scan("\"", text, start, index, depth, true, true),
    do: do_scan(text, start, index + 1, depth, true, false)

  defp step_scan("\"", text, start, index, depth, true, false),
    do: do_scan(text, start, index + 1, depth, false, false)

  defp step_scan("\"", text, start, index, depth, false, _escape?),
    do: do_scan(text, start, index + 1, depth, true, false)

  defp step_scan("{", text, start, index, depth, false, _escape?),
    do: do_scan(text, start, index + 1, depth + 1, false, false)

  defp step_scan("}", text, start, index, depth, false, _escape?) do
    new_depth = depth - 1

    if new_depth == 0 do
      :binary.part(text, start, index - start + 1)
    else
      do_scan(text, start, index + 1, new_depth, false, false)
    end
  end

  defp step_scan(_byte, text, start, index, depth, in_string?, _escape?),
    do: do_scan(text, start, index + 1, depth, in_string?, false)

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp coerce_score(value) when is_integer(value) and value >= 1 and value <= 10, do: {:ok, value}

  defp coerce_score(value) when is_float(value) do
    rounded = round(value)

    if rounded >= 1 and rounded <= 10 do
      {:ok, rounded}
    else
      {:error, {:score_out_of_range, value}}
    end
  end

  defp coerce_score(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> coerce_score(parsed)
      _ -> {:error, {:invalid_score, value}}
    end
  end

  defp coerce_score(value), do: {:error, {:invalid_score, value}}

  defp coerce_reason(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, "(no reason provided)"}
      reason -> {:ok, reason}
    end
  end

  defp coerce_reason(_value), do: {:ok, "(no reason provided)"}
end
