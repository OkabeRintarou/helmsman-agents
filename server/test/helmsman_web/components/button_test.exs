defmodule HelmsmanWeb.Components.ButtonTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.CoreComponents

  defp render_button(assigns_fun), do: rendered_to_string(assigns_fun.(%{}))

  test "variants and sizes map to classes" do
    for {variant, class} <- [
          {"primary", "btn-primary"},
          {"secondary", "border-border-strong"},
          {"ghost", "btn-ghost"},
          {"danger", "btn-error"},
          {"link", "btn-link"}
        ],
        {size, height} <- [{"xs", "h-6"}, {"sm", "h-7"}, {"md", "h-8"}, {"lg", "h-9"}] do
      assigns = %{variant: variant, size: size}

      html =
        rendered_to_string(~H"""
        <.button variant={@variant} size={@size}>Go</.button>
        """)

      assert html =~ class, "#{variant} should have #{class}"
      assert html =~ height, "#{size} should have #{height}"
    end
  end

  test "renders a link when navigate is given" do
    html =
      render_button(fn assigns ->
        ~H"""
        <.button navigate="/w/acme">Go</.button>
        """
      end)

    assert html =~ ~s(href="/w/acme")
    assert html =~ "data-phx-link"
  end

  test "disabled with a reason stays focusable and describes the reason" do
    html =
      render_button(fn assigns ->
        ~H"""
        <.button id="start" disabled_reason="只有成员可以开始" phx-click="start">开始</.button>
        """
      end)

    assert html =~ ~s(aria-disabled="true")
    assert html =~ ~s(aria-describedby="start-reason")
    assert html =~ ~s(<span id="start-reason" role="tooltip")
    assert html =~ "只有成员可以开始"
    refute html =~ ~s(phx-click="start")
    refute html =~ ~r/<button[^>]* disabled[ >]/
  end

  test "a submit button disabled with a reason is marked for the click/submit guard" do
    html =
      render_button(fn assigns ->
        ~H"""
        <.button id="save" type="submit" disabled_reason="只读成员不能保存">保存</.button>
        """
      end)

    assert html =~ ~r/<button[^>]*type="submit"[^>]*aria-disabled="true"[^>]*data-hm-disabled/
    assert File.read!(Path.expand("../../../assets/js/app.js", __DIR__)) =~ "[data-hm-disabled]"
  end

  test "disabled_reason without an id raises" do
    assert_raise ArgumentError, ~r/needs an id/, fn ->
      render_component(&button/1, disabled_reason: "no", inner_block: [])
    end
  end

  test "submit state: spinner shown while LiveView marks the button as submitting" do
    html =
      render_button(fn assigns ->
        ~H"""
        <.button type="submit" variant="primary">保存</.button>
        """
      end)

    assert html =~ "lucide-loader-circle"
    assert html =~ "phx-submit-loading:inline-block"
    assert html =~ "data-hm-busy"
  end

  test "icon buttons use the label as accessible name and tooltip" do
    html =
      render_button(fn assigns ->
        ~H"""
        <.icon_button icon="lucide-x" label="关闭" />
        """
      end)

    assert html =~ ~s(aria-label="关闭")
    assert html =~ "lucide-x"
    assert html =~ "size-8"
  end

  test "icon buttons without a label fail to compile" do
    code = """
    defmodule HelmsmanWeb.Components.ButtonTest.MissingLabel do
      use Phoenix.Component
      import HelmsmanWeb.CoreComponents
      def render(assigns), do: ~H"<.icon_button icon=\\"lucide-x\\" />"
    end
    """

    warnings = ExUnit.CaptureIO.capture_io(:stderr, fn -> Code.compile_string(code) end)
    assert warnings =~ ~s(missing required attribute "label")
  end
end
