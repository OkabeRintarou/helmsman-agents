defmodule HelmsmanWeb.SettingsLive.Errors do
  @moduledoc "Messages for errors returned by the domain to the settings pages (design D6)."
  use Gettext, backend: HelmsmanWeb.Gettext

  @doc "The message shown for a failed settings operation."
  def message(:forbidden), do: dgettext("ui", "没有权限执行此操作")
  def message(:last_owner), do: dgettext("ui", "工作区至少需要一个所有者")
  def message(:not_found), do: dgettext("ui", "对象已不存在，列表已刷新")
  def message(_reason), do: dgettext("ui", "操作失败，请稍后重试")

  @doc "Whether the page should reload its lists after `reason`."
  def reload?(reason), do: reason in [:forbidden, :not_found, :last_owner]
end
