defmodule SymphonyElixir.ReviewAgentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ReviewAgent

  describe "parse_response/1" do
    test "accepts approved verdict JSON inside surrounding text" do
      assert {:ok, %{verdict: :approve, comments: []}} =
               ReviewAgent.parse_response("""
               Review complete.
               ```json
               {"verdict":"approve","comments":[]}
               ```
               """)
    end

    test "accepts request_changes with actionable comments" do
      assert {:ok, %{verdict: :request_changes, comments: ["Add coverage."]}} =
               ReviewAgent.parse_response(~s({"verdict":"request_changes","comments":["Add coverage."]}))
    end

    test "requires comments for request_changes" do
      assert {:error, {:malformed_review_agent_response, :missing_request_changes_comments}} =
               ReviewAgent.parse_response(~s({"verdict":"request_changes","comments":[]}))
    end

    test "requires a reason for block" do
      assert {:error, {:malformed_review_agent_response, :missing_block_reason}} =
               ReviewAgent.parse_response(~s({"verdict":"block","comments":[]}))
    end
  end
end
