defmodule HelmsmanWeb.APIHelpers do
  @moduledoc """
  Test helpers for the REST API (`add-rest-api`): a workspace with a
  token of its user, and JSON requests with that token.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  require Ecto.Query

  import Helmsman.AccountsFixtures
  import Helmsman.ApiTokensFixtures
  import Helmsman.WorkspacesFixtures
  import Plug.Conn
  import Phoenix.ConnTest

  alias HelmsmanWeb.API.ApiSpec

  @endpoint HelmsmanWeb.Endpoint

  @doc """
  alice (owner) and her workspace, with her scope and a token with every
  scope: `%{alice, workspace, slug, scope, token, api_token}`.
  """
  def api_fixture(token_attrs \\ %{}) do
    alice = user_fixture()
    workspace = workspace_fixture(alice)
    scope = workspace_scope_fixture(alice, workspace)
    %{token: token, api_token: api_token} = api_token_fixture(scope, token_attrs)

    %{
      alice: alice,
      workspace: workspace,
      slug: workspace.slug,
      scope: scope,
      token: token,
      api_token: api_token
    }
  end

  @doc "A token of `user` in `workspace` (`attrs` go to the token): the plaintext."
  def token_for(user, workspace, attrs \\ %{}) do
    %{token: token} = api_token_fixture(workspace_scope_fixture(user, workspace), attrs)
    token
  end

  @doc """
  A new user of `workspace` with `role` and a token of theirs (`attrs` go
  to the token): `{user, token}`. Viewers cannot create tokens, so the
  token is created as a member and the role changed after.
  """
  def member_token(workspace, role, attrs \\ %{}) do
    user = user_fixture()
    member_fixture(workspace, user, if(role == :viewer, do: :member, else: role))
    token = token_for(user, workspace, attrs)

    if role == :viewer do
      Helmsman.Repo.update_all(
        Ecto.Query.from(m in Helmsman.Workspaces.Membership,
          where: m.workspace_id == ^workspace.id and m.user_id == ^user.id
        ),
        set: [role: :viewer]
      )
    end

    {user, token}
  end

  @doc "A connection with `token` as bearer and `headers`."
  def authed(token, headers \\ []) do
    conn = build_conn()
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    Enum.reduce(headers, conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
  end

  @doc "`GET path` with `token` (and `headers`)."
  def api_get(token, path, headers \\ []), do: get(authed(token, headers), path)

  @doc """
  A request with a JSON body: `method` (`:post`, `:patch`, `:delete`) to
  `path` with `body` encoded (nil: no body).
  """
  def api_send(method, token, path, body \\ nil, headers \\ []) do
    conn = authed(token, headers)

    case body do
      nil ->
        dispatch(conn, @endpoint, method, path, nil)

      body ->
        encoded = if is_binary(body), do: body, else: Jason.encode!(body)

        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-length", Integer.to_string(byte_size(encoded)))
        |> dispatch(@endpoint, method, path, encoded)
    end
  end

  @doc "The decoded body of a JSON response with `status`."
  def body!(conn, status) do
    if conn.status != status do
      raise ExUnit.AssertionError,
        message: "expected status #{status}, got #{conn.status}: #{conn.resp_body}"
    end

    Jason.decode!(conn.resp_body)
  end

  @doc "Asserts the REST error body with `status` and `code`; returns its detail."
  def error!(conn, status, code) do
    body = body!(conn, status)

    unless match?(
             %{"error" => ^code, "message" => message, "detail" => %{}} when is_binary(message),
             body
           ) do
      raise ExUnit.AssertionError,
        message: "expected error #{code}, got #{inspect(body)}"
    end

    unless Map.keys(body) |> Enum.sort() == ["detail", "error", "message"] do
      raise ExUnit.AssertionError, message: "unexpected keys in #{inspect(body)}"
    end

    body["detail"]
  end

  @doc "The OpenAPI document of the REST API."
  def api_spec, do: ApiSpec.spec()

  @doc "The path of the workspace `slug` under `/api/v1/w`."
  def w(slug, path), do: "/api/v1/w/#{slug}#{path}"
end
