defmodule Helmsman.Backup.FormatTest do
  use ExUnit.Case, async: true
  alias Helmsman.Backup.Format

  test "keys are sorted recursively and UTC timestamps have six places" do
    assert Format.encode(%{"z" => 1, "a" => %{"c" => 2, "b" => [true, nil]}}) ==
             ~s({"a":{"b":[true,null],"c":2},"z":1})

    assert Format.time(~U[2026-01-01 00:00:00Z]) == "2026-01-01T00:00:00.000000Z"

    for {kind, fields} <- Format.fields() do
      encoded = Format.encode(Map.new(fields, &{&1, nil}))
      assert Format.encode(Jason.decode!(encoded)) == encoded
      assert File.read!("../docs/EXPORT-FORMAT.md") =~ "| #{kind} | #{Enum.join(fields, ", ")} |"
    end
  end

  test "each portable record has a stable encoding snapshot" do
    snapshots = [
      {"source", ~s({"app_version":"1.0.0","host":"example.invalid"})},
      {"workspace", ~s({"name":"Synthetic","slug":"synthetic"})},
      {"actors", ~s({"disabled":false,"kind":"agent","name":"alice/dev","owner":"alice"})},
      {"projects",
       ~s({"archived_at":null,"created_at":"2026-01-01T00:00:00.123456Z","description":"Synthetic","key":"BOS","name":"Project","spec_finalize":"approval","task_seq":12,"updated_at":"2026-01-01T00:00:00.123456Z"})},
      {"tasks",
       ~s({"assignee":"alice/dev","created_at":"2026-01-01T00:00:00.123456Z","created_by":"alice","description":"Line 1\\n你好","epic":null,"id":"BOS-2","kind":"task","labels":["z","a"],"priority":"high","project":"BOS","seq":2,"status":"new","title":"Synthetic","updated_at":"2026-01-01T00:00:00.123456Z"})},
      {"task_events",
       ~s({"actor":"alice","assignee_side":["alice/dev","alice"],"at":"2026-01-01T00:00:00.123456Z","auto":false,"auto_reason":null,"comment":"Created","commits":["abcdef0"],"feedback":"BOS-2#1","from":null,"n":1,"task":"BOS-2","tests":{"command":"mix test","passed":true,"summary":"ok"},"to":"new","verified_sha":null})},
      {"feedback",
       ~s({"at":"2026-01-01T00:00:00.123456Z","author":"alice","content":"Synthetic question?","fallback":false,"id":"BOS-2#1","kind":"question","mentions":["alice/dev"],"reply_root":null,"reply_to":null,"status":"active","superseded_by":null,"supersedes":null,"thread":1})},
      {"links",
       ~s({"actor":"alice","at":"2026-01-01T00:00:00.123456Z","from":"BOS-2","to":"BOS-1","type":"depends_on"})},
      {"saved_filters", ~s({"bql":"status = new","name":"New tasks","owner":"alice"})}
    ]

    for {kind, expected} <- snapshots do
      assert {:ok, record} = Format.decode(expected)
      assert Enum.sort(Map.keys(record)) == Format.fields()[kind]
      assert Format.encode(record) == expected

      typed =
        Map.new(record, fn {key, value} ->
          if key in ~w(created_at updated_at at) do
            {:ok, time, 0} = DateTime.from_iso8601(value)
            {key, time}
          else
            {key, value}
          end
        end)

      assert Format.encode(typed) == expected
    end
  end
end
