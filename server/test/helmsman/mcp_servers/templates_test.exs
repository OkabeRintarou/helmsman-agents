defmodule Helmsman.McpServers.TemplatesTest do
  use ExUnit.Case, async: true
  alias Helmsman.McpServers.{Entry, Templates}

  test "every starter validates and declares exactly its local credential references" do
    templates = Templates.all()

    assert Enum.map(templates, & &1.name) ==
             ~w(github github-local playwright filesystem fetch context7)

    for template <- templates do
      assert {:ok, _} = Entry.validate(%{template.name => template.config})
      assert Enum.sort(Entry.references(template.config)) == Enum.sort(template.env_refs)
      assert template.config["type"] in ~w(stdio http)

      for value <- Map.values(template.config["headers"] || %{}) do
        assert value =~ "${env:"
      end

      for value <- Map.values(template.config["env"] || %{}) do
        assert value =~ "${env:"
      end
    end
  end
end
