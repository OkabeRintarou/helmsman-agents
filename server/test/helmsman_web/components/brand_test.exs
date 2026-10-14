defmodule HelmsmanWeb.Components.BrandTest do
  @moduledoc "web-components「品牌图标」「模型名」(add-actor-avatars D1, D18)."
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import HelmsmanWeb.Components.Brand

  test "colour variant as an <img> on the light plate (deepseek)" do
    html = render_component(&brand_icon/1, icon: "deepseek")
    assert html =~ ~s(src="/images/brand/deepseek-color.svg")
    assert html =~ "bg-id-plate"
    assert html =~ "border-id-plate-border"
    refute html =~ "<svg"
  end

  test "monochrome variant inlined with the plate ink (openai), no 1em size" do
    html = render_component(&brand_icon/1, icon: "openai", label: "OpenAI")
    assert html =~ ~r/<svg class="size-\[70%\]" aria-hidden="true"/
    assert html =~ ~s(fill="currentColor")
    assert html =~ "text-id-plate-ink"
    refute html =~ ~s(width="1em")
    refute html =~ ~s(height="1em")
    refute html =~ "<img"
    assert html =~ ~s(role="img")
    assert html =~ ~s(aria-label="OpenAI")
  end

  test "ollama (monochrome) keeps the light plate in any theme" do
    html = render_component(&brand_icon/1, icon: "ollama")
    assert html =~ "bg-id-plate text-id-plate-ink"
    assert html =~ ~s(aria-hidden="true")
  end

  test "unknown keys fall back to neutral icons" do
    cpu = render_component(&brand_icon/1, icon: "foo")
    assert cpu =~ "lucide-cpu"
    assert cpu =~ "bg-id-neutral"
    assert cpu =~ ~s(data-brand="none")

    bot = render_component(&brand_icon/1, icon: nil, fallback: :bot)
    assert bot =~ "lucide-bot"
  end

  test "every table icon is vendored; colour availability matches the files" do
    for name <- HelmsmanWeb.Brands.icon_names(), do: assert(vendored?(name))
    assert color?("deepseek")
    refute color?("openai")
    refute color?("githubcopilot")
  end

  describe "model_label/1" do
    test "vendor icon, name and tooltip" do
      html = render_component(&model_label/1, model: "glm-5.3")
      assert html =~ ~s(data-model-vendor="zhipu")
      assert html =~ "智谱 · glm-5.3"
      assert html =~ ~s(aria-label="智谱")
    end

    test "the account's family overrides the inference" do
      html = render_component(&model_label/1, model: "glm-5.3", account_icon: "zai")
      assert html =~ ~s(data-model-vendor="zai")
      assert html =~ "Z.ai · glm-5.3"
    end

    test "unknown model: neutral chip icon and the bare name" do
      html = render_component(&model_label/1, model: "my-finetune-7b")
      assert html =~ ~s(data-model-vendor="none")
      assert html =~ "lucide-cpu"
      refute html =~ " · my-finetune-7b"
      assert html =~ "my-finetune-7b"
    end
  end
end
