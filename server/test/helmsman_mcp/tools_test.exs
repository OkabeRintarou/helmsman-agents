defmodule HelmsmanMCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Component.Schema
  alias HelmsmanMCP.Tools

  defmodule WriteTool do
    @moduledoc false
    use HelmsmanMCP.Tool,
      name: "test_write",
      description: "A write tool.",
      schema: %{title: {:required, :string}},
      mode: :write

    @impl HelmsmanMCP.Tool
    def call(_args, _ctx), do: {:ok, %{}}
  end

  test "fetch/1 finds a tool by name" do
    assert Tools.fetch("whoami") == {:ok, HelmsmanMCP.Tools.Whoami}
    assert Tools.fetch("nope") == :error
  end

  test "every tool is well formed" do
    tools = Tools.all()
    names = Enum.map(tools, & &1.name())

    assert Enum.sort(names) == ["identify", "list_actors", "whoami"]
    assert names == Enum.uniq(names)

    for tool <- [WriteTool | tools] do
      description = tool.description()
      assert description != "" and description =~ ~r/\A[\x20-\x7e]+\z/, tool.name()
      assert tool.mode() in [:read, :write]
      assert is_map(tool.input_schema())

      if tool.mode() == :write do
        assert {:string, opts} = tool.input_schema().actor
        assert opts[:description]
      end
    end
  end

  test "a write tool's actor argument is optional" do
    schema = Schema.to_json_schema(WriteTool.input_schema())
    assert schema["properties"]["actor"]["type"] == "string"
    assert schema["required"] == ["title"]
  end
end
