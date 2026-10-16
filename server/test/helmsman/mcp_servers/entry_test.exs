defmodule Helmsman.McpServers.EntryTest do
  use ExUnit.Case, async: true
  alias Helmsman.McpServers.Entry

  test "valid transport fields, byte and count boundaries" do
    for entry <- [
          %{
            "command" => "npx",
            "args" => ["-y"],
            "env" => %{"KEY" => "${env:LOCAL_KEY}"},
            "cwd" => "~/tools"
          },
          %{
            "type" => "http",
            "url" => "https://example.com/mcp",
            "headers" => %{"X-Key" => "secret"}
          },
          %{"type" => "sse", "url" => "http://localhost:9000"},
          %{"command" => String.duplicate("x", 1024), "args" => List.duplicate("", 64)}
        ] do
      assert {:ok, %{"docs" => ^entry}} = Entry.validate(%{"docs" => entry})
    end

    for {entry, field} <- [
          {%{"type" => "http"}, "docs.url"},
          {%{"command" => ""}, "docs.command"},
          {%{"command" => String.duplicate("x", 1025)}, "docs.command"},
          {%{"command" => "npx", "args" => List.duplicate("x", 65)}, "docs.args"},
          {%{"command" => "npx", "args" => [String.duplicate("x", 4097)]}, "docs.args.0"},
          {%{"command" => "npx", "cwd" => "relative"}, "docs.cwd"},
          {%{"type" => "http", "url" => "/relative"}, "docs.url"},
          {%{"type" => "bad"}, "docs.type"},
          {%{"command" => "npx", "env" => %{"1X" => "secret"}}, "docs.env"},
          {%{"command" => "npx", "env" => %{"X" => String.duplicate("x", 8193)}}, "docs.env.X"},
          {%{
             "type" => "http",
             "url" => "https://a.test",
             "headers" => %{"Bad Header" => "secret"}
           }, "docs.headers"}
        ] do
      assert {:error, errors} = Entry.validate(%{"docs" => entry})
      assert List.keymember?(errors, field, 0)
      refute inspect(errors) =~ "secret"
    end
  end

  test "name rules, case collisions, configuration size and reserved references" do
    for name <- ["", "my docs", "helmsman", "Helmsman", String.duplicate("a", 65)] do
      assert {:error, _} = Entry.validate(%{name => %{"command" => "npx"}})
    end

    assert {:error, _} =
             Entry.validate(%{"Docs" => %{"command" => "npx"}, "docs" => %{"command" => "npx"}})

    assert {:error, _} =
             Entry.validate(%{
               "docs" => %{"command" => "npx", "auth" => String.duplicate("x", 32_768)}
             })

    for field <- ["command", "url", "cwd"] do
      assert {:error, errors} =
               Entry.validate(%{
                 "docs" => %{"command" => "npx", field => "${env:HELMSMAN_RUN_TOKEN}"}
               })

      assert Enum.any?(errors, fn {_, message} -> message =~ "cannot be referenced" end)
    end

    assert Entry.references(%{
             "args" => ["${env:A}-${env:B}", "${env:A}"],
             "auth" => %{"x" => "${env:C}"}
           })
           |> Enum.sort() == ~w(A B C)
  end

  test "opaque fields are hidden, preserved, deleted and replaced; extension types are checked" do
    old = %{
      "docs" => %{
        "type" => "http",
        "url" => "https://a.test",
        "headers" => %{"X-Key" => "canary1", "Authorization" => "Bearer ${env:TOKEN}"},
        "http_headers" => %{"X" => "canary2"},
        "auth" => %{"secret" => "canary3"},
        "unknown" => ["canary4"],
        "tools" => ["*"],
        "timeout" => 3,
        "enabled" => true,
        "disabled_tools" => %{"canary5" => true}
      }
    }

    editable = Entry.editable(old)
    for i <- 1..5, do: refute(inspect(editable) =~ "canary#{i}")
    assert editable["docs"]["tools"] == ["*"]
    assert editable["docs"]["headers"]["Authorization"] == "Bearer ${env:TOKEN}"
    attrs = %{"renamed" => editable["docs"] |> Map.put("url", "https://b.test")}
    assert {:ok, merged} = Entry.validate(attrs, old)
    assert merged["renamed"]["auth"] == old["docs"]["auth"]
    assert merged["renamed"]["headers"]["X-Key"] == "canary1"

    attrs =
      Map.update!(
        attrs,
        "renamed",
        &(&1 |> Map.delete("auth") |> Map.put("unknown", ["replacement"]))
      )

    assert {:ok, merged} = Entry.validate(attrs, old)
    refute Map.has_key?(merged["renamed"], "auth")
    assert merged["renamed"]["unknown"] == ["replacement"]
    assert {:error, errors} = Entry.validate(attrs)
    assert Enum.any?(errors, fn {_, error} -> error == "no stored value to keep" end)
    refute inspect(errors) =~ "canary"
  end

  test "empty replacements, JSON shape, and every count/value boundary" do
    assert {:ok, nil} = Entry.validate(nil)
    assert {:ok, %{}} = Entry.validate(%{})
    assert {:error, _} = Entry.validate([])
    assert {:error, _} = Entry.validate(%{%{} => %{"command" => "npx"}})
    assert {:error, _} = Entry.validate(%{"docs" => []})
    assert {:ok, _} = Entry.validate(%{String.duplicate("A", 64) => %{"command" => "npx"}})

    for {field, max, entry} <- [
          {"env", 64, %{"command" => "npx"}},
          {"headers", 32, %{"type" => "http", "url" => "https://a.test"}}
        ] do
      valid = Map.new(1..max, &{"KEY#{&1}", ""})
      assert {:ok, _} = Entry.validate(%{"docs" => Map.put(entry, field, valid)})

      assert {:error, _} =
               Entry.validate(%{"docs" => Map.put(entry, field, Map.put(valid, "EXTRA", ""))})

      for value <- [nil, [], %{}, 1, true, String.duplicate("v", 8193)] do
        assert {:error, errors} =
                 Entry.validate(%{"docs" => Map.put(entry, field, %{"KEY" => value})})

        assert List.keymember?(errors, "docs.#{field}.KEY", 0)
      end

      assert {:ok, _} =
               Entry.validate(%{
                 "docs" => Map.put(entry, field, %{"KEY" => String.duplicate("v", 8192)})
               })
    end

    base = "https://example.test/"
    url = base <> String.duplicate("x", 2048 - byte_size(base))
    assert {:ok, _} = Entry.validate(%{"docs" => %{"url" => url}})
    assert {:error, _} = Entry.validate(%{"docs" => %{"url" => url <> "x"}})
    assert {:error, _} = Entry.validate(%{"docs" => %{"url" => "ftp://a.test"}})

    assert {:ok, _} =
             Entry.validate(%{
               "docs" => %{"command" => "npx", "args" => [String.duplicate("x", 4096)]}
             })

    assert {:error, _} = Entry.validate(%{"docs" => %{"command" => "npx", "args" => [1]}})
  end
end
