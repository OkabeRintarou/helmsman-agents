defmodule Helmsman.Search.TokenizerTest do
  # add-fulltext-search 1.2: the default tokenizer (decision 3).
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Helmsman.Search.Tokenizer
  alias Helmsman.Search.Tokenizer.Bigram

  defp terms(text), do: text |> Bigram.tokens() |> Enum.map(&{&1.term, &1.pos})

  describe "tokens/1 (task-search: 中英文分词)" do
    test "中文二元组: adjacent bigrams, consecutive positions" do
      assert terms("任务管理") == [{"任务", 0}, {"务管", 1}, {"管理", 2}]
    end

    test "连接符片段: the whole word and its fragments at one position" do
      assert terms("Feature-Search") ==
               [{"feature-search", 0}, {"feature", 0}, {"search", 0}]

      assert terms("BOS-12") == [{"bos-12", 0}, {"bos", 0}, {"12", 0}]
    end

    test "全角与大小写: NFKC, then downcased" do
      assert terms("ＢＵＧ") == [{"bug", 0}]
      assert terms("Ｆｉｘ１２") == [{"fix12", 0}]
    end

    test "停用词: not output, but they keep their position" do
      assert terms("the bug") == [{"bug", 1}]
      assert terms("a bug") == [{"bug", 1}]
      assert terms("登 的 录") == [{"登", 0}, {"录", 2}]
      assert terms("好了 了") == [{"好了", 0}]
      # Only on their own: inside a run they are part of the bigrams.
      assert terms("我的任务") == [{"我的", 0}, {"的任", 1}, {"任务", 2}]
    end

    test "the decision's example" do
      assert terms("Fix feature-search 任务管理") == [
               {"fix", 0},
               {"feature-search", 1},
               {"feature", 1},
               {"search", 1},
               {"任务", 2},
               {"务管", 3},
               {"管理", 4}
             ]
    end

    test "a single CJK character gives itself" do
      assert terms("登") == [{"登", 0}]
      assert terms("x 登 y") == [{"x", 0}, {"登", 1}, {"y", 2}]
    end

    test "Japanese kana and Korean are CJK" do
      assert terms("ひらがな") == [{"ひら", 0}, {"らが", 1}, {"がな", 2}]
      assert terms("カタカナ") == [{"カタ", 0}, {"タカ", 1}, {"カナ", 2}]
      assert terms("한국어") == [{"한국", 0}, {"국어", 1}]
      # The prolonged sound mark belongs to the kana run.
      assert terms("コーヒー") == [{"コー", 0}, {"ーヒ", 1}, {"ヒー", 2}]
      # Half-width kana with its voiced mark is one character, normalized.
      assert terms("ｶﾞｷﾞ") == [{"ガギ", 0}]
    end

    test "CJK punctuation separates runs" do
      assert terms("任务、管理") == [{"任务", 0}, {"管理", 1}]
      assert terms("任务。") == [{"任务", 0}]
    end

    test "CJK and Latin alternate with running positions" do
      assert terms("修复login超时") == [{"修复", 0}, {"login", 1}, {"超时", 2}]
    end

    test "/ and _ are connectors too" do
      assert terms("src/lib_foo") ==
               [{"src/lib_foo", 0}, {"src", 0}, {"lib", 0}, {"foo", 0}]

      assert terms("hm/BOS-12") ==
               [{"hm/bos-12", 0}, {"hm", 0}, {"bos", 0}, {"12", 0}]
    end

    test "leading, trailing and repeated connectors are separators" do
      assert terms("-foo-") == [{"foo", 0}]
      assert terms("_x_ /y/") == [{"x", 0}, {"y", 1}]
      assert terms("a--b") == [{"b", 1}]
      assert terms("foo--bar") == [{"foo", 0}, {"bar", 1}]
    end

    test "fragments equal to the whole word or repeated are output once" do
      assert terms("x-x") == [{"x-x", 0}, {"x", 0}]
    end

    test "other punctuation and symbols are separators" do
      assert terms("foo.bar,baz!(qux)") == [{"foo", 0}, {"bar", 1}, {"baz", 2}, {"qux", 3}]
      assert terms("it's") == [{"it", 0}, {"s", 1}]
      assert terms("") == []
      assert terms("  ...  ") == []
    end

    test "terms over 64 characters are not output; other fragments are" do
      long = String.duplicate("x", 65)
      ok = String.duplicate("y", 64)
      assert terms(long) == []
      assert terms(ok) == [{ok, 0}]
      assert terms("#{long} z") == [{"z", 1}]
      assert terms("#{long}-abc") == [{"abc", 0}]
    end

    test "the limit counts code points, not graphemes" do
      marks = "x" <> String.duplicate("\u0301", 2500)
      assert String.length(marks) == 1
      assert terms(marks) == []
      assert terms("#{marks}-abc deadlock") == [{"abc", 0}, {"deadlock", 1}]
      assert terms("x" <> String.duplicate("\u0301", 63)) |> length() == 1
      assert terms("x" <> String.duplicate("\u0301", 64)) == []
      # Marks after a CJK character are not CJK: an overlong run of their own.
      han = "任" <> String.duplicate("\u0301", 100)
      assert terms(han) == [{"任", 0}]
      assert terms(han <> "务管") == [{"任", 0}, {"务管", 2}]
    end

    test "the limit applies after NFKC" do
      # U+FDFA expands to 18 code points under NFKC.
      word = String.duplicate("\uFDFA", 4)
      assert String.length(word) == 4
      assert terms(word) == []
    end

    test "offsets point to the original text" do
      text = "ＢＵＧ 修复 feature-search"

      for %{term: term, start: start, len: len} <- Bigram.tokens(text) do
        source = binary_part(text, start, len)
        assert term == source |> :unicode.characters_to_nfkc_binary() |> String.downcase()
      end

      assert [%{start: 0, len: 9} | _] = Bigram.tokens(text)
    end

    test "the configured tokenizer is Bigram" do
      assert Tokenizer.impl() == Bigram
      assert Tokenizer.tokens("任务") == Bigram.tokens("任务")
    end
  end

  describe "query/1" do
    test "words are terms, the last one a prefix" do
      assert Bigram.query("fix login") == [{:term, "fix"}, {:prefix, "login"}]
      assert Bigram.query("deadl") == [{:prefix, "deadl"}]
    end

    test "a word with connectors is one group; its fragments are not" do
      assert Bigram.query("feature-search x") == [{:term, "feature-search"}, {:prefix, "x"}]
    end

    test "CJK runs: phrase, term or prefix by length" do
      assert Bigram.query("任务管理") == [{:phrase, ["任务", "务管", "管理"]}]
      assert Bigram.query("任务") == [{:term, "任务"}]
      assert Bigram.query("登") == [{:prefix, "登"}]
    end

    test "a CJK last group stays as it is" do
      assert Bigram.query("fix 任务") == [{:term, "fix"}, {:term, "任务"}]
    end

    test "stop words and duplicates are dropped" do
      assert Bigram.query("the bug the") == [{:prefix, "bug"}]
      assert Bigram.query("的") == []
      assert Bigram.query("the a") == []
      assert Bigram.query("bug bug x") == [{:term, "bug"}, {:prefix, "x"}]
    end

    test "at most 16 groups, the first ones" do
      words = Enum.map(1..20, &"w#{&1}")
      groups = Bigram.query(Enum.join(words, " "))
      assert length(groups) == 16
      assert groups == Enum.map(Enum.take(words, 16), &{:term, &1})
    end

    test "a word too long to be indexed whole searches its fragments" do
      long = String.duplicate("x", 65)
      assert Bigram.query("#{long}-abc-def") == [{:term, "abc"}, {:term, "def"}]
    end

    test "an overlong term never becomes a group" do
      marks = "x" <> String.duplicate("\u0301", 2500)
      assert Bigram.query(marks) == []
      assert Bigram.query("#{marks} deadl") == [{:prefix, "deadl"}]
      assert Bigram.query("#{marks}-abc") == [{:term, "abc"}]
      assert Bigram.query("任" <> String.duplicate("\u0301", 100)) == [{:prefix, "任"}]
    end

    test "nothing to search for" do
      assert Bigram.query("") == []
      assert Bigram.query(" ,.!") == []
    end
  end

  describe "properties" do
    property "positions never decrease and offsets stay inside the text" do
      check all text <- string(:printable, max_length: 80), max_runs: 300 do
        tokens = Bigram.tokens(text)
        positions = Enum.map(tokens, & &1.pos)
        assert positions == Enum.sort(positions)

        for %{start: start, len: len} <- tokens do
          assert start >= 0 and len > 0 and start + len <= byte_size(text)
        end
      end
    end

    property "every term is its source, normalized" do
      check all parts <-
                  list_of(
                    one_of([
                      string(:printable, max_length: 12),
                      string(Enum.concat([?一..?龥, ?ぁ..?ん, ?ァ..?ン, ?가..?힣]),
                        max_length: 8
                      ),
                      string(0x0300..0x036F, max_length: 100),
                      member_of(["-", "_", "/", " ", "ー", "ＢＵＧ", "\u0301", "ﾞ", "\uFDFA"])
                    ]),
                    max_length: 8
                  ),
                max_runs: 300 do
        text = Enum.join(parts)

        for %{term: term, start: start, len: len} <- Bigram.tokens(text) do
          source = binary_part(text, start, len)
          assert term == source |> :unicode.characters_to_nfkc_binary() |> String.downcase()
          assert length(String.codepoints(term)) <= 64
        end
      end
    end
  end
end
