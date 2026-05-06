defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    reviewer_comments = normalize_reviewer_comments(Keyword.get(opts, :reviewer_comments, []))

    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map(),
        "reviewer_comments" => to_solid_value(reviewer_comments)
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
    |> append_extra_prompt(Keyword.get(opts, :extra_prompt) || Keyword.get(opts, :prompt_context))
    |> append_reviewer_comments(reviewer_comments)
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end

  defp append_extra_prompt(prompt, extra_prompt) when is_binary(extra_prompt) do
    case String.trim(extra_prompt) do
      "" -> prompt
      trimmed -> prompt <> "\n\n" <> trimmed
    end
  end

  defp append_extra_prompt(prompt, _extra_prompt), do: prompt

  defp append_reviewer_comments(prompt, []), do: prompt

  defp append_reviewer_comments(prompt, comments) when is_list(comments) do
    prompt <> "\n\n" <> reviewer_comments_section(comments)
  end

  defp reviewer_comments_section(comments) do
    entries =
      comments
      |> Enum.with_index(1)
      |> Enum.map_join("\n\n", fn {comment, index} ->
        [
          "#{index}. #{comment_header(comment)}",
          Map.fetch!(comment, :body)
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
      end)

    "Unaddressed reviewer comments:\n\n" <> entries
  end

  defp comment_header(comment) when is_map(comment) do
    [
      comment_author(comment),
      comment_kind(comment),
      comment_location(comment),
      comment_url(comment)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp comment_author(%{author: author}) when is_binary(author) and author != "", do: "#{author}:"
  defp comment_author(_comment), do: "Reviewer:"

  defp comment_kind(%{kind: kind}) when is_binary(kind) and kind != "", do: "[#{kind}]"
  defp comment_kind(_comment), do: nil

  defp comment_location(%{path: path, line: line}) when is_binary(path) and is_integer(line), do: "#{path}:#{line}"
  defp comment_location(%{path: path}) when is_binary(path), do: path
  defp comment_location(_comment), do: nil

  defp comment_url(%{url: url}) when is_binary(url) and url != "", do: url
  defp comment_url(_comment), do: nil

  defp normalize_reviewer_comments(comments) when is_list(comments) do
    comments
    |> Enum.map(&normalize_reviewer_comment/1)
    |> Enum.reject(&(String.trim(Map.get(&1, :body, "")) == ""))
  end

  defp normalize_reviewer_comments(_comments), do: []

  defp normalize_reviewer_comment(comment) when is_map(comment) do
    %{
      id: string_field(comment, :id),
      kind: string_field(comment, :kind),
      author: string_field(comment, :author),
      body: string_field(comment, :body) || "",
      url: string_field(comment, :url),
      path: string_field(comment, :path),
      line: integer_field(comment, :line),
      created_at: Map.get(comment, :created_at) || Map.get(comment, "created_at"),
      updated_at: Map.get(comment, :updated_at) || Map.get(comment, "updated_at")
    }
  end

  defp normalize_reviewer_comment(_comment), do: %{body: ""}

  defp string_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _value -> nil
    end
  end

  defp integer_field(map, key) when is_map(map) and is_atom(key) do
    case Map.get(map, key) || Map.get(map, to_string(key)) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end
end
