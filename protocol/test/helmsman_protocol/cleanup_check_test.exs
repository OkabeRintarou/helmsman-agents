defmodule HelmsmanProtocol.CleanupCheckTest do
  use ExUnit.Case, async: true
  alias HelmsmanProtocol.{CleanupItem, CleanupResult, ErrorReply, Messages, Reply, Report}

  test "request and corresponding reply roundtrip at cleanup version" do
    items = [%{workspace_id: 7, ident: "bos-12"}, %{workspace_id: 7, ident: "BOS-13"}]
    assert {:ok, request} = Report.CleanupCheck.new(items: items)
    assert [%CleanupItem{} | _] = request.items
    assert {:ok, {"cleanup_check", wire}} = Messages.encode(request)
    assert {:ok, ^request} = Messages.decode("cleanup_check", wire)

    results =
      Enum.map(
        items,
        &Map.merge(&1, %{
          deletable: true,
          base_branch: nil,
          pushed_heads: [String.duplicate("a", 40)]
        })
      )

    assert {:ok, reply} = Reply.CleanupCheck.new(results: results)
    assert [%CleanupResult{} | _] = reply.results
    assert {:ok, wire} = Messages.encode_reply("cleanup_check", reply)
    assert {:ok, ^reply} = Messages.decode_reply("cleanup_check", wire)

    for version <- 1..(HelmsmanProtocol.cleanup_version() - 1) do
      assert {:error, {:not_in_version, ^version}} = Messages.encode(request, version)

      assert {:error, {:not_in_version, ^version}} =
               Messages.encode_reply("cleanup_check", reply, version)

      {:ok, error} = ErrorReply.new(:wrong_state, "unavailable")

      assert {:error, {:not_in_version, ^version}} =
               Messages.encode_reply("cleanup_check", error, version)
    end
  end

  test "batch boundaries and strict commit evidence" do
    item = %{"workspace_id" => 7, "ident" => "bos-12"}

    for count <- [0, 501] do
      assert {:error, {:invalid_payload, ["items"], {:count, 1, 500}}} =
               Messages.decode("cleanup_check", %{"items" => List.duplicate(item, count)})
    end

    assert {:ok, _} = Messages.decode("cleanup_check", %{"items" => List.duplicate(item, 500)})

    result =
      Map.merge(item, %{"deletable" => true, "base_branch" => "main", "pushed_heads" => []})

    for sha <- ["abc", String.duplicate("A", 40), String.duplicate("g", 40)] do
      assert {:error, {:invalid_payload, ["results", 0, "pushed_heads", 0], :type}} =
               Messages.decode_reply("cleanup_check", %{
                 "results" => [Map.put(result, "pushed_heads", [sha])]
               })
    end

    assert {:error, {:invalid_payload, ["results", 0, "pushed_heads"], {:count, 0, 200}}} =
             Messages.decode_reply("cleanup_check", %{
               "results" => [
                 Map.put(result, "pushed_heads", List.duplicate(String.duplicate("a", 40), 201))
               ]
             })
  end
end
