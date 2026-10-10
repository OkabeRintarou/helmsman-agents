defmodule HelmsmanWeb.Components.InputTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.CoreComponents

  defp form_with(params, errors, action \\ nil) do
    to_form(params, as: :task, errors: errors, action: action)
  end

  defp render_title(form) do
    assigns = %{form: form}

    rendered_to_string(~H"""
    <.input field={@form[:title]} label="标题" help="一句话" />
    """)
  end

  test "errors are hidden until the field was used" do
    # LiveView sends `_unused_<field>` for fields the user has not touched yet.
    form = form_with(%{"title" => "", "_unused_title" => ""}, title: {"can't be blank", []})
    html = render_title(form)

    refute html =~ "不能为空"
    refute html =~ "aria-invalid"
    assert html =~ ~s(aria-describedby="task_title-help")
    assert html =~ ~r/<label[^>]* for="task_title"/
  end

  test "after submit errors are shown and linked with aria attributes" do
    form = form_with(%{"title" => ""}, [title: {"can't be blank", []}], :insert)
    html = render_title(form)

    assert html =~ "不能为空"
    assert html =~ ~s(aria-invalid="true")
    assert html =~ ~s(aria-describedby="task_title-help task_title-error")
    assert html =~ ~s(id="task_title-error")
    assert html =~ "text-danger-fg"
  end

  test "row layout puts the label beside the control" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.input name="notify" type="switch" value="true" label="通知" layout={:row} />
      """)

    assert html =~ "sm:grid-cols-[12rem_1fr]"
    assert html =~ ~s(role="switch")
    assert html =~ "toggle"
    assert html =~ "checked"
  end

  test "select, textarea and radio share the structure" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.input name="kind" type="select" value="b" label="类型" options={[{"A", "a"}, {"B", "b"}]} />
      <.input name="body" type="textarea" value="hi" label="正文" />
      <.input name="pick" type="radio" value="b" label="选项" options={[{"A", "a"}, {"B", "b"}]} />
      """)

    assert html =~ ~s(<option selected value="b">B</option>)
    assert html =~ ~r/<textarea[^>]*>\s*hi<\/textarea>/
    assert html =~ ~s(role="radiogroup")
    assert html =~ ~s(aria-labelledby="pick-legend")
  end
end
