defmodule HelmsmanWeb.AvatarData do
  @moduledoc """
  The avatar domain functions the web layer uses (add-actor-avatars D7, D10, D11):
  thin wrappers of `Helmsman.Avatars` and `Helmsman.Actors.appearance/1`, the avatar
  read addresses (D5) and the Chinese messages of the error codes.
  """
  use Gettext, backend: HelmsmanWeb.Gettext
  use HelmsmanWeb, :verified_routes

  alias Helmsman.{Actors, Avatars}

  @type target :: Avatars.target()

  defdelegate put(scope, target, binary), to: Avatars
  defdelegate delete(scope, target), to: Avatars
  defdelegate can_manage?(scope, target), to: Avatars

  @doc "`Helmsman.Actors.appearance/1`; empty without a workspace."
  def appearance(%{workspace: %{id: id}} = scope) when is_integer(id),
    do: Actors.appearance(scope)

  def appearance(_scope), do: %{}

  @doc "`Helmsman.Avatars.user_avatar_key/1` (nil without a user)."
  def user_avatar_key(user_id) when is_integer(user_id), do: Avatars.user_avatar_key(user_id)
  def user_avatar_key(_user_id), do: nil

  @doc "Address of the signed-in user's own avatar (`/users/avatar/:key`), nil without one."
  @spec user_avatar_url(map() | nil) :: String.t() | nil
  def user_avatar_url(%{id: id}) do
    case user_avatar_key(id) do
      nil -> nil
      key -> ~p"/users/avatar/#{key}"
    end
  end

  def user_avatar_url(_user), do: nil

  @doc "Address of an avatar `key` readable in the workspace `slug` (`/w/:slug/avatars/:key`)."
  @spec workspace_avatar_url(String.t(), String.t() | nil) :: String.t() | nil
  def workspace_avatar_url(_slug, nil), do: nil
  def workspace_avatar_url(slug, key), do: ~p"/w/#{slug}/avatars/#{key}"

  @doc "The Chinese message of an avatar error code (domain, upload or client side)."
  @spec error_message(atom()) :: String.t()
  def error_message(code), do: Map.get_lazy(messages(), code, &generic_message/0)

  defp messages do
    %{
      unsupported_type: dgettext("ui", "只支持 PNG、JPEG 或 WebP 图片"),
      not_accepted: dgettext("ui", "只支持 PNG、JPEG 或 WebP 图片"),
      invalid_image: dgettext("ui", "无法读取这张图片"),
      too_large: dgettext("ui", "头像不能超过 256 KB"),
      not_square: dgettext("ui", "头像必须是正方形"),
      bad_dimensions: dgettext("ui", "头像边长须在 32 到 1024 像素之间"),
      animated: dgettext("ui", "不支持动图"),
      forbidden: dgettext("ui", "你没有权限修改这个头像"),
      not_found: dgettext("ui", "身份不存在"),
      too_many_files: dgettext("ui", "一次只能上传一张图片"),
      too_complex: dgettext("ui", "图片过于复杂，请换一张"),
      source_too_large: dgettext("ui", "图片不能超过 10 MB")
    }
  end

  defp generic_message, do: dgettext("ui", "头像保存失败，请重试")
end
