defmodule MediaAssist.DiscoveryTest do
  use ExUnit.Case, async: true

  alias MediaAssist.Discovery

  describe "parse_titles/1" do
    test "parses clean and messy LLM output, deduping by title" do
      content = """
      Dark City (1998)
      1. Gattaca (1997)
      - Minority Report (2002)
      * dark city (1998)
      Not a movie line
      Upgrade (2018) — a lean cyberpunk revenge thriller
      """

      assert Discovery.parse_titles(content) == [
               {"Dark City", 1998},
               {"Gattaca", 1997},
               {"Minority Report", 2002},
               {"Upgrade", 2018}
             ]
    end

    test "returns [] for unparseable output" do
      assert Discovery.parse_titles("I'm sorry, I can't help with that.") == []
    end
  end

  describe "cosine/2" do
    test "identical, orthogonal, and zero vectors" do
      assert_in_delta Discovery.cosine([1.0, 0.0], [1.0, 0.0]), 1.0, 0.0001
      assert_in_delta Discovery.cosine([1.0, 0.0], [0.0, 1.0]), 0.0, 0.0001
      assert Discovery.cosine([0.0, 0.0], [1.0, 0.0]) == 0.0
    end
  end
end
