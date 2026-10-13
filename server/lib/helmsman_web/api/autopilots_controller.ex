defmodule HelmsmanWeb.API.AutopilotsController do
  @moduledoc """
  `POST /autopilots/:id/run`: "run now" (`add-rest-api` decision 13,
  `Helmsman.Autopilots.run_now/3`).

  Autopilots are managed by people, so this is the one write that does
  not run as the request's writer: always as the token's user, never as
  an agent. The token's default agent is ignored; `X-Helmsman-Actor` or
  the body's `actor` may only be left out or name the user's own human
  identity (anything else is 403 `forbidden`, nothing recorded). There is
  no outer transaction and no lock here: `run_now/3` takes its own locks
  in the domain's order (membership, autopilot, target).
  """

  use HelmsmanWeb.API.Controller

  alias Helmsman.{Actors, Autopilots}
  alias HelmsmanWeb.API.Params
  alias OpenApiSpex.Schema

  # The body, checked as tool arguments are (`peri` types).
  @args %{instructions: :string, actor: :string}

  def run(conn, %{"id" => id}) do
    ToolAction.guarded(conn, "run_autopilot", fn ->
      scope = conn.assigns.current_scope

      with {:ok, id} <- ToolAction.positive_id(id),
           {:ok, args, requested} <- Params.args(conn, @args, %{}),
           {:ok, scope} <- as_user(scope, requested),
           :ok <- test_hook({:run_now, Helmsman.Repo.in_transaction?()}),
           {:ok, record} <- run_now(scope, id, args["instructions"]) do
        ToolAction.data(conn, 202, %{
          id: record.id,
          status: to_string(record.status),
          reason: record.reason
        })
      end
    end)
  end

  # The user's human identity, read without a lock.
  defp as_user(scope, requested) do
    case Actors.get_human(scope.workspace.id, scope.user.id) do
      nil -> {:error, :not_found}
      %{name: name} = human when requested in [nil, name] -> {:ok, %{scope | actor: human}}
      _human -> {:error, :forbidden}
    end
  end

  # The domain names the argument `note`; REST calls it `instructions`.
  defp run_now(scope, id, instructions) do
    case Autopilots.run_now(scope, id, instructions) do
      {:error, %Ecto.Changeset{} = changeset} ->
        fields = ErrorMapper.changeset_fields(changeset)

        {:error,
         {:validation_failed,
          Map.new(fields, fn
            {:note, messages} -> {:instructions, messages}
            other -> other
          end)}}

      other ->
        other
    end
  end

  # Tests check that no transaction is open when the domain is called.
  if Mix.env() == :test do
    defp test_hook(point) do
      case Process.get(:helmsman_test_hook) do
        hook when is_function(hook, 1) -> hook.(point)
        _none -> :ok
      end

      :ok
    end
  else
    defp test_hook(_point), do: :ok
  end

  @doc false
  def operation(:run) do
    Operations.manual(
      id: "run_autopilot",
      summary: "run_autopilot",
      description:
        "Run an autopilot now, enabled or not (member and above who may trigger its " <>
          "target). Unlike other writes it always runs as you, never as an agent: the " <>
          "token's default agent is ignored and X-Helmsman-Actor / actor may only name your " <>
          "own human identity. Returns the trigger record (202); a run already in progress " <>
          "gives a skipped or pending record, per the autopilot's overlap setting.",
      tag: "autopilots",
      write: true,
      params: [{:id, :path, %Schema{type: :integer, minimum: 1}, "Autopilot ID."}],
      body: %Schema{
        type: :object,
        properties: %{
          instructions: %Schema{type: :string, description: "A note for this run, ≤ 4 KB."},
          actor: %Schema{type: :string, description: "Only your own human identity name."}
        }
      },
      status: 202,
      response: Schemas.AutopilotRecord
    )
  end
end
