defmodule HelmsmanWeb.UrlTest do
  alias Plug.Conn.Query
  use ExUnit.Case, async: true
  doctest HelmsmanWeb.Url

  alias HelmsmanWeb.Url

  test "keeps array params and other values" do
    uri = "/w/acme/tasks?label[]=api,backend&label[]=ui&q=x"
    opened = Url.put_params(uri, %{panel: "new"})
    assert Url.drop_params(opened, [:panel]) == Url.drop_params(uri, [])
    assert Query.decode(URI.parse(opened).query)["label"] == ["api,backend", "ui"]
    assert Url.drop_params("/w/acme/tasks?panel=new", ["panel"]) == "/w/acme/tasks"
  end

  describe "agent_path/2" do
    test "keeps the name's slashes as path separators" do
      assert Url.agent_path("acme", "keel/dev") == "/w/acme/agents/keel/dev"
      assert Url.agent_path("acme", "dev") == "/w/acme/agents/dev"
    end

    test "names with empty segments are one encoded segment that routes back to the name" do
      for name <- ["keel//dev", "keel/dev/", "/keel"] do
        path = Url.agent_path("acme", name)
        assert path == "/w/acme/agents/" <> String.replace(name, "/", "%2F")
        "/w/acme/agents/" <> rest = path
        segments = rest |> String.split("/") |> Enum.map(&URI.decode/1)
        assert Url.agent_name(segments) == name
      end
    end
  end
end
