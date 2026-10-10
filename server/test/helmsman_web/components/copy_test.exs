defmodule HelmsmanWeb.Components.CopyTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.Components.Text

  test "copy button carries the text, labels and the colocated hook" do
    html = render_component(&copy_button/1, id: "c", text: "mix test")
    assert html =~ ~s(data-copy="mix test")
    assert html =~ ~s(phx-hook="HelmsmanWeb.Components.Text.Copy")
    assert html =~ ~s(aria-label="复制")
    assert html =~ ~s(data-copied="已复制")
    assert html =~ ~s(id="c-status" role="status")
  end

  test "secret once shows the value in monospace with a warning and copy button" do
    html = render_component(&secret_once/1, id: "s", value: "hm_secret")
    assert html =~ ~r/<code id="s-value"[^>]*font-mono[^>]*>\s*hm_secret\s*<\/code>/
    assert html =~ "关闭后将无法再次查看"
    assert html =~ ~s(data-copy="hm_secret")
    assert html =~ ~s(data-copy-target="#s-value")
  end
end
