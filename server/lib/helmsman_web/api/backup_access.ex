defmodule HelmsmanWeb.API.BackupAccess do
  @moduledoc "Resolves backup management requests as the token user's human identity."
  alias Helmsman.Actors
  alias HelmsmanWeb.API.{Operations, Params}

  def operation(opts) do
    operation = Operations.manual(opts)

    parameters =
      Enum.map(operation.parameters, fn
        %{name: :"X-Helmsman-Actor"} = parameter ->
          %{
            parameter
            | description:
                "Omit or name your own human identity. The token's default agent is ignored; an Agent header is forbidden."
          }

        parameter ->
          parameter
      end)

    %{operation | parameters: parameters}
  end

  def scope(conn) do
    scope = conn.assigns.current_scope

    with {:ok, requested} <- Params.requested_actor(conn, nil) do
      case Actors.get_human(scope.workspace.id, scope.user.id) do
        nil -> {:error, :not_found}
        %{name: name} = human when requested in [nil, name] -> {:ok, %{scope | actor: human}}
        _ -> {:error, :forbidden}
      end
    end
  end
end
