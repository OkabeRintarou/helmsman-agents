defmodule HelmsmanWeb.API.ApiSpec do
  @moduledoc """
  The OpenAPI document of the REST API (`add-rest-api` decision 8),
  served at `GET /api/v1/openapi.json`. Paths come from the router
  (`OpenApiSpex.Paths.from_router/1`): every `/api/v1` route's controller
  describes its operations (`HelmsmanWeb.API.Controller`).
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Helmsman REST API",
        description:
          "Tasks, feedback, links and runs of a workspace. Most endpoints are the MCP tools " <>
            "of the same name over HTTP. Authenticate with an API token " <>
            "(Authorization: Bearer hm_...): api:read for GET, api:write for the rest.",
        version: version()
      },
      servers: [Server.from_endpoint(HelmsmanWeb.Endpoint)],
      paths: paths(),
      components: %Components{
        securitySchemes: %{
          "bearer" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "An API token of the workspace (hm_...)."
          }
        }
      },
      security: [%{"bearer" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end

  defp paths do
    HelmsmanWeb.Router
    |> Paths.from_router()
    |> Map.filter(fn {path, _item} -> String.starts_with?(path, "/api/v1/") end)
  end

  defp version do
    case Application.spec(:helmsman, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
