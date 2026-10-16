defmodule Helmsman.Agents.McpRefsRaceTest do
  use Helmsman.DataCase, async: false
  import Helmsman.RunsFixtures
  alias Helmsman.{Agents, CommittedData, McpServers}
  alias Helmsman.McpServers.{Definition, Ref}

  test "saving references and deleting a definition on separate connections never leaves dangling refs" do
    ctx = CommittedData.unboxed(fn -> dispatch_fixture() end)
    on_exit(fn -> CommittedData.delete_user_data!([ctx.alice.id]) end)

    {:ok, definition} =
      CommittedData.unboxed(fn ->
        McpServers.create(ctx.alice_scope, %{name: "docs", config: %{"command" => "npx"}})
      end)

    parent = self()

    children =
      for op <- [:save, :delete] do
        task =
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go ->
                CommittedData.unboxed(fn ->
                  case op do
                    :save ->
                      Agents.update(ctx.alice_scope, ctx.agent.name, %{
                        mcp_server_ids: [definition.id]
                      })

                    :delete ->
                      McpServers.delete(ctx.alice_scope, definition.id)
                  end
                end)
            end
          end)

        assert_receive {:ready, pid}
        {task, pid}
      end

    Enum.each(children, fn {_, pid} -> send(pid, :go) end)
    results = Enum.map(children, fn {task, _} -> Task.await(task, 15_000) end)

    assert Enum.all?(results, fn result ->
             match?({:ok, _}, result) or match?({:error, _}, result)
           end)

    assert CommittedData.unboxed(fn ->
             not Repo.exists?(
               from r in Ref,
                 left_join: d in Definition,
                 on: d.id == r.server_id,
                 where: r.agent_actor_id == ^ctx.agent.id and is_nil(d.id)
             )
           end)
  end
end
