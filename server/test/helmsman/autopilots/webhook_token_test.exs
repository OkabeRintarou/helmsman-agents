defmodule Helmsman.Autopilots.WebhookTokenTest do
  # add-autopilots 6.1: webhook tokens (decision 14).
  use Helmsman.DataCase, async: true

  import Helmsman.AutopilotsFixtures

  alias Helmsman.Autopilots

  setup do
    ctx = autopilots_fixture()
    Map.put(ctx, :view, autopilot_fixture(ctx.alice_scope))
  end

  test "a token is hma_ and 43 base64url characters; only its SHA-256 is kept", ctx do
    {:ok, %{token: token, autopilot: view}} =
      Autopilots.enable_webhook(ctx.alice_scope, ctx.view.id)

    assert "hma_" <> rest = token
    assert byte_size(token) == 47
    assert {:ok, <<_::binary-size(32)>>} = Base.url_decode64(rest, padding: false)
    assert view.webhook.enabled

    hash = autopilot_row(ctx.view).webhook_token_hash
    assert hash == :crypto.hash(:sha256, token)
    assert {:ok, ^hash} = Autopilots.authenticate_webhook(ctx.view.id, token)
  end

  test "rotating: the old token stops working, bob becomes the source", ctx do
    {:ok, %{token: old}} = Autopilots.enable_webhook(ctx.alice_scope, ctx.view.id)
    {:ok, %{token: new}} = Autopilots.rotate_webhook_token(ctx.bob_scope, ctx.view.id)

    assert Autopilots.authenticate_webhook(ctx.view.id, old) == {:error, :unauthorized}
    assert {:ok, _} = Autopilots.authenticate_webhook(ctx.view.id, new)
    assert autopilot_row(ctx.view).initiator_user_id == ctx.bob.id
  end

  test "turning it off: no token works, the source stays", ctx do
    {:ok, %{token: token}} = Autopilots.enable_webhook(ctx.bob_scope, ctx.view.id)
    {:ok, view} = Autopilots.disable_webhook(ctx.alice_scope, ctx.view.id)
    refute view.webhook.enabled
    assert Autopilots.authenticate_webhook(ctx.view.id, token) == {:error, :unauthorized}
    assert autopilot_row(ctx.view).initiator_user_id == ctx.bob.id
  end

  test "unknown ids, missing and malformed tokens are refused alike", ctx do
    {:ok, %{token: token}} = Autopilots.enable_webhook(ctx.alice_scope, ctx.view.id)

    for {id, t} <- [
          {-1, token},
          {"x", token},
          {ctx.view.id, nil},
          {ctx.view.id, "hma_x"},
          {ctx.view.id, String.slice(token, 4..-1//1)}
        ] do
      assert Autopilots.authenticate_webhook(id, t) == {:error, :unauthorized}
    end
  end
end
