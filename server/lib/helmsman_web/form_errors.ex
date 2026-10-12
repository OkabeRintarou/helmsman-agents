defmodule HelmsmanWeb.FormErrors do
  @moduledoc """
  Field errors of a domain changeset as display text: `%{field => [message]}`.

  Messages the domain layer writes itself (task and project validations, assignee
  checks) are translated here under the `ui` domain; Ecto's standard messages go
  through `HelmsmanWeb.CoreComponents.translate_error/1`.
  """
  use Gettext, backend: HelmsmanWeb.Gettext

  alias Ecto.Changeset

  @spec messages(Changeset.t()) :: %{atom() => [String.t()]}
  def messages(%Changeset{errors: errors}) do
    Enum.reduce(Enum.reverse(errors), %{}, fn {field, error}, acc ->
      Map.update(acc, field, [text(field, error)], &[text(field, error) | &1])
    end)
  end

  @doc "The first message of `field`, or nil."
  @spec first(%{atom() => [String.t()]}, atom()) :: String.t() | nil
  def first(errors, field), do: errors |> Map.get(field, []) |> List.first()

  defp text(:key, {"has already been taken", _}), do: dgettext("ui", "Key 已被占用")

  defp text(:key, {"must be 2-10 characters of A-Z and 0-9, starting with a letter", _}),
    do: dgettext("ui", "Key 须以大写字母开头，由 2–10 位大写字母或数字组成")

  defp text(
         :slug,
         {"must be 2-39 characters of a-z, 0-9 and -, starting with a letter or digit", _}
       ),
       do: dgettext("ui", "须为 2–39 位小写字母、数字或 -，以字母或数字开头")

  defp text(:scopes, {"must be one or more of: " <> _, _}),
    do: dgettext("ui", "至少选择一项")

  defp text(:default_agent_id, {"must be an active agent of your own", _}),
    do: dgettext("ui", "须为你名下未停用的 Agent")

  defp text(_field, {"should be at least %{count} character(s)", opts} = error) do
    if opts[:count] == 1,
      do: dgettext("ui", "不能为空"),
      else: HelmsmanWeb.CoreComponents.translate_error(error)
  end

  defp text(_field, {"must be 1-200 characters", _}), do: dgettext("ui", "长度须为 1–200 个字符")
  defp text(_field, {"must be 1-80 characters", _}), do: dgettext("ui", "长度须为 1–80 个字符")
  defp text(_field, {"must be 1-64 characters", _}), do: dgettext("ui", "长度须为 1–64 个字符")
  defp text(_field, {"must be at most 64 KB", _}), do: dgettext("ui", "不能超过 64 KB")

  # Markdown bodies (feedback content) are limited in whole kilobytes.
  defp text(_field, {"should be at most %{count} byte(s)", opts} = error) do
    case opts[:count] do
      count when is_integer(count) and count >= 1024 and rem(count, 1024) == 0 ->
        dgettext("ui", "不能超过 %{n} KB", n: div(count, 1024))

      _ ->
        HelmsmanWeb.CoreComponents.translate_error(error)
    end
  end

  defp text(_field, {"must be at most 20 labels", _}), do: dgettext("ui", "最多 20 个标签")

  defp text(_field, {"each label must be 1-32 characters", _}),
    do: dgettext("ui", "每个标签须为 1–32 个字符")

  defp text(_field, {"does not exist", _}), do: dgettext("ui", "不存在")
  defp text(_field, {"is disabled", _}), do: dgettext("ui", "已停用，不能指派")
  defp text(_field, {"cannot be the system identity", _}), do: dgettext("ui", "不能指派给系统身份")
  defp text(_field, error), do: HelmsmanWeb.CoreComponents.translate_error(error)
end
