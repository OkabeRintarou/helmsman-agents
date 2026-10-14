defmodule HelmsmanWeb.AvatarData do
  @moduledoc """
  The avatar domain functions the web layer uses (add-actor-avatars D7, D10, D11;
  update-actor-icons D3, D12, D13): thin wrappers of `Helmsman.Avatars` and
  `Helmsman.Actors.appearance/1`, the avatar read addresses (D5) and the Chinese
  messages of the error codes.
  """
  use Gettext, backend: HelmsmanWeb.Gettext
  use HelmsmanWeb, :verified_routes

  alias Helmsman.{Actors, Avatars}

  @type target :: Avatars.target()

  defdelegate can_manage?(scope, target), to: Avatars
  defdelegate put(scope, target, binary), to: Avatars
  defdelegate delete(scope, target), to: Avatars
  defdelegate put_icon(scope, target, icon), to: Avatars

  @doc "`Helmsman.Actors.appearance/1`; empty without a workspace."
  def appearance(%{workspace: %{id: id}} = scope) when is_integer(id),
    do: Actors.appearance(scope)

  def appearance(_scope), do: %{}

  @doc """
  The signed-in user's own avatar as the user menu and the account settings page show
  it: `%{avatar_url, avatar_icon}` (`/users/avatar/:key` for an image, the icon name for
  a built-in icon, both nil without a custom avatar or a user).
  """
  @spec user_avatar(map() | nil) :: %{avatar_url: String.t() | nil, avatar_icon: String.t() | nil}
  def user_avatar(%{id: id}) when is_integer(id) do
    case Avatars.user_avatar(id) do
      {:image, key} -> %{avatar_url: ~p"/users/avatar/#{key}", avatar_icon: nil}
      {:icon, icon} -> %{avatar_url: nil, avatar_icon: icon}
      nil -> no_avatar()
    end
  end

  def user_avatar(_user), do: no_avatar()

  defp no_avatar, do: %{avatar_url: nil, avatar_icon: nil}

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
      unknown_icon: dgettext("ui", "这个图标不可用"),
      too_many_files: dgettext("ui", "一次只能上传一张图片"),
      too_complex: dgettext("ui", "图片过于复杂，请换一张"),
      source_too_large: dgettext("ui", "图片不能超过 10 MB")
    }
  end

  defp generic_message, do: dgettext("ui", "头像保存失败，请重试")
end
