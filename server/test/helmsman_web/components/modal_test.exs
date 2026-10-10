defmodule HelmsmanWeb.Components.ModalTest do
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.Components.Overlay

  defp modal_html(view), do: view |> element("#demo-modal-portal") |> render()

  test "visiting the URL with the parameter opens the modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?modal=log")
    html = modal_html(view)

    assert html =~ ~s(id="demo-modal")
    assert html =~ "执行记录"
    assert html =~ "sm:h-[85vh]"
    assert html =~ "overflow-y-auto"
  end

  test "closing removes the parameter", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dev/ui?modal=log")

    assert modal_html(view) =~
             ~r/data-cancel="\[\[&quot;patch&quot;,\{[^}]*&quot;href&quot;:&quot;\/dev\/ui&quot;/

    render_patch(view, "/dev/ui")
    refute modal_html(view) =~ ~s(id="demo-modal")
  end

  test "sizes" do
    for {size, class} <- [sm: "sm:max-w-[440px]", md: "sm:max-w-[640px]", lg: "sm:max-w-[960px]"] do
      assigns = %{size: size}

      html =
        rendered_to_string(~H"""
        <.modal id="m" size={@size} title="T">body</.modal>
        """)

      assert html =~ class
    end
  end
end
