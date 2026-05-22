defmodule SymphonyElixir.FormatTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Format

  test "format_count groups integer and integer-like values" do
    assert Format.format_count(nil) == "0"
    assert Format.format_count(1_234_567) == "1,234,567"
    assert Format.format_count(-1_234_567) == "-1,234,567"
    assert Format.format_count(" 1234567 ") == "1,234,567"
    assert Format.format_count("12.5") == "12.5"
    assert Format.format_count(:unknown) == "unknown"
  end

  test "truncate shortens binary values and preserves other terms" do
    assert Format.truncate("abcdef", 3) == "abc..."
    assert Format.truncate("abc", 3) == "abc"
    assert Format.truncate(nil, 3) == nil
  end
end
