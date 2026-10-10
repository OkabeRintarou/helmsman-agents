defmodule HelmsmanWeb.Components.OverlayTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.Components.Overlay

  test "renders into the #hm-overlays portal with dialog semantics and a focus wrap" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.overlay id="ov">
        <h2 id="ov-title">T</h2><button>OK</button>
      </.overlay>
      """)

    assert html =~ ~r/<template[^>]* id="ov-portal" data-phx-portal="#hm-overlays">/
    assert html =~ ~s(role="dialog")
    assert html =~ ~s(aria-modal="true")
    assert html =~ ~s(aria-labelledby="ov-title")
    assert html =~ ~s(phx-hook="Phoenix.FocusWrap")
    assert html =~ ~s(id="ov-container-start")
    assert html =~ "data-hm-overlay"
  end

  test "open sets inert on the shell after showing and focuses inside" do
    js = open_overlay("ov") |> Jason.encode!()
    assert js =~ ~s("dispatch",{"to":"#ov","event":"hm:overlay-open"})
    assert js =~ ~s("set_attr",{"to":"#hm-shell","attr":["inert",""]})
    assert js =~ ~s("set_attr",{"to":"#ov","attr":["data-open",""]})
    assert js =~ ~s("focus_first",{"to":"#ov-content"})

    [remember_focus | _] = Jason.decode!(js)
    assert remember_focus == ["dispatch", %{"to" => "#ov", "event" => "hm:overlay-open"}]
  end

  test "close hides, removes inert and restores focus (in that order)" do
    ops = close_overlay("ov") |> Jason.encode!() |> Jason.decode!()
    hide = Enum.find_index(ops, &match?(["hide", %{"to" => "#ov"}], &1))

    remove =
      Enum.find_index(
        ops,
        &match?(["remove_attr", %{"to" => "#hm-shell", "attr" => "inert"}], &1)
      )

    pop = Enum.find_index(ops, &match?(["dispatch", %{"event" => "hm:overlay-close"}], &1))
    assert hide < remove
    assert remove < pop
  end

  test "stacked overlays make the overlay underneath inert instead of the shell" do
    open = open_overlay("confirm", stack_on: "panel") |> Jason.encode!()
    close = close_overlay("confirm", stack_on: "panel") |> Jason.encode!()
    assert open =~ ~s("set_attr",{"to":"#panel","attr":["inert",""]})
    refute open =~ "#hm-shell"
    assert close =~ ~s("remove_attr",{"to":"#panel","attr":"inert"})
  end

  test "client-controlled overlays put the close command on data-cancel and the backdrop" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.overlay id="ov">
        <p>x</p>
      </.overlay>
      """)

    assert html =~ ~r/data-cancel="[^"]*inert[^"]*hm:overlay-close/
    assert html =~ ~r/id="ov-backdrop"[^>]*phx-click="[^"]*hm:overlay-close/
  end

  test "dirty overlays do not close on backdrop click" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.overlay id="ov" dirty>
        <p>x</p>
      </.overlay>
      """)

    refute html =~ ~r/id="ov-backdrop"[^>]*phx-click/
  end

  test "server-controlled overlays open on mount, close on removal and render only when shown" do
    assigns = %{show: true}

    html =
      rendered_to_string(~H"""
      <.overlay id="ov" show={@show} on_cancel={Phoenix.LiveView.JS.patch("/x")}>
        <p>x</p>
      </.overlay>
      """)

    assert html =~ ~r/phx-mounted="[^"]*inert/
    assert html =~ ~r/phx-remove="[^"]*remove_attr[^"]*inert/
    assert html =~ ~r/data-cancel="[^"]*patch/

    assigns = %{show: false}

    html =
      rendered_to_string(~H"""
      <.overlay id="ov" show={@show}>
        <p>x</p>
      </.overlay>
      """)

    refute html =~ ~s(id="ov")
  end
end
