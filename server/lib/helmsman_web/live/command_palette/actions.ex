defmodule HelmsmanWeb.CommandPalette.Actions do
  @moduledoc "\"操作\": new task, theme switching and copying the current page link."
  @behaviour HelmsmanWeb.CommandPalette.Source
  use Gettext, backend: HelmsmanWeb.Gettext

  @impl true
  def search(_scope, query, ctx) do
    q = String.downcase(String.trim(query))

    ctx
    |> all()
    |> Enum.filter(&(q == "" or String.contains?(String.downcase(&1.label), q)))
  end

  # Without :create_task (viewers) the 新建任务 action is left out.
  defp all(ctx) do
    group = dgettext("ui", "操作")

    new_task =
      if Map.get(ctx, :can_create_task?, true),
        do: [
          %{
            group: group,
            label: dgettext("ui", "新建任务"),
            icon: "lucide-plus",
            action: {"new-task", %{}}
          }
        ],
        else: []

    new_task ++
      [
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
