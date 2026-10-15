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

    assert Enum.sort(names) ==
             Enum.sort(~w(identify whoami list_actors list_projects get_project create_project
                 update_project list_tasks search_tasks query_tasks list_filters save_filter delete_filter get_task create_task update_task list_my_tasks
                 transition_task link_tasks unlink_tasks add_feedback update_feedback
                 list_feedback list_agents run_agent list_runs cancel_run get_design propose_agent
               withdraw_agent delegate propose_squad get_spec diff_spec list_spec_reviews
               submit_spec_version submit_spec_review reply_spec_issue rule_spec_issue
               finalize_spec update_spec cancel_spec_review request_spec_review))

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

  test "the feedback write tools also take author" do
    for name <- ["add_feedback", "update_feedback"] do
      {:ok, tool} = Tools.fetch(name)
      assert tool.mode() == :write
      assert {:string, opts} = tool.input_schema().author
      assert opts[:description] =~ ~r/\A[\x20-\x7e]+\z/
    end

    write_tools = Enum.filter(Tools.all(), &(&1.mode() == :write))

    assert write_tools |> Enum.map(& &1.name()) |> Enum.sort() ==
             Enum.sort(
               ~w(add_feedback cancel_run create_project create_task delegate link_tasks run_agent
                  transition_task unlink_tasks update_feedback update_project update_task
                  cancel_spec_review finalize_spec reply_spec_issue request_spec_review
                  rule_spec_issue submit_spec_review submit_spec_version update_spec)
             )
  end

  test "every schema converts to JSON Schema" do
    for tool <- Tools.all() do
      assert %{"type" => "object"} = Schema.to_json_schema(tool.input_schema()), tool.name()
    end
  end

  test "a write tool's actor argument is optional" do
    schema = Schema.to_json_schema(WriteTool.input_schema())
    assert schema["properties"]["actor"]["type"] == "string"
    assert schema["required"] == ["title"]
  end
end
