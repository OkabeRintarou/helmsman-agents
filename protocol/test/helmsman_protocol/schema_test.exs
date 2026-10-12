defmodule HelmsmanProtocol.SchemaTest.Child do
  @moduledoc false
  use HelmsmanProtocol.Schema
  field(:name, :string, max_bytes: 4)
end

defmodule HelmsmanProtocol.SchemaTest.Sample do
  @moduledoc false
  use HelmsmanProtocol.Schema
  field(:id, :pos_integer)
  field(:count, :non_neg_integer)
  field(:cost, :number)
  field(:text, :string, max_bytes: 4)
  field(:flag, :boolean)
  field(:kind, {:enum, [:one, :two]})
  field(:at, :datetime)
  field(:env, :string_map)
  field(:object, :json_object)
  field(:optional, :string, nullable: true)
  embeds(:child, HelmsmanProtocol.SchemaTest.Child)
  list(:children, HelmsmanProtocol.SchemaTest.Child, min: 1, max: 2)
  list(:tags, :string)
  list(:ids, :pos_integer)
  list(:kinds, {:enum, [:one, :two]})
end

defmodule HelmsmanProtocol.SchemaTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.SchemaTest.Sample

  defp payload do
    %{
      "id" => 1,
      "count" => 0,
      "cost" => 0.5,
      "text" => "你好",
      "flag" => true,
      "kind" => "one",
      "at" => "2026-10-12T07:00:00Z",
      "env" => %{"KEY" => "value"},
      "object" => %{"nested" => [1, true, nil, %{"x" => "y"}]},
      "optional" => nil,
      "child" => %{"name" => "a"},
      "children" => [%{"name" => "b"}],
      "tags" => ["one"],
      "ids" => [1],
      "kinds" => ["two"]
    }
    |> Map.put("text", "好")
  end

  test "all supported types roundtrip; unknown fields ignored; nullable omitted becomes null" do
    assert {:ok, sample} = Sample.from_wire(Map.put(payload(), "untrusted-new-key", "anything"))
    assert sample.kind == :one
    assert sample.at == ~U[2026-10-12 07:00:00Z]
    assert Sample.to_wire(sample) == payload()
    assert {:ok, ^sample} = Sample.new(Map.from_struct(sample))
    assert {:ok, ^sample} = Sample.new(Map.from_struct(sample) |> Map.to_list())
    assert {:ok, ^sample} = Sample.from_wire(Map.delete(payload(), "optional"))
    assert {:ok, with_optional} = Sample.from_wire(Map.put(payload(), "optional", "yes"))
    assert with_optional.optional == "yes"
    assert {:ok, _} = Sample.from_wire(Map.put(payload(), "cost", 0))
    assert {:error, {:invalid_payload, [], :type}} = Sample.from_wire([])
    assert {:error, {:invalid_payload, [], :type}} = Sample.new(["bad"])
  end

  test "missing, wrong types, enum, byte and list limits" do
    cases = [
      {"id", "1", :type},
      {"id", 0, :type},
      {"count", -1, :type},
      {"cost", -0.1, :type},
      {"cost", "1", :type},
      {"text", 7, :type},
      {"text", "hello", {:too_long, 4}},
      {"text", <<255>>, :type},
      {"flag", "true", :type},
      {"kind", "three", {:enum, [:one, :two]}},
      {"kind", :one, {:enum, [:one, :two]}},
      {"at", "bad", :type},
      {"at", "2026-10-12T08:00:00+01:00", :type},
      {"at", 1, :type},
      {"env", %{"KEY" => 1}, :type},
      {"env", %{key: "value"}, :type},
      {"env", [], :type},
      {"object", [], :type},
      {"object", %{"x" => self()}, :type},
      {"object", %{x: 1}, :type},
      {"optional", 1, :type},
      {"children", [], {:count, 1, 2}},
      {"children", List.duplicate(%{"name" => "a"}, 3), {:count, 1, 2}},
      {"children", %{}, :type}
    ]

    for {key, value, reason} <- cases do
      assert {:error, {:invalid_payload, [^key], ^reason}} =
               Sample.from_wire(Map.put(payload(), key, value))
    end

    for key <- Map.keys(payload()) -- ["optional"] do
      assert {:error, {:invalid_payload, [^key], :required}} =
               Sample.from_wire(Map.delete(payload(), key))

      assert {:error, {:invalid_payload, [^key], :type}} =
               Sample.from_wire(Map.put(payload(), key, nil))
    end
  end

  test "nested errors include list indices" do
    assert {:error, {:invalid_payload, ["child", "name"], :required}} =
             Sample.from_wire(Map.put(payload(), "child", %{}))

    assert {:error, {:invalid_payload, ["children", 1, "name"], {:too_long, 4}}} =
             Sample.from_wire(
               Map.put(payload(), "children", [%{"name" => "a"}, %{"name" => "long!"}])
             )

    for {key, bad} <- [{"tags", 1}, {"ids", 0}, {"kinds", "three"}] do
      assert {:error, {:invalid_payload, [^key, 0], _}} =
               Sample.from_wire(Map.put(payload(), key, [bad]))
    end
  end
end
