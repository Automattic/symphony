defmodule SymphonyElixir.URLUtils do
  @moduledoc false

  @spec present_url(term()) :: String.t() | nil
  def present_url(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def present_url(_url), do: nil

  @spec pull_request_url(term()) :: String.t() | nil
  def pull_request_url(entry) when is_map(entry) do
    present_url(Map.get(entry, :pull_request_url)) ||
      present_url(Map.get(entry, "pull_request_url")) ||
      present_url(Map.get(entry, :pr_url)) ||
      present_url(Map.get(entry, "pr_url")) ||
      first_present_url(Map.get(entry, :pr_urls)) ||
      first_present_url(Map.get(entry, "pr_urls"))
  end

  def pull_request_url(_entry), do: nil

  @spec dashboard_url(String.t() | nil, non_neg_integer() | nil, non_neg_integer() | nil) :: String.t() | nil
  def dashboard_url(_host, nil, nil), do: nil
  def dashboard_url(_host, 0, nil), do: nil

  def dashboard_url(host, configured_port, bound_port) do
    port = bound_port || configured_port

    if is_integer(port) and port > 0 do
      "http://#{dashboard_url_host(host)}:#{port}/"
    end
  end

  @spec transcript_url(String.t() | nil, String.t() | nil, non_neg_integer() | nil, non_neg_integer() | nil) ::
          String.t() | nil
  def transcript_url(identifier, host, configured_port, bound_port) when is_binary(identifier) do
    case dashboard_url(host, configured_port, bound_port) do
      url when is_binary(url) ->
        url <> "issues/" <> URI.encode_www_form(identifier) <> "/transcript"

      _ ->
        nil
    end
  end

  def transcript_url(_identifier, _host, _configured_port, _bound_port), do: nil

  @spec transcript_url(
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          non_neg_integer() | nil,
          non_neg_integer() | nil
        ) :: String.t() | nil
  def transcript_url(repo_key, identifier, host, configured_port, bound_port)
      when is_binary(repo_key) and is_binary(identifier) do
    case dashboard_url(host, configured_port, bound_port) do
      url when is_binary(url) ->
        url <> String.trim_leading(transcript_path(repo_key, identifier), "/")

      _ ->
        nil
    end
  end

  def transcript_url(_repo_key, _identifier, _host, _configured_port, _bound_port), do: nil

  @spec transcript_path(String.t() | nil, String.t() | nil) :: String.t() | nil
  def transcript_path(repo_key, identifier) when is_binary(repo_key) and is_binary(identifier) do
    "/repos/" <> URI.encode_www_form(repo_key) <> "/issues/" <> URI.encode_www_form(identifier) <> "/transcript"
  end

  def transcript_path(_repo_key, _identifier), do: nil

  defp first_present_url(urls) when is_list(urls) do
    Enum.find_value(urls, &present_url/1)
  end

  defp first_present_url(_urls), do: nil

  defp dashboard_url_host(host) when host in ["0.0.0.0", "::", "[::]", "", nil], do: "127.0.0.1"

  defp dashboard_url_host(host) when is_binary(host) do
    trimmed_host = String.trim(host)

    cond do
      trimmed_host in ["0.0.0.0", "::", "[::]", ""] ->
        "127.0.0.1"

      String.starts_with?(trimmed_host, "[") and String.ends_with?(trimmed_host, "]") ->
        trimmed_host

      String.contains?(trimmed_host, ":") ->
        "[#{trimmed_host}]"

      true ->
        trimmed_host
    end
  end
end
