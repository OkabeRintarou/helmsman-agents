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

  # Regression (M4 browser acceptance): a server-opened overlay must not depend on the
  # phx-mounted JS to become visible.
  test "a server-opened overlay renders visible with a CSS enter transition" do
    for kind <- [:panel, :dialog] do
      assigns = %{kind: kind}

      tree =
        ~H"""
        <.overlay id="ov" show kind={@kind} on_cancel={Phoenix.LiveView.JS.push("close")}>
          <p>x</p>
        </.overlay>
        """
        |> overlay_tree()

      for id <- ~w(#ov #ov-backdrop #ov-container) do
        refute classes(tree, id) |> Enum.member?("hidden"), "#{id} is hidden (#{kind})"
      end

      assert "fixed" in classes(tree, "#ov")
      assert "inset-0" in classes(tree, "#ov")
      assert "flex" in classes(tree, "#ov-container")
      assert "starting:opacity-0" in classes(tree, "#ov-backdrop")

      starting = if kind == :panel, do: "starting:translate-x-full", else: "starting:scale-95"
      assert starting in classes(tree, "#ov-container")
    end
  end

  test "a client-controlled overlay renders hidden until opened" do
    assigns = %{}

    tree =
      ~H"""
      <.overlay id="ov">
        <p>x</p>
      </.overlay>
      """
      |> overlay_tree()

    for id <- ~w(#ov #ov-backdrop #ov-container) do
      assert "hidden" in classes(tree, id), "#{id} is not hidden"
    end

    refute Enum.any?(classes(tree, "#ov-container"), &String.starts_with?(&1, "starting:"))
  end

  test "closing drops the CSS enter transition before the leave transition" do
    ops = close_overlay("ov", kind: :panel) |> Jason.encode!() |> Jason.decode!()

    remove =
      Enum.find_index(ops, fn
        ["remove_class", %{"to" => "#ov-container", "names" => names}] ->
          "starting:translate-x-full" in names

        _ ->
          false
      end)

    hide = Enum.find_index(ops, &match?(["hide", %{"to" => "#ov-container"}], &1))
    assert remove < hide
  end

  defp overlay_tree(rendered) do
    rendered
    |> rendered_to_string()
    |> String.replace(~r/<template[^>]*>|<\/template>/, "")
    |> LazyHTML.from_fragment()
  end

  defp classes(tree, selector) do
    tree
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> List.first("")
    |> String.split()
  end
end
