defmodule HelmsmanWeb.CommandPalette.Actions do
  @moduledoc "\"操作\": new task, theme switching and copying the current page link."
  @behaviour HelmsmanWeb.CommandPalette.Source
  use Gettext, backend: HelmsmanWeb.Gettext

  @impl true
  def search(_scope, query, _ctx) do
    q = String.downcase(String.trim(query))
    Enum.filter(all(), &(q == "" or String.contains?(String.downcase(&1.label), q)))
  end

  defp all do
    group = dgettext("ui", "操作")

    [
      %{
        group: group,
        label: dgettext("ui", "新建任务"),
        icon: "lucide-plus",
        action: {"new-task", %{}}
      },
      %{
        group: group,
        label: dgettext("ui", "切换主题：跟随系统"),
        icon: "lucide-monitor",
        action: {"theme", %{theme: "system"}}
      },
      %{
        group: group,
        label: dgettext("ui", "切换主题：亮"),
        icon: "lucide-sun",
        action: {"theme", %{theme: "light"}}
      },
      %{
        group: group,
        label: dgettext("ui", "切换主题：暗"),
        icon: "lucide-moon",
        action: {"theme", %{theme: "dark"}}
      },
      %{
        group: group,
        label: dgettext("ui", "复制当前页面链接"),
        icon: "lucide-link",
        action: {"copy-link", %{}}
      }
    ]
  end
end
