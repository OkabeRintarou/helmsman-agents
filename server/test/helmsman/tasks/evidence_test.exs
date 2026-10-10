defmodule Helmsman.Tasks.EvidenceTest do
  use ExUnit.Case, async: true

  alias Helmsman.Tasks.Evidence

  doctest Evidence

  @tests %{command: "mix test", passed: true, summary: "ok"}

  test "no evidence" do
    assert Evidence.normalize(%{}) == {:ok, %{comment: nil, commits: [], tests: nil}}
    assert Evidence.normalize([]) == {:ok, %{comment: nil, commits: [], tests: nil}}
  end

  describe "commits" do
    test "are downcased and deduplicated, first occurrence first" do
      assert {:ok, %{commits: ["abc1234", "def5678"]}} =
               Evidence.normalize(%{commits: ["ABC1234", "abc1234", "def5678"]})
    end

    test "an invalid commit is reported" do
      assert Evidence.normalize(%{commits: ["xyz"]}) == {:error, {:invalid_commits, "xyz"}}

      assert Evidence.normalize(%{commits: ["abc1234", 1_234_567]}) ==
               {:error, {:invalid_commits, 1_234_567}}

      for commits <- [[nil], ["abc1234", nil], [nil, "xyz"], ["abc1234", nil, 1]] do
        assert Evidence.normalize(%{commits: commits}) == {:error, {:invalid_commits, nil}},
               inspect(commits)
      end

      assert Evidence.normalize(%{commits: "abc1234"}) ==
               {:error, {:invalid_commits, "abc1234"}}
    end

    test "must have 7 to 64 hexadecimal characters" do
      for bad <- [String.duplicate("a", 6), String.duplicate("a", 65), "abc123g"] do
        assert Evidence.normalize(%{commits: [bad]}) == {:error, {:invalid_commits, bad}}
      end

      for ok <- [String.duplicate("a", 7), String.duplicate("F", 64)] do
        assert {:ok, %{commits: [_]}} = Evidence.normalize(%{commits: [ok]})
      end
    end
  end

  describe "tests" do
    test "keep command, passed and summary only, with string keys" do
      assert {:ok, %{tests: %{"command" => "mix test", "passed" => true, "summary" => "ok"}}} =
               Evidence.normalize(%{tests: Map.put(@tests, :extra, "dropped")})

      assert {:ok, %{tests: %{"passed" => false}}} =
               Evidence.normalize(%{
                 "tests" => %{"command" => "x", "passed" => false, "summary" => ""}
               })
    end

    test "passed must be a boolean" do
      assert Evidence.normalize(%{tests: %{@tests | passed: "yes"}}) ==
               {:error, {:invalid_tests, {:passed, :not_a_boolean}}}

      assert Evidence.normalize(%{tests: Map.delete(@tests, :passed)}) ==
               {:error, {:invalid_tests, {:passed, :not_a_boolean}}}
    end

    test "command and summary are strings of at most 2000 characters" do
      long = String.duplicate("é", 2001)

      assert Evidence.normalize(%{tests: %{@tests | command: long}}) ==
               {:error, {:invalid_tests, {:command, :too_long}}}

      assert Evidence.normalize(%{tests: %{@tests | summary: long}}) ==
               {:error, {:invalid_tests, {:summary, :too_long}}}

      assert {:ok, _} =
               Evidence.normalize(%{tests: %{@tests | command: String.duplicate("é", 2000)}})

      assert Evidence.normalize(%{tests: Map.delete(@tests, :summary)}) ==
               {:error, {:invalid_tests, {:summary, :not_a_string}}}
    end

    test "must be an object" do
      assert Evidence.normalize(%{tests: "passed"}) == {:error, {:invalid_tests, :not_an_object}}
      assert Evidence.normalize(%{tests: [@tests]}) == {:error, {:invalid_tests, :not_an_object}}
    end
  end

  describe "comment" do
    test "at most 10000 characters" do
      ok = String.duplicate("é", 10_000)
      assert {:ok, %{comment: ^ok}} = Evidence.normalize(%{comment: ok})

      assert Evidence.normalize(%{comment: ok <> "x"}) ==
               {:error, {:invalid_comment, :too_long}}
    end

    test "empty means none; anything but a string is refused" do
      assert {:ok, %{comment: nil}} = Evidence.normalize(%{comment: ""})
      assert Evidence.normalize(%{comment: 1}) == {:error, {:invalid_comment, :not_a_string}}
    end
  end
end
