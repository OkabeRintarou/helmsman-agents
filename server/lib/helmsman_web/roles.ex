defmodule HelmsmanWeb.Roles do
  @moduledoc "Display names of workspace roles, highest first."
  use Gettext, backend: HelmsmanWeb.Gettext

  @roles [:owner, :admin, :member, :viewer]

  @doc "Roles from highest to lowest."
  def all, do: @roles

  @doc "The role's display name."
  def label(:owner), do: dgettext("ui", "所有者")
  def label(:admin), do: dgettext("ui", "管理员")
  def label(:member), do: dgettext("ui", "成员")
  def label(:viewer), do: dgettext("ui", "只读")
  def label(role) when is_binary(role), do: role |> String.to_existing_atom() |> label()
end
