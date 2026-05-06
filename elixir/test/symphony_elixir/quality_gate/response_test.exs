defmodule SymphonyElixir.QualityGate.ResponseTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.QualityGate.Response

  describe "parse/1" do
    test "decodes a clean JSON object" do
      assert {:ok, %{score: 7, reason: "well-scoped"}} =
               Response.parse(~s({"score": 7, "reason": "well-scoped"}))
    end

    test "tolerates Markdown code fences" do
      raw = """
      ```json
      {"score": 4, "reason": "vague description"}
      ```
      """

      assert {:ok, %{score: 4, reason: "vague description"}} = Response.parse(raw)
    end

    test "extracts the JSON object even when prose surrounds it" do
      raw = ~s(Sure! Here it is: {"score": 9, "reason": "clear acceptance criteria"} hope this helps.)
      assert {:ok, %{score: 9, reason: "clear acceptance criteria"}} = Response.parse(raw)
    end

    test "coerces float scores by rounding" do
      assert {:ok, %{score: 8, reason: _}} = Response.parse(~s({"score": 7.6, "reason": "ok"}))
    end

    test "coerces stringified integer scores" do
      assert {:ok, %{score: 6, reason: _}} = Response.parse(~s({"score": "6", "reason": "ok"}))
    end

    test "rejects out-of-range scores" do
      assert {:error, _} = Response.parse(~s({"score": 11, "reason": "too high"}))
      assert {:error, _} = Response.parse(~s({"score": 0, "reason": "too low"}))
    end

    test "rejects malformed JSON" do
      assert {:error, _} = Response.parse("definitely not json")
    end

    test "supplies a fallback reason when missing" do
      assert {:ok, %{score: 5, reason: "(no reason provided)"}} =
               Response.parse(~s({"score": 5}))
    end

    test "rejects empty input" do
      assert {:error, :empty_response} = Response.parse("")
      assert {:error, :empty_response} = Response.parse(nil)
    end

    test "rejects strings that are only code fences" do
      assert {:error, :empty_response} = Response.parse("```json\n```\n")
    end

    test "returns no_json_object when no opening brace is present" do
      assert {:error, :no_json_object} = Response.parse("just text, no JSON here")
    end

    test "returns nil when an opening brace has no matching close" do
      assert {:error, :no_json_object} = Response.parse(~s({"score": 5))
    end

    test "tolerates escape sequences and nested objects" do
      raw = ~s({"reason": "with \\"quotes\\" and {curly braces}", "score": 7, "meta": {"k":"v"}})
      assert {:ok, %{score: 7, reason: ~s(with "quotes" and {curly braces})}} = Response.parse(raw)
    end

    test "rejects responses that decode to a JSON array" do
      assert {:error, :no_json_object} = Response.parse(~s([1, 2, 3]))
    end

    test "rejects responses whose JSON is not an object" do
      raw = ~s({}garbage)
      # decodes to %{} which has no score field
      assert {:error, _reason} = Response.parse(raw)
    end

    test "rejects malformed JSON inside a brace block" do
      assert {:error, {:invalid_json, _}} = Response.parse(~s({"score": ,}))
    end

    test "rejects non-numeric stringified scores" do
      assert {:error, _reason} = Response.parse(~s({"score": "high", "reason": "bad"}))
    end

    test "supplies a fallback reason when blank" do
      assert {:ok, %{reason: "(no reason provided)"}} =
               Response.parse(~s({"score": 5, "reason": "   "}))
    end
  end
end
