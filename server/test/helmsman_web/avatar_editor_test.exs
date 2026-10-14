defmodule HelmsmanWeb.AvatarEditorTest do
  @moduledoc """
  web-avatars 头像编辑对话框 / 个人头像 / 移除头像 on the account settings page
  (add-actor-avatars D10, D15), against `Helmsman.Avatars`. Writes are counted by the
  `{:user_avatar_changed}` each committed write broadcasts.
  """
  use HelmsmanWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import HelmsmanWeb.PortalHelpers

  alias Helmsman.{Avatars, AvatarsFixtures, Events}

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/users/settings")
    Events.subscribe(Events.topic(:user, user.id))

    %{
      view: view,
      user: user,
      webp: AvatarsFixtures.webp(64, 64),
      png: AvatarsFixtures.png(48, 48)
    }
  end

  # Committed avatar writes of the user since the last call.
  defp writes(n \\ 0) do
    receive do
      {:user_avatar_changed} -> writes(n + 1)
    after
      100 -> n
    end
  end

  defp own_avatar(user) do
    with key when is_binary(key) <- Avatars.user_avatar_key(user.id),
         {:ok, %{data: data}} <- Avatars.fetch_own(user.id, key) do
      data
    else
      _ -> nil
    end
  end

  defp editor(view), do: with_target(view, "#my-avatar")

  defp open_dialog(view) do
    view |> element("#my-avatar-upload-item") |> render_click()
    assert open?(view, "my-avatar-dialog")
    render_hook(editor(view), "source", %{})
    nonce(view)
  end

  defp nonce(view), do: portal_attr(view, "my-avatar-dialog", "#my-avatar-cropper", "data-nonce")

  defp dialog?(view, selector \\ "#my-avatar-dialog", text \\ nil),
    do: in_portal?(view, "my-avatar-dialog", selector, text)

  defp upload(view, name, content) do
    file_input(view, "#my-avatar-upload", :avatar, [
      %{name: name, content: content, type: "image/webp"}
    ])
  end

  test "the avatar section offers 上传图片… / 选择图标… and no 恢复缺省头像 without an avatar",
       %{view: view} do
    html = render(view)
    assert html =~ "显示在你加入的所有工作区"
    assert has_element?(view, "#my-avatar-menu-trigger[aria-label='更换头像']")
    assert has_element?(view, "#my-avatar-upload-item", "上传图片…")
    assert has_element?(view, "#my-avatar-icon-item", "选择图标…")
    refute has_element?(view, "#my-avatar-remove-item")
    assert has_element?(view, "#avatar-section [data-actor-mark=human]")
  end

  test "a completed upload saves once, closes the dialog and shows the avatar",
       %{view: view, user: user} = ctx do
    nonce = open_dialog(view)
    assert dialog?(view, "#my-avatar-save:not([disabled])")

    input = upload(view, "avatar-#{nonce}.webp", ctx.webp)
    render_upload(input, "avatar-#{nonce}.webp")

    assert writes() == 1
    assert own_avatar(user) == ctx.webp
    refute dialog?(view)
    assert render(view) =~ "头像已更新"
    key = Avatars.user_avatar_key(user.id)
    assert has_element?(view, "#avatar-section img[data-avatar][src='/users/avatar/#{key}']")
    assert has_element?(view, "#hm-personal-user img[data-avatar]")
    assert has_element?(view, "#my-avatar-remove-item")
  end

  test "an upload in progress does not write and marks the save button busy",
       %{view: view} = ctx do
    nonce = open_dialog(view)
    input = upload(view, "avatar-#{nonce}.webp", ctx.webp)

    render_upload(input, "avatar-#{nonce}.webp", 50)
    assert writes() == 0
    assert dialog?(view, "#my-avatar-save[aria-busy=true][disabled]")
    assert dialog?(view)

    render_upload(input, "avatar-#{nonce}.webp", 50)
    assert writes() == 1
    refute dialog?(view)
  end

  test "an upload finishing after the dialog was closed is dropped",
       %{view: view, user: user} = ctx do
    old = open_dialog(view)
    stale = upload(view, "avatar-#{old}.webp", ctx.webp)
    render_upload(stale, "avatar-#{old}.webp", 50)

    render_click(editor(view), "close", %{})
    refute dialog?(view)

    new = open_dialog(view)
    assert new != old
    input = upload(view, "avatar-#{new}.webp", ctx.png)
    render_upload(input, "avatar-#{new}.webp")
    assert own_avatar(user) == ctx.png

    # The old entry was cancelled; finishing it cannot write.
    catch_exit(render_upload(stale, "avatar-#{old}.webp", 50))
    assert own_avatar(user) == ctx.png
    assert writes() == 1
  end

  test "an entry named with a stale nonce is consumed and dropped",
       %{view: view} = ctx do
    old = open_dialog(view)
    # Choosing another image renews the nonce.
    render_hook(editor(view), "source", %{})
    assert nonce(view) != old

    input = upload(view, "avatar-#{old}.webp", ctx.webp)
    render_upload(input, "avatar-#{old}.webp")
    assert writes() == 0
    assert dialog?(view)
  end

  # The upload limit equals the domain's (256 KB), so a too large file is refused by the
  # upload itself (next test); the domain's own refusals come back the same way.
  test "server errors show in Chinese at the top, keep the dialog open, write nothing",
       %{view: view, user: user} do
    nonce = open_dialog(view)
    input = upload(view, "avatar-#{nonce}.webp", AvatarsFixtures.png(64, 32))
    render_upload(input, "avatar-#{nonce}.webp")

    assert writes() == 0
    assert own_avatar(user) == nil
    assert dialog?(view, "#my-avatar-error[role=alert]", "头像必须是正方形")
    assert dialog?(view, "#my-avatar-save:not([disabled])")
  end

  for {code, text, bytes} <- [
        {:unsupported_type, "只支持 PNG、JPEG 或 WebP 图片", quote(do: AvatarsFixtures.gif(64, 64))},
        {:invalid_image, "无法读取这张图片", quote(do: <<0x89, "PNG", 13, 10, 26, 10, "broken">>)},
        {:not_square, "头像必须是正方形", quote(do: AvatarsFixtures.webp(64, 48))},
        {:bad_dimensions, "头像边长须在 32 到 1024 像素之间", quote(do: AvatarsFixtures.png(16, 16))},
        {:animated, "不支持动图", quote(do: AvatarsFixtures.png(64, 64, apng: true))}
      ] do
    test "error #{code} is shown as #{text}", %{view: view} do
      nonce = open_dialog(view)
      input = upload(view, "avatar-#{nonce}.webp", unquote(bytes))
      render_upload(input, "avatar-#{nonce}.webp")
      assert dialog?(view, "#my-avatar-error", unquote(text))
    end
  end

  test "the other error codes have their messages" do
    assert HelmsmanWeb.AvatarData.error_message(:too_large) == "头像不能超过 256 KB"
    assert HelmsmanWeb.AvatarData.error_message(:forbidden) == "你没有权限修改这个头像"
    assert HelmsmanWeb.AvatarData.error_message(:not_found) == "身份不存在"
    assert HelmsmanWeb.AvatarData.error_message(:whatever) == "头像保存失败，请重试"
  end

  test "upload limits are reported in the dialog", %{view: view} do
    nonce = open_dialog(view)

    input =
      file_input(view, "#my-avatar-upload", :avatar, [
        %{name: "avatar-#{nonce}.webp", content: :binary.copy("a", 262_145), type: "image/webp"}
      ])

    assert {:error, [[_, :too_large]]} = render_upload(input, "avatar-#{nonce}.webp")
    # The browser follows the selection with the form's change event.
    view |> form("#my-avatar-upload") |> render_change()
    assert dialog?(view, "#my-avatar-error", "头像不能超过 256 KB")
  end

  test "client side errors (undecodable file, too complex)", %{view: view} do
    open_dialog(view)
    render_hook(editor(view), "client_error", %{"code" => "invalid_image"})
    assert dialog?(view, "#my-avatar-error", "无法读取这张图片")
    render_hook(editor(view), "client_error", %{"code" => "too_complex"})
    assert dialog?(view, "#my-avatar-error", "图片过于复杂，请换一张")
  end

  test "removing asks first, focuses 取消, then restores the default mark",
       %{view: view, user: user} = ctx do
    nonce = open_dialog(view)
    render_upload(upload(view, "avatar-#{nonce}.webp", ctx.webp), "avatar-#{nonce}.webp")

    assert has_element?(view, "#my-avatar-remove-item", "恢复缺省头像")
    view |> element("#my-avatar-remove-item") |> render_click()
    assert in_portal?(view, "my-avatar-remove", "#my-avatar-remove[role=alertdialog]")
    assert in_portal?(view, "my-avatar-remove", "#my-avatar-remove", "恢复缺省头像？")
    assert in_portal?(view, "my-avatar-remove", "#my-avatar-remove-default", "首字母")
    assert in_portal?(view, "my-avatar-remove", "#my-avatar-remove-cancel[autofocus]")

    render_click(editor(view), "remove", %{})
    assert own_avatar(user) == nil
    assert render(view) =~ "已恢复缺省头像"
    refute has_element?(view, "#avatar-section img[data-avatar]")
    refute has_element?(view, "#my-avatar-remove-item")
  end

  test "the dialog has an accessible cropper", %{view: view} do
    open_dialog(view)
    assert dialog?(view, "#my-avatar-crop canvas[role=application][aria-describedby]")
    assert dialog?(view, "#my-avatar-crop input[type=range][min='1'][max='4']")
    assert dialog?(view, "#my-avatar-crop canvas[data-crop-preview][data-size='40']")
    assert dialog?(view, "#my-avatar-crop canvas[data-crop-preview].rounded-full")
  end
end
