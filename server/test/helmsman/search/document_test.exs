defmodule Helmsman.Search.DocumentTest do
  # add-fulltext-search 1.3: the column values (decision 4) and the
  # tsquery text (decision 6).
  use Helmsman.DataCase, async: true

  alias Helmsman.Search.{Document, Query}

  defp positions(lexemes), do: Map.new(lexemes, &{&1.word, &1.positions})

  defp task(attrs) do
    Document.task(Map.merge(%{ident: "BOS-1", labels: [], title: "", description: ""}, attrs))
  end

  defp as_text(lexemes) do
    %{rows: [[text]]} = Repo.query!("SELECT $1::tsvector::text", [lexemes])
    text
  end

  describe "task/1" do
    test "fields from position 1, ten positions apart, weights A and B" do
      assert positions(task(%{title: "fix login", description: "timeout"})) == %{
               "bos-1" => [{1, :A}],
               "bos" => [{1, :A}],
               "1" => [{1, :A}],
               "fix" => [{11, :A}],
               "login" => [{12, :A}],
               "timeout" => [{22, :B}]
             }
    end

    test "labels one after the other, between ID and title" do
      assert positions(task(%{labels: ["ui", "db"], title: "x"})) |> Map.take(["ui", "db", "x"]) ==
               %{"ui" => [{11, :A}], "db" => [{12, :A}], "x" => [{22, :A}]}
    end

    test "empty fields take no positions" do
      lexemes = task(%{ident: "BOS-1", labels: [], title: "x", description: ""})
      assert positions(lexemes)["x"] == [{11, :A}]
      assert positions(task(%{labels: nil, title: "", description: "y"}))["y"] == [{11, :B}]
      assert positions(Document.build([{[""], :A}, {["z"], :C}])) == %{"z" => [{1, :C}]}
    end

    test "a term's positions are merged and sorted" do
      assert positions(task(%{title: "bos x", description: "bos"}))["bos"] ==
               [{1, :A}, {11, :A}, {22, :B}]
    end

    test "positions above 16383 are left out; a term left without any has none" do
      filler = String.duplicate("w ", 16_400)
      lexemes = Document.feedback("first " <> filler <> "late first")
      by_word = positions(lexemes)

      assert by_word["first"] == [{1, :C}]
      assert by_word["late"] == []
      assert Enum.all?(by_word["w"], fn {pos, _} -> pos <= 16_383 end)
      assert as_text(lexemes) =~ "'late' "
    end

    test "at most 256 positions per term" do
      by_word = positions(Document.feedback(String.duplicate("w ", 300)))
      assert length(by_word["w"]) == 256
      assert hd(by_word["w"]) == {1, :C}
    end

    test "PostgreSQL reads the value as built" do
      lexemes = task(%{title: "Fix 任务管理", description: "it's"})

      assert as_text(lexemes) ==
               "'1':1A 'bos':1A 'bos-1':1A 'fix':11A 'it':24B 's':25B " <>
                 "'任务':12A '务管':13A '管理':14A"
    end
  end

  describe "feedback/1" do
    test "content weighted C from position 1" do
      assert positions(Document.feedback("deadlock again")) ==
               %{"deadlock" => [{1, :C}], "again" => [{2, :C}]}
    end
  end

  describe "Query" do
    test "parse/1" do
      assert {:ok, :blank} = Query.parse("  \n ")
      assert {:ok, [{:prefix, "x"}]} = Query.parse(" x ")
      assert {:ok, []} = Query.parse("the")
      assert {:ok, _} = Query.parse(String.duplicate("x", 200))
      assert {:error, {:invalid_query, :too_long}} = Query.parse(String.duplicate("x", 201))
      assert {:error, {:invalid_query, :not_a_string}} = Query.parse(12)
    end

    test "to_tsquery/1" do
      assert Query.to_tsquery([]) == nil

      assert Query.to_tsquery([
               {:term, "fix"},
               {:phrase, ["任务", "务管", "管理"]},
               {:prefix, "deadl"}
             ]) == "'fix' & ('任务' <-> '务管' <-> '管理') & 'deadl':*"
    end

    test "quotes and backslashes survive PostgreSQL's parser" do
      text = Query.to_tsquery([{:term, "it's"}, {:prefix, "a\\b"}, {:phrase, ["x'", "\\'"]}])
      %{rows: [[parsed]]} = Repo.query!("SELECT $1::text::tsquery::text", [text])
      assert parsed == ~S('it''s' & 'a\\b':* & 'x''' <-> '\\''')

      %{rows: [[matched]]} =
        Repo.query!("SELECT $1::tsvector @@ $2::text::tsquery", [
          [
            %Postgrex.Lexeme{word: "it's", positions: [{1, nil}]},
            %Postgrex.Lexeme{word: "a\\bc", positions: [{2, nil}]},
            %Postgrex.Lexeme{word: "x'", positions: [{3, nil}]},
            %Postgrex.Lexeme{word: "\\'", positions: [{4, nil}]}
          ],
          text
        ])

      assert matched
    end
  end

  describe "短语不跨字段" do
    test "a title ending with 登 and a description starting with 录 do not match 登录" do
      lexemes = task(%{title: "修复登", description: "录超时"})
      {:ok, groups} = Query.parse("登录")

      %{rows: [[matched]]} =
        Repo.query!("SELECT $1::tsvector @@ $2::text::tsquery", [
          lexemes,
          Query.to_tsquery(groups)
        ])

      refute matched
    end
  end
end
