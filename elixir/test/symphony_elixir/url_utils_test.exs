defmodule SymphonyElixir.URLUtilsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.URLUtils

  test "present_url trims binary URLs and rejects empty or non-binary values" do
    assert URLUtils.present_url(" https://example.test/path ") == "https://example.test/path"
    assert URLUtils.present_url(" ") == nil
    assert URLUtils.present_url(nil) == nil
  end

  test "pull_request_url accepts primary and fallback metadata keys" do
    assert URLUtils.pull_request_url(%{pull_request_url: " https://github.com/example/repo/pull/1 "}) ==
             "https://github.com/example/repo/pull/1"

    assert URLUtils.pull_request_url(%{
             pull_request_url: "",
             pr_url: "https://github.com/example/repo/pull/2"
           }) == "https://github.com/example/repo/pull/2"

    assert URLUtils.pull_request_url(%{
             "pull_request_url" => "",
             "pr_urls" => ["", "https://github.com/example/repo/pull/3"]
           }) == "https://github.com/example/repo/pull/3"

    assert URLUtils.pull_request_url(nil) == nil
  end

  test "transcript_url builds local dashboard transcript deeplinks" do
    assert URLUtils.dashboard_url("0.0.0.0", 0, nil) == nil

    assert URLUtils.transcript_url("RSM-1", "0.0.0.0", 0, 4100) ==
             "http://127.0.0.1:4100/issues/RSM-1/transcript"

    assert URLUtils.transcript_url("RSM 2", "::1", 4101, nil) ==
             "http://[::1]:4101/issues/RSM+2/transcript"

    assert URLUtils.transcript_url("RSM-3", " [::1] ", 4102, nil) ==
             "http://[::1]:4102/issues/RSM-3/transcript"

    assert URLUtils.transcript_url("RSM-4", " example.test ", 4103, nil) ==
             "http://example.test:4103/issues/RSM-4/transcript"

    assert URLUtils.transcript_url("RSM-3", "127.0.0.1", nil, nil) == nil
    assert URLUtils.transcript_url(nil, "127.0.0.1", 4104, nil) == nil
  end
end
