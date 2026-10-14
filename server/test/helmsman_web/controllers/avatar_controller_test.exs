defmodule HelmsmanWeb.AvatarControllerTest do
  # add-actor-avatars 7.3: actor-avatars「读取头像」, the browser routes.
  use HelmsmanWeb.ConnCase, async: true

  import Helmsman.AccountsFixtures
  import Helmsman.AvatarsFixtures
  import Helmsman.RunsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.Avatars

  setup %{conn: conn} do
    ctx = dispatch_fixture()
    data = png(64, 64)
    {:ok, %{key: key}} = Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, data)
    {viewer, _scope} = member_scope_fixture(ctx.workspace, :viewer)
    Map.merge(ctx, %{conn: conn, data: data, key: key, viewer: viewer})
  end

  defp assert_image(conn, data, content_type) do
    assert conn.status == 200
    assert conn.resp_body == data
    assert get_resp_header(conn, "content-type") == [content_type]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    conn
  end

  test "a member (viewer) reads an agent's avatar with the security headers", ctx do
    conn =
      ctx.conn |> log_in_user(ctx.viewer) |> get(~p"/w/#{ctx.workspace.slug}/avatars/#{ctx.key}")

    assert_image(conn, ctx.data, "image/png")
    assert get_resp_header(conn, "etag") == [~s("#{ctx.key}")]
  end

  test "an image Accept header is fine", ctx do
    ctx.conn
    |> log_in_user(ctx.viewer)
    |> put_req_header("accept", "image/webp")
    |> get(~p"/w/#{ctx.workspace.slug}/avatars/#{ctx.key}")
    |> assert_image(ctx.data, "image/png")
  end

  test "a matching If-None-Match is 304 without a body", ctx do
    conn =
      ctx.conn
      |> log_in_user(ctx.viewer)
      |> put_req_header("if-none-match", ~s(W/"other", "#{ctx.key}"))
      |> get(~p"/w/#{ctx.workspace.slug}/avatars/#{ctx.key}")

    assert conn.status == 304
    assert conn.resp_body == ""
    assert get_resp_header(conn, "etag") == [~s("#{ctx.key}")]

    conn =
      ctx.conn
      |> log_in_user(ctx.viewer)
      |> put_req_header("if-none-match", ~s("other"))
      |> get(~p"/w/#{ctx.workspace.slug}/avatars/#{ctx.key}")

    assert conn.status == 200
  end

  test "users' avatars are read through the workspaces they have an identity in", ctx do
    {:ok, %{key: key}} = Avatars.put(user_scope_fixture(ctx.viewer), :me, jpeg(64, 64))

    ctx.conn
    |> log_in_user(ctx.alice)
    |> get(~p"/w/#{ctx.workspace.slug}/avatars/#{key}")
    |> assert_image(jpeg(64, 64), "image/jpeg")
  end

  test "across workspaces: 404 for a non-member, and for another workspace's key", ctx do
    outsider = user_fixture()
    other = workspace_fixture(outsider)
    other_scope = workspace_scope_fixture(outsider, other)
    {:ok, %{key: own_key}} = Avatars.put(other_scope, :me, png(48, 48))

    conn =
      ctx.conn |> log_in_user(outsider) |> get(~p"/w/#{ctx.workspace.slug}/avatars/#{ctx.key}")

    assert conn.status == 404
    assert conn.resp_body == ""

    conn =
      ctx.conn |> log_in_user(ctx.alice) |> get(~p"/w/#{ctx.workspace.slug}/avatars/#{own_key}")

    assert conn.status == 404

    conn = ctx.conn |> log_in_user(outsider) |> get(~p"/w/#{other.slug}/avatars/#{ctx.key}")
    assert conn.status == 404
  end

  test "unknown, replaced and malformed keys, and no session, are 404", ctx do
    {:ok, _} =
      Avatars.put(ctx.alice_scope, {:actor, "keel/dev"}, png(64, 64, color: {1, 2, 3, 4}))

    conn = log_in_user(ctx.conn, ctx.alice)

    for key <- [ctx.key, String.duplicate("0", 32), "not-a-key", String.upcase(ctx.key)] do
      assert get(conn, "/w/#{ctx.workspace.slug}/avatars/#{key}").status == 404
    end

    assert get(ctx.conn, "/w/#{ctx.workspace.slug}/avatars/#{ctx.key}").status == 404
  end

  test "/users/avatar/:key: only the user's own", ctx do
    {:ok, %{key: key}} = Avatars.put(user_scope_fixture(ctx.alice), :me, webp(64, 64))

    ctx.conn
    |> log_in_user(ctx.alice)
    |> get(~p"/users/avatar/#{key}")
    |> assert_image(webp(64, 64), "image/webp")

    assert ctx.conn
           |> log_in_user(ctx.viewer)
           |> get(~p"/users/avatar/#{key}")
           |> Map.get(:status) == 404

    assert ctx.conn
           |> log_in_user(ctx.alice)
           |> get(~p"/users/avatar/#{ctx.key}")
           |> Map.get(:status) == 404

    assert ctx.conn |> get(~p"/users/avatar/#{key}") |> Map.get(:status) == 404
  end
end
