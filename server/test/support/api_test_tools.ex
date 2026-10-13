defmodule HelmsmanWeb.Test.ReadTool do
  @moduledoc "A read tool compiled for tests only: echoes its identity and arguments."

  use Boundary, top_level?: true, check: [in: false, out: false]

  use HelmsmanMCP.Tool,
    name: "test_read",
    description: "Test only.",
    schema: %{
      limit: {:integer, description: "A number."},
      extra: {:string, description: "Added by a test (tool parameter changes)."}
    },
    mode: :read

  @impl HelmsmanMCP.Tool
  def call(args, %{scope: scope}) do
    {:ok,
     %{actor: scope.actor && scope.actor.name, args: args, in_tx: Helmsman.Repo.in_transaction?()}}
  end
end

defmodule HelmsmanWeb.Test.WriteTool do
  @moduledoc """
  A write tool compiled for tests only: adds a feedback to `task_id`, then
  fails with `:stale` when `fail` is true (everything rolls back).
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  use HelmsmanMCP.Tool,
    name: "test_write",
    description: "Test only.",
    schema: %{
      task_id: {:required, :string, description: "Task ID."},
      fail: {:boolean, description: "Fail after writing."}
    },
    mode: :write

  @impl HelmsmanMCP.Tool
  def call(%{"task_id" => id} = args, %{scope: scope}) do
    with {:ok, _entry} <- Helmsman.Feedback.add(scope, id, %{content: "written"}) do
      if args["fail"], do: {:error, :stale}, else: {:ok, %{actor: scope.actor.name}}
    end
  end
end

defmodule HelmsmanWeb.Test.RaisingTool do
  @moduledoc "A read tool compiled for tests only: raises."

  use Boundary, top_level?: true, check: [in: false, out: false]

  use HelmsmanMCP.Tool,
    name: "test_raising",
    description: "Test only.",
    schema: %{},
    mode: :read

  @impl HelmsmanMCP.Tool
  def call(_args, _ctx), do: raise("secret failure detail")
end
