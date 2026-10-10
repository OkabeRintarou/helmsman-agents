defmodule HelmsmanWeb.Components.ConfirmDialogTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component
  import HelmsmanWeb.Components.Overlay

  defp click_ops(html, id) do
    [_, js] = Regex.run(~r/id="#{id}"[^>]*phx-click="([^"]*)"/, html)
    js |> String.replace("&quot;", "\"") |> Jason.decode!()
  end

  test "two affirmative actions push the same event with different params" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.confirm_dialog
        id="start"
        title="认领任务"
        confirm_label="开始"
        on_confirm="claim"
        confirm_value={%{start: true}}
      >
        认领后是否立即开始？ <:secondary_action label="暂不开始" event="claim" value={%{start: false}} />
      </.confirm_dialog>
      """)

    assert html =~ ~s(role="alertdialog")
    assert html =~ ~s(aria-describedby="start-description")

    assert ["push", %{"event" => "claim", "value" => %{"start" => true}}] =
             List.last(click_ops(html, "start-confirm"))

    [_, secondary] =
      Regex.run(~r/<button type="button"[^>]*phx-click="([^"]*)"[^>]*>\s*暂不开始/, html)

    assert ["push", %{"event" => "claim", "value" => %{"start" => false}}] =
             secondary |> String.replace("&quot;", "\"") |> Jason.decode!() |> List.last()

    assert html =~ ~r/id="start-confirm"[^>]*data-confirm-primary/
  end

  test "non-destructive dialogs focus the confirm button" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.confirm_dialog id="d" title="T" confirm_label="开始" on_confirm="go">x</.confirm_dialog>
      """)

    assert html =~ ~r/id="d-confirm"[^>]*autofocus/
    refute html =~ ~r/id="d-cancel"[^>]*autofocus/
    assert html =~ "btn-primary"
    assert html =~ ~s(&quot;focus&quot;,{&quot;to&quot;:&quot;#d-confirm&quot;})
  end

  test "destructive dialogs use danger and focus cancel" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.confirm_dialog id="d" title="吊销？" danger confirm_label="吊销" on_confirm="revoke">
        x
      </.confirm_dialog>
      """)

    assert html =~ ~r/id="d-cancel"[^>]*autofocus/
    refute html =~ ~r/id="d-confirm"[^>]*autofocus/
    assert html =~ "btn-error"
    assert html =~ ~s(&quot;focus&quot;,{&quot;to&quot;:&quot;#d-cancel&quot;})
    assert html =~ "取消"
  end

  test "stacked on a panel it makes the panel inert" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.confirm_dialog id="d" title="T" confirm_label="OK" on_confirm="go" stack_on="panel">
        x
      </.confirm_dialog>
      """)

    assert html =~
             ~s(&quot;remove_attr&quot;,{&quot;to&quot;:&quot;#panel&quot;,&quot;attr&quot;:&quot;inert&quot;})
  end
end
