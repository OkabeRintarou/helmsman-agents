defmodule Helmsman.BQL.ParserTest do
  use ExUnit.Case, async: true
  alias Helmsman.BQL

  test "bosun grammar, precedence, aliases and unicode" do
    assert {:ok,
            %{
              order: [{:priority, :desc}, {:updated, :asc}],
              where: {:and, [_, {:or, _}, {:not, _}, _, _]}
            }} =
             BQL.parse(
               ~S|project = bos AND (status in (new, "in progress") OR priority >= high) and not labels ~ back and text ~ "创建 任务" and updated >= -7d order by priority desc, updated|
             )

    assert {:ok, %{where: true, order: [{:created, :desc}]}} = BQL.parse("ORDER BY created DESC")
    assert {:ok, %{where: true, order: []}} = BQL.parse("  ")

    for {q, condition} <- [
          {"labels is empty", {:cond, :labels, :empty, true}},
          {"feedback IS NOT EMPTY", {:cond, :feedback, :not_empty, true}},
          {"status not in (DONE, VERIFIED)", {:cond, :status, :not_in, ["done", "verified"]}},
          {"reporter = Keel", {:cond, :created_by, :eq, "keel"}},
          {"question = true", {:cond, :question, :eq, true}},
          {"text ~ 搜索", {:cond, :text, :match, "搜索"}},
          {"assignee IS NULL", {:cond, :assignee, :empty, true}}
        ],
        do: assert({:ok, %{where: condition, order: []}} == BQL.parse(q))

    assert {:ok, %{where: {:or, [_, {:and, [_, {:not, _}]}]}}} =
             BQL.parse("status = new OR status = done AND NOT labels = mcp")

    assert {:ok, %{where: {:cond, :title, :eq, "a\"b\\c\\z"}}} =
             BQL.parse(~S(title = "a\"b\\c\z"))
  end

  test "bosun errors have exact messages and codepoint positions" do
    for {query, message, position} <- [
          {"foo = 1", "unknown field 'foo'", 1},
          {"status = closed", "invalid status 'closed'", 10},
          {"(status = new", "expected ')'", 14},
          {"title ~ \"abc", "unterminated string", 9},
          {"status ~ new", "operator ~ not supported for status", 8},
          {"project > BOS", "operator > not supported for project", 9},
          {"created > yesterday", "invalid date 'yesterday'", 11},
          {"status = new new", "unexpected token 'new'", 14},
          {"status", "expected an operator", 7},
          {"order by nope", "unknown field 'nope' in ORDER BY", 10},
          {"ORDER BY labels", "field 'labels' cannot be used in ORDER BY", 10},
          {"text ~ 中文 new", "unexpected token 'new'", 11},
          {"title = new", "", 0},
          {"title = AND", "expected a value", 9}
        ],
        message != "" do
      assert {:error, {:invalid_bql, %{message: ^message, position: ^position}}} =
               BQL.parse(query)
    end
  end

  test "bounded grammar" do
    for {query, message} <- [
          {String.duplicate("x", 2001), "query is too long"},
          {Enum.map_join(1..65, " OR ", fn _ -> "status = new" end),
           "too many conditions (at most 64)"},
          {String.duplicate("(", 33) <> "status = new" <> String.duplicate(")", 33),
           "too much nesting (at most 32)"},
          {String.duplicate("NOT ", 33) <> "status = new", "too much nesting (at most 32)"},
          {"status IN (" <> Enum.map_join(1..101, ",", fn _ -> "new" end) <> ")",
           "too many IN values (at most 100)"},
          {"ORDER BY id,id,id,id,id,id", "too many ORDER BY fields (at most 5)"}
        ] do
      assert {:error, {:invalid_bql, %{message: ^message, position: pos}}} = BQL.parse(query)
      assert pos > 0
    end

    assert {:ok, _} =
             BQL.parse(String.duplicate("(", 32) <> "status = new" <> String.duplicate(")", 32))

    assert {:error, {:invalid_bql, _}} = BQL.parse(<<255>>)
  end
end
