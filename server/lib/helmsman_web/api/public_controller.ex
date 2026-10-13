defmodule HelmsmanWeb.API.PublicController do
  @moduledoc """
  The REST endpoints without authentication (`add-rest-api` decision 9):
  the agent workflow (`GET /api/v1/workflow.md?lang=en|zh`) and the
  OpenAPI document (`GET /api/v1/openapi.json`).
  """

  use HelmsmanWeb.API.Controller

  alias HelmsmanWeb.ErrorMapper
  alias OpenApiSpex.Plug.RenderSpec
  alias OpenApiSpex.Schema

  @docs Path.expand("../../../../docs", __DIR__)
  @en_path Path.join(@docs, "AGENT-WORKFLOW.en.md")
  @zh_path Path.join(@docs, "AGENT-WORKFLOW.md")
  @external_resource @en_path
  @external_resource @zh_path
  @workflows %{"en" => File.read!(@en_path), "zh" => File.read!(@zh_path)}

  def workflow(conn, params) do
    case Map.fetch(@workflows, Map.get(params, "lang", "en")) do
      {:ok, markdown} ->
        conn
        |> put_resp_content_type("text/markdown")
        |> send_resp(200, markdown)

      :error ->
        response = ErrorMapper.to_response({:invalid_params, %{"lang" => ["must be en or zh"]}})
        ErrorMapper.send_error(conn, response)
    end
  end

  def openapi(conn, _params), do: RenderSpec.call(conn, [])

  @doc false
  def operation(:workflow) do
    Operations.manual(
      id: "workflow",
      summary: "workflow",
      description:
        "The agent workflow (roles, statuses, what to do at each step) as Markdown; the same " <>
          "text as the MCP resource helmsman://workflow.",
      tag: "public",
      public: true,
      params: [
        {:lang, :query, %Schema{type: :string, enum: ["en", "zh"]},
         "Language: en (default) or zh."}
      ],
      content_type: "text/markdown",
      response: %Schema{type: :string}
    )
  end

  def operation(:openapi) do
    Operations.manual(
      id: "openapi",
      summary: "openapi",
      description: "This OpenAPI document.",
      tag: "public",
      public: true,
      content_type: "application/json",
      response: %Schema{type: :object}
    )
  end
end
