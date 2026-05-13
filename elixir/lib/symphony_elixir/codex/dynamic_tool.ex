defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.AgentTools.{GitHub, Linear}

  @tool_schemas [
    %{
      "name" => "linear_get_current_issue",
      "description" => "Read full fields for the current Linear issue.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear_get_subissues",
      "description" => "Read direct child issues of the current Linear issue.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear_get_parent_issue",
      "description" => "Read the parent issue of the current Linear issue, if any.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear_get_comments",
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
      "name" => "linear_get_related_issues",
      "description" => "Read blocks and blocked-by issue summaries for the current Linear issue.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "linear_update_state",
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
      "name" => "linear_set_assignee",
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
      "name" => "linear_add_comment",
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
      "name" => "linear_update_comment",
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
      "name" => "linear_delete_comment",
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
      "name" => "linear_attach_url",
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
      "name" => "linear_attach_file",
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
    },
    %{
      "name" => "github_get_pull_request",
      "description" => "Read the pull request for the current workspace branch in the configured origin repo.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_create_pull_request",
      "description" => "Create a pull request from the current workspace branch to the configured origin repo default branch.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["title", "body"],
        "properties" => %{
          "title" => %{"type" => "string"},
          "body" => %{"type" => "string"},
          "draft" => %{"type" => "boolean"}
        }
      }
    },
    %{
      "name" => "github_update_pull_request_body",
      "description" => "Update the body of the pull request for the current workspace branch.",
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
      "name" => "github_add_pr_comment",
      "description" => "Add a comment to the pull request for the current workspace branch.",
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
      "name" => "github_push_branch",
      "description" => "Push the current workspace branch to origin.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    },
    %{
      "name" => "github_get_pr_checks",
      "description" => "Read status checks for the pull request for the current workspace branch.",
      "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
    }
  ]

  @tool_names Enum.map(@tool_schemas, & &1["name"])
  @invalid_tool_names Enum.reject(@tool_names, fn name -> Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name) end)

  if @invalid_tool_names != [] do
    raise ArgumentError, "dynamic tool names must match ^[a-zA-Z0-9_-]+$: #{inspect(@invalid_tool_names)}"
  end

  @allowed_arguments %{
    "linear_get_current_issue" => [],
    "linear_get_subissues" => [],
    "linear_get_parent_issue" => [],
    "linear_get_comments" => ["limit"],
    "linear_get_related_issues" => [],
    "linear_update_state" => ["state_name_or_id"],
    "linear_set_assignee" => ["assignee"],
    "linear_add_comment" => ["body"],
    "linear_update_comment" => ["comment_id", "body"],
    "linear_delete_comment" => ["comment_id"],
    "linear_attach_url" => ["url", "title"],
    "linear_attach_file" => ["local_path", "title"],
    "github_get_pull_request" => [],
    "github_create_pull_request" => ["title", "body", "draft"],
    "github_update_pull_request_body" => ["body"],
    "github_add_pr_comment" => ["body"],
    "github_push_branch" => [],
    "github_get_pr_checks" => []
  }
  @legacy_tool_aliases %{
    "linear.get_current_issue" => "linear_get_current_issue",
    "linear.get_subissues" => "linear_get_subissues",
    "linear.get_parent_issue" => "linear_get_parent_issue",
    "linear.get_comments" => "linear_get_comments",
    "linear.get_related_issues" => "linear_get_related_issues",
    "linear.update_state" => "linear_update_state",
    "linear.set_assignee" => "linear_set_assignee",
    "linear.add_comment" => "linear_add_comment",
    "linear.update_comment" => "linear_update_comment",
    "linear.delete_comment" => "linear_delete_comment",
    "linear.attach_url" => "linear_attach_url",
    "linear.attach_file" => "linear_attach_file",
    "github.get_pull_request" => "github_get_pull_request",
    "github.create_pull_request" => "github_create_pull_request",
    "github.update_pull_request_body" => "github_update_pull_request_body",
    "github.add_pr_comment" => "github_add_pr_comment",
    "github.push_branch" => "github_push_branch",
    "github.get_pr_checks" => "github_get_pr_checks"
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    context = tool_context(opts)
    tool = normalize_tool_name(tool)

    case Map.fetch(@allowed_arguments, tool) do
      {:ok, allowed_arguments} ->
        with_arguments(tool, arguments, allowed_arguments, fn args -> execute_tool(tool, context, args, opts) end)

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
      comment_registry: Keyword.get(opts, :comment_registry),
      command_security: Keyword.get(opts, :command_security) || %{}
    }
  end

  defp with_arguments(tool, arguments, allowed_keys, fun) when is_function(fun, 1) do
    with {:ok, args} <- normalize_arguments(arguments),
         :ok <- reject_scope_arguments(tool, args),
         :ok <- validate_argument_keys(args, allowed_keys),
         {:ok, result} <- fun.(args) do
      success_response(result)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
    end
  end

  defp execute_tool("linear_" <> _rest = tool, context, args, opts), do: execute_linear_tool(tool, context, args, opts)
  defp execute_tool("github_" <> _rest = tool, context, args, opts), do: execute_github_tool(tool, context, args, opts)

  defp execute_linear_tool("linear_get_current_issue", context, _args, opts), do: Linear.get_current_issue(context, opts)
  defp execute_linear_tool("linear_get_subissues", context, _args, opts), do: Linear.get_subissues(context, opts)
  defp execute_linear_tool("linear_get_parent_issue", context, _args, opts), do: Linear.get_parent_issue(context, opts)
  defp execute_linear_tool("linear_get_related_issues", context, _args, opts), do: Linear.get_related_issues(context, opts)

  defp execute_linear_tool("linear_get_comments", context, args, opts) do
    Linear.get_comments(context, Map.get(args, "limit"), opts)
  end

  defp execute_linear_tool("linear_update_state", context, args, opts) do
    Linear.update_state(context, Map.get(args, "state_name_or_id"), opts)
  end

  defp execute_linear_tool("linear_set_assignee", context, args, opts) do
    Linear.set_assignee(context, Map.get(args, "assignee"), opts)
  end

  defp execute_linear_tool("linear_add_comment", context, args, opts) do
    Linear.add_comment(context, Map.get(args, "body"), opts)
  end

  defp execute_linear_tool("linear_update_comment", context, args, opts) do
    Linear.update_comment(context, Map.get(args, "comment_id"), Map.get(args, "body"), opts)
  end

  defp execute_linear_tool("linear_delete_comment", context, args, opts) do
    Linear.delete_comment(context, Map.get(args, "comment_id"), opts)
  end

  defp execute_linear_tool("linear_attach_url", context, args, opts) do
    Linear.attach_url(context, Map.get(args, "url"), Map.get(args, "title"), opts)
  end

  defp execute_linear_tool("linear_attach_file", context, args, opts) do
    Linear.attach_file(context, Map.get(args, "local_path"), Map.get(args, "title"), opts)
  end

  defp execute_github_tool("github_get_pull_request", context, _args, opts), do: GitHub.get_pull_request(context, opts)

  defp execute_github_tool("github_create_pull_request", context, args, opts) do
    GitHub.create_pull_request(context, Map.get(args, "title"), Map.get(args, "body"), Map.get(args, "draft"), opts)
  end

  defp execute_github_tool("github_update_pull_request_body", context, args, opts) do
    GitHub.update_pull_request_body(context, Map.get(args, "body"), opts)
  end

  defp execute_github_tool("github_add_pr_comment", context, args, opts) do
    GitHub.add_pr_comment(context, Map.get(args, "body"), opts)
  end

  defp execute_github_tool("github_push_branch", context, _args, opts), do: GitHub.push_branch(context, opts)
  defp execute_github_tool("github_get_pr_checks", context, _args, opts), do: GitHub.get_pr_checks(context, opts)

  defp normalize_tool_name(tool) when is_binary(tool), do: Map.get(@legacy_tool_aliases, tool, tool)
  defp normalize_tool_name(tool), do: tool

  defp normalize_arguments(nil), do: {:ok, %{}}
  defp normalize_arguments(arguments) when is_map(arguments), do: {:ok, stringify_keys(arguments)}
  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp stringify_keys(arguments) do
    Map.new(arguments, fn {key, value} -> {to_string(key), value} end)
  end

  defp reject_scope_arguments("linear_" <> _rest, args) do
    if Enum.any?(Map.keys(args), &(&1 in ["issue_id", "issueId", "id"])) do
      {:error, :scope_argument_rejected}
    else
      :ok
    end
  end

  defp reject_scope_arguments("github_" <> _rest, args) do
    scope_keys = [
      "repo",
      "repository",
      "remote",
      "head",
      "base",
      "branch",
      "current_branch",
      "currentBranch",
      "ref",
      "refspec"
    ]

    if Enum.any?(Map.keys(args), &(&1 in scope_keys)) do
      {:error, {:scope_argument_rejected, :github}}
    else
      :ok
    end
  end

  defp reject_scope_arguments(_tool, _args), do: :ok

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
        "message" => "Dynamic tools expect an object argument payload."
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

  defp tool_error_payload({:scope_argument_rejected, :github}) do
    %{
      "error" => %{
        "code" => "scope_argument_rejected",
        "message" => "Dynamic GitHub tools are scoped to the current workspace branch and configured origin; repo, remote, head, branch, and refspec arguments are not accepted."
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

  defp tool_error_payload(:missing_github_origin_repo) do
    %{
      "error" => %{
        "code" => "missing_github_origin_repo",
        "message" => "Symphony could not resolve the configured origin GitHub repo for this workspace."
      }
    }
  end

  defp tool_error_payload(:missing_workspace) do
    %{
      "error" => %{
        "code" => "missing_workspace",
        "message" => "Symphony could not resolve the current workspace for this dynamic tool call."
      }
    }
  end

  defp tool_error_payload(:workspace_not_found) do
    %{
      "error" => %{
        "code" => "workspace_not_found",
        "message" => "The current workspace path does not exist."
      }
    }
  end

  defp tool_error_payload(:missing_current_branch) do
    %{
      "error" => %{
        "code" => "missing_current_branch",
        "message" => "Symphony could not resolve the current git branch for this workspace."
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "code" => inspect(reason),
        "message" => "Dynamic tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end
end
