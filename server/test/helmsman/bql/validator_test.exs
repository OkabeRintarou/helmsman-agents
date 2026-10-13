defmodule Helmsman.BQL.ValidatorTest do
  use ExUnit.Case, async: true
  alias Helmsman.BQL

  test "malformed ASTs are controlled input errors" do
    condition = {:cond, :status, :eq, "new"}

    bad_nodes = [
      false,
      {:not, true},
      {:and, []},
      {:or, [condition]},
      {:and, [condition | :tail]},
      {:cond, :workspace_id, :eq, 1},
      {:cond, :status, :eq, "closed"},
      {:cond, :status, :match, "new"},
      {:cond, :status, :eq, "NEW"},
      {:cond, "status", :eq, "new"},
      {:cond, :feedback_count, :eq, -1},
      {:cond, :feedback_count, :eq, "1"},
      {:cond, :labels, :in, []},
      {:cond, :labels, :in, ["a" | :tail]},
      {:cond, :labels, :in, List.duplicate("a", 101)},
      {:cond, :title, :eq, <<255>>},
      {:cond, :title, :eq, String.duplicate("x", 4001)},
      {:cond, :title, :eq, :current_user},
      {:cond, :assignee, :match, :current_user},
      {:cond, :labels, :empty, false},
      {:cond, :created, :gte, ~D[2026-01-01]},
      {:cond, :created, :gte, %{~U[2026-01-01 00:00:00Z] | month: 99}},
      {:and, List.duplicate(condition, 65)},
      Enum.reduce(1..33, condition, fn _, child -> {:not, child} end)
    ]

    for node <- bad_nodes do
      assert {:error, {:invalid_bql, %{message: message, position: 1}}} =
               BQL.validate_ast(%{where: node, order: []})

      assert is_binary(message)
    end

    for order <- [
          nil,
          [{:status, :up}],
          [{:workspace_id, :asc}],
          [{:labels, :asc}],
          List.duplicate({:id, :asc}, 6),
          [{:id, :asc} | :tail]
        ] do
      assert {:error, {:invalid_bql, _}} = BQL.validate_ast(%{where: true, order: order})
    end

    assert {:error, {:invalid_bql, _}} = BQL.validate_ast(%{})
    assert {:error, {:invalid_bql, _}} = BQL.validate_ast(%{where: true, order: [], extra: true})
  end

  test "Unicode lowercase expansion stays within the AST payload budget" do
    for codepoint <- 0..0x10FFFF, codepoint not in 0xD800..0xDFFF do
      lower = String.downcase(<<codepoint::utf8>>)
      size = length(String.codepoints(lower))

      assert size == if(codepoint == 0x0130, do: 2, else: 1),
             "U+#{Integer.to_string(codepoint, 16)}"
    end
  end

  test "AST strings have a cumulative 4000-codepoint budget; integers retain arbitrary precision" do
    for n <- [2000, 4000] do
      ast = %{where: {:cond, :title, :eq, String.duplicate("x", n)}, order: []}
      assert {:ok, ^ast} = BQL.validate_ast(ast)
    end

    ast = %{
      where:
        {:and,
         [
           {:cond, :title, :eq, String.duplicate("x", 2001)},
           {:cond, :labels, :in, [String.duplicate("x", 2000)]}
         ]},
      order: []
    }

    assert {:error, {:invalid_bql, %{message: "query is too long", position: 1}}} =
             BQL.validate_ast(ast)

    ast = %{where: {:cond, :feedback_count, :eq, Integer.pow(10, 5000)}, order: []}
    assert {:ok, ^ast} = BQL.validate_ast(ast)
  end

  test "all field/operator canonical outputs validate, including list and identity values" do
    for query <- [
          "",
          "ORDER BY id",
          "assignee IN (currentUser(), alice)",
          "status NOT IN (new, done)",
          "created > -7d",
          "labels IS EMPTY",
          Enum.map_join(1..64, " OR ", fn _ -> "status=new" end)
        ] do
      assert {:ok, ast} = BQL.parse(query)
      assert {:ok, ^ast} = BQL.validate_ast(ast)
    end
  end

  test "only necessary precedence parentheses contribute nesting" do
    condition = {:cond, :status, :eq, "new"}
    group = {:or, [condition, {:cond, :priority, :eq, "high"}]}
    accepted = Enum.reduce(1..31, group, fn _, child -> {:not, child} end)
    assert {:ok, _} = BQL.validate_ast(%{where: accepted, order: []})

    assert {:error, {:invalid_bql, %{message: "too much nesting (at most 32)"}}} =
             BQL.validate_ast(%{where: {:not, accepted}, order: []})

    # Associative groups are flattened, so NOT does not need redundant pairs
    # of parentheses for each same-operator child.
    nested = {:and, [condition, {:and, [condition, condition]}]}

    assert {:ok, %{where: {:and, [^condition, ^condition, ^condition]}} = normalized} =
             BQL.validate_ast(%{where: nested, order: []})

    assert {:ok, ^normalized} = BQL.parse(BQL.to_string(normalized))
  end
end
