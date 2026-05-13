defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.AgentTools.Linear

  @tool_schemas [
    %{
      "name" => "linear.get_current_issue",
      "description" => "Read full fields for the current Linear issue.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear.get_subissues",
      "description" => "Read direct child issues of the current Linear issue.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear.get_parent_issue",
      "description" => "Read the parent issue of the current Linear issue, if any.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear.get_comments",
      "description" => "Read comments on the current Linear issue, newest first.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}
        }
      }
    },
    %{
      "name" => "linear.get_related_issues",
      "description" => "Read blocks and blocked-by issue summaries for the current Linear issue.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear.update_state",
      "description" => "Move the current Linear issue to a state in its team's workflow.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["state_name_or_id"],
        "properties" => %{
          "state_name_or_id" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "linear.set_assignee",
      "description" => "Set the current Linear issue assignee to self, unassign, or a user id.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["assignee"],
        "properties" => %{
          "assignee" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "linear.add_comment",
      "description" => "Add a comment to the current Linear issue.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["body"],
        "properties" => %{
          "body" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "linear.update_comment",
      "description" => "Update a comment created earlier by this run.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["comment_id", "body"],
        "properties" => %{
          "comment_id" => %{"type" => "string"},
          "body" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "linear.delete_comment",
      "description" => "Delete a comment created earlier by this run.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["comment_id"],
        "properties" => %{
          "comment_id" => %{"type" => "string"}
        }
      }
    },
    %{
      "name" => "linear.attach_url",
      "description" => "Attach a URL to the current Linear issue.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["url"],
        "properties" => %{
          "url" => %{"type" => "string"},
          "title" => %{"type" => ["string", "null"], "maxLength" => 120}
        }
      }
    },
    %{
      "name" => "linear.attach_file",
      "description" => "Upload and attach a workspace-local file to the current Linear issue.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["local_path"],
        "properties" => %{
          "local_path" => %{"type" => "string"},
          "title" => %{"type" => ["string", "null"], "maxLength" => 120}
        }
      }
    }
  ]

  @tool_names Enum.map(@tool_schemas, & &1["name"])
  @allowed_arguments %{
    "linear.get_current_issue" => [],
    "linear.get_subissues" => [],
    "linear.get_parent_issue" => [],
    "linear.get_comments" => ["limit"],
    "linear.get_related_issues" => [],
    "linear.update_state" => ["state_name_or_id"],
    "linear.set_assignee" => ["assignee"],
    "linear.add_comment" => ["body"],
    "linear.update_comment" => ["comment_id", "body"],
    "linear.delete_comment" => ["comment_id"],
    "linear.attach_url" => ["url", "title"],
    "linear.attach_file" => ["local_path", "title"]
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    context = tool_context(opts)

    case Map.fetch(@allowed_arguments, tool) do
      {:ok, allowed_arguments} ->
        with_arguments(arguments, allowed_arguments, fn args -> execute_linear_tool(tool, context, args, opts) end)

      :error ->
        tool_not_found_response(tool)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs, do: @tool_schemas

  defp tool_context(opts) do
    %{
      issue: Keyword.get(opts, :issue),
      issue_id: Keyword.get(opts, :issue_id),
      workspace: Keyword.get(opts, :workspace),
      comment_registry: Keyword.get(opts, :comment_registry)
    }
  end

  defp with_arguments(arguments, allowed_keys, fun) when is_function(fun, 1) do
    with {:ok, args} <- normalize_arguments(arguments),
         :ok <- reject_scope_arguments(args),
         :ok <- validate_argument_keys(args, allowed_keys),
         {:ok, result} <- fun.(args) do
      success_response(result)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_linear_tool("linear.get_current_issue", context, _args, opts), do: Linear.get_current_issue(context, opts)
  defp execute_linear_tool("linear.get_subissues", context, _args, opts), do: Linear.get_subissues(context, opts)
  defp execute_linear_tool("linear.get_parent_issue", context, _args, opts), do: Linear.get_parent_issue(context, opts)
  defp execute_linear_tool("linear.get_related_issues", context, _args, opts), do: Linear.get_related_issues(context, opts)

  defp execute_linear_tool("linear.get_comments", context, args, opts) do
    Linear.get_comments(context, Map.get(args, "limit"), opts)
  end

  defp execute_linear_tool("linear.update_state", context, args, opts) do
    Linear.update_state(context, Map.get(args, "state_name_or_id"), opts)
  end

  defp execute_linear_tool("linear.set_assignee", context, args, opts) do
    Linear.set_assignee(context, Map.get(args, "assignee"), opts)
  end

  defp execute_linear_tool("linear.add_comment", context, args, opts) do
    Linear.add_comment(context, Map.get(args, "body"), opts)
  end

  defp execute_linear_tool("linear.update_comment", context, args, opts) do
    Linear.update_comment(context, Map.get(args, "comment_id"), Map.get(args, "body"), opts)
  end

  defp execute_linear_tool("linear.delete_comment", context, args, opts) do
    Linear.delete_comment(context, Map.get(args, "comment_id"), opts)
  end

  defp execute_linear_tool("linear.attach_url", context, args, opts) do
    Linear.attach_url(context, Map.get(args, "url"), Map.get(args, "title"), opts)
  end

  defp execute_linear_tool("linear.attach_file", context, args, opts) do
    Linear.attach_file(context, Map.get(args, "local_path"), Map.get(args, "title"), opts)
  end

  defp normalize_arguments(nil), do: {:ok, %{}}
  defp normalize_arguments(arguments) when is_map(arguments), do: {:ok, stringify_keys(arguments)}
  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp stringify_keys(arguments) do
    Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
  end

  defp reject_scope_arguments(args) do
    if Enum.any?(Map.keys(args), &(&1 in ["issue_id", "issueId", "id"])) do
      {:error, :scope_argument_rejected}
    else
      :ok
    end
  end

  defp validate_argument_keys(args, allowed_keys) do
    allowed = MapSet.new(allowed_keys)

    args
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> case do
      [] -> :ok
      keys -> {:error, {:unexpected_arguments, keys}}
    end
  end

  defp success_response(payload) do
    dynamic_tool_response(true, encode_payload(payload))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp tool_not_found_response(tool) do
    failure_response(%{
      "error" => %{
        "code" => "tool_not_found",
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => @tool_names
      }
    })
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "code" => "invalid_arguments",
        "message" => "Dynamic Linear tools expect an object argument payload."
      }
    }
  end

  defp tool_error_payload(:scope_argument_rejected) do
    %{
      "error" => %{
        "code" => "scope_argument_rejected",
        "message" => "Dynamic Linear tools are scoped to the current issue; issue id arguments are not accepted."
      }
    }
  end

  defp tool_error_payload({:unexpected_arguments, keys}) do
    %{
      "error" => %{
        "code" => "unexpected_arguments",
        "message" => "Unexpected argument(s): #{Enum.join(keys, ", ")}.",
        "arguments" => keys
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "code" => "missing_linear_api_token",
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status, body}) do
    %{
      "error" => %{
        "body" => body,
        "code" => "linear_api_status",
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "code" => "linear_api_request",
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:state_not_found, available_states}) do
    %{
      "error" => %{
        "code" => "state_not_found",
        "message" => "Linear workflow state not found. Available states: #{Enum.join(available_states, ", ")}.",
        "available_states" => available_states
      }
    }
  end

  defp tool_error_payload({:linear_mutation_failed, field, body}) do
    %{
      "error" => %{
        "code" => "linear_mutation_failed",
        "message" => "Linear `#{field}` mutation reported success=false.",
        "field" => field,
        "body" => body
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "code" => inspect(reason),
        "message" => "Linear tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end
end
