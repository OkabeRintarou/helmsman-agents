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
end
