defmodule HelmsmanWeb.SpecExportController do
  @moduledoc """
  `GET /w/:slug/t/:ident/spec/export` (add-spec-workflow-ui D11): a version of the task's
  spec as an OpenSpec change directory (`version`, `format` `tar.gz` / `zip`, `reviews`),
  for the browser session. A missing spec, version or task, or another workspace's task,
  is 404; a refused read is 403.
  """
  use HelmsmanWeb, :controller

  alias Helmsman.Accounts.Scope
  alias Helmsman.Workspaces
  alias HelmsmanWeb.SpecData

  def export(conn, %{"slug" => slug, "ident" => ident} = params) do
    user = conn.assigns.current_scope.user

    with {:ok, %{workspace: workspace, membership: membership, actor: actor}} <-
           Workspaces.fetch_for_user(user, slug),
         scope = %{
           Scope.put_workspace(Scope.for_user(user), workspace, membership, actor)
           | via: :web
         },
         {:ok, opts} <- options(params),
         {:ok, file} <- SpecData.export_archive(scope, ident, opts) do
      conn
      |> put_resp_content_type(file.content_type, nil)
      |> send_download({:binary, file.body},
        filename: file.filename,
        content_type: file.content_type
      )
    else
      {:error, :forbidden} -> send_resp(conn, 403, "Forbidden")
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  defp options(params) do
    version =
      case Integer.parse(params["version"] || "") do
        {n, ""} when n > 0 -> n
        _ -> nil
      end

    format = if params["format"] == "zip", do: "zip", else: "tar.gz"

    if params["version"] not in [nil, ""] and version == nil,
      do: {:error, :not_found},
      else: {:ok, [version: version, format: format, reviews: params["reviews"] == "true"]}
  end
end
