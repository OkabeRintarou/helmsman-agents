defmodule HelmsmanWeb.FiltersTest do
  alias Plug.Conn.Query
  use ExUnit.Case, async: true

  alias HelmsmanWeb.Filters

  @statuses ~w(new in_progress done verified rejected cancelled)
  @schema [status: {:list, @statuses}, label: :list, q: :string]

  test "parse/2 reads comma lists, drops unknown values and empty dimensions" do
    params = %{"status" => "new,bogus,in_progress", "label" => "api", "q" => "  ", "other" => "x"}
    assert Filters.parse(params, @schema) == %{status: ["new", "in_progress"], label: ["api"]}
  end

  test "to_query/1 and path/2" do
    filters = %{status: ["new", "in_progress"], label: ["api"]}
    assert Filters.to_query(filters) == %{"status" => "new,in_progress", "label" => "api"}

    assert Filters.path("/w/acme/tasks", filters) ==
             "/w/acme/tasks?label=api&status=new%2Cin_progress"

    assert Filters.path("/w/acme/tasks", %{}) == "/w/acme/tasks"
  end

  test "values containing commas survive the URL round trip" do
    filters = %{label: ["api,backend", "ui", "前端"], status: ["new"]}
    query = Filters.to_query(filters)

    assert query["label"] == ["api,backend", "ui", "前端"]
    assert query["status"] == "new"

    path = Filters.path("/w/acme/tasks", filters)
    %URI{query: qs} = URI.parse(path)
    assert Filters.parse(Query.decode(qs), @schema) == filters

    removed = Filters.path("/w/acme/tasks", Map.delete(filters, :status))
    %URI{query: qs} = URI.parse(removed)

    assert Filters.parse(Query.decode(qs), @schema) == %{
             label: ["api,backend", "ui", "前端"]
           }
  end

  test "toggle/3" do
    assert Filters.toggle(%{}, :label, "api") == %{label: ["api"]}
    assert Filters.toggle(%{label: ["api"]}, :label, "api") == %{}
    assert Filters.toggle(%{label: ["api"]}, :label, "ui") == %{label: ["api", "ui"]}
  end

  # Round-trip property: parse(to_query(f)) == f for every filter map parse/2 can produce.
  test "parse ∘ to_query is the identity on parsed filters" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..500 do
      filters = random_filters()
      query = Filters.to_query(filters)
      assert Filters.parse(query, @schema) == filters
      %URI{query: qs} = URI.parse(Filters.path("/x", filters))
      assert Filters.parse(Query.decode(qs || ""), @schema) == filters
    end
  end

  defp random_filters do
    %{
      status: @statuses |> Enum.shuffle() |> Enum.take(:rand.uniform(7) - 1),
      label: for(_ <- 1..(:rand.uniform(4) - 1)//1, do: random_word()) |> Enum.uniq(),
      q: if(:rand.uniform(2) == 1, do: random_word() <> " " <> random_word(), else: "")
    }
    |> Map.reject(fn {_k, v} -> v in ["", []] end)
  end

  defp random_word do
    alphabet = Enum.concat([?a..?z, ?0..?9, ~c"-_:/,&=[]%+中文"])
    for(_ <- 1..:rand.uniform(6)//1, into: "", do: <<Enum.random(alphabet)::utf8>>)
  end
end
