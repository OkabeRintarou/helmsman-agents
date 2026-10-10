defmodule Mix.Tasks.Helmsman.CheckUiClassesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Helmsman.CheckUiClasses

  defp write!(root, path, content) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, content)
  end

  defp paths(violations), do: Enum.map(violations, fn {path, line, _} -> {path, line} end)

  @tag :tmp_dir
  test "reports violations with path and line", %{tmp_dir: tmp} do
    write!(tmp, "lib/helmsman_web/live/run_live.html.heex", """
    <div class="px-2">
      <button class="btn btn-primary">Go</button>
    </div>
    """)

    write!(tmp, "lib/helmsman_web/live/run_live.ex", """
    defmodule RunLive do
      def render(assigns) do
        ~H\"\"\"
        <span
          class={["px-2", "bg-blue-500"]}
        >x</span>
        \"\"\"
      end
    end
    """)

    write!(tmp, "lib/helmsman_web/components/x.ex", """
    defmodule X do
      def x(assigns), do: ~H|<b style="color: #fff">x</b>|
    end
    """)

    assert [
             {"lib/helmsman_web/components/x.ex", 2, style_msg},
             {"lib/helmsman_web/live/run_live.ex", 5, palette_msg},
             {"lib/helmsman_web/live/run_live.html.heex", 2, btn_msg},
             {"lib/helmsman_web/live/run_live.html.heex", 2, btn_primary_msg}
           ] = CheckUiClasses.violations(tmp)

    assert style_msg =~ ~s("#fff")
    assert palette_msg =~ ~s("bg-blue-500")
    assert btn_msg =~ ~s("btn")
    assert btn_primary_msg =~ ~s("btn-primary")
  end

  @tag :tmp_dir
  test "detects variant-prefixed and nested-expression tokens", %{tmp_dir: tmp} do
    write!(tmp, "lib/helmsman_web/live/a.html.heex", """
    <a class={["px-2", @x && "hover:btn-primary", "!badge-sm"]}>a</a>
    <i class="md:hover:text-red-600/50 text-fg">b</i>
    <i style={"background: oklch(0.5 0.1 200); width: \#{@w}px"}>c</i>
    """)

    assert paths(CheckUiClasses.violations(tmp)) == [
             {"lib/helmsman_web/live/a.html.heex", 1},
             {"lib/helmsman_web/live/a.html.heex", 1},
             {"lib/helmsman_web/live/a.html.heex", 2},
             {"lib/helmsman_web/live/a.html.heex", 3}
           ]
  end

  @tag :tmp_dir
  test "accepts compliant files and ignores body text", %{tmp_dir: tmp} do
    write!(tmp, "lib/helmsman_web/live/ok.html.heex", """
    <div class="text-label bg-surface px-2 bg-input-x">
      Use btn bg-blue-500 #fff here.
    </div>
    """)

    write!(tmp, "lib/helmsman_web/components/x.ex", """
    defmodule X do
      def x(assigns), do: ~H|<button class="btn btn-primary">x</button>|
    end
    """)

    assert CheckUiClasses.violations(tmp) == []
    assert capture_io(fn -> CheckUiClasses.run(["--root", tmp]) end) =~ "OK"
  end

  @tag :tmp_dir
  test "palette classes are violations in the component layer too", %{tmp_dir: tmp} do
    write!(tmp, "lib/helmsman_web/components/x.ex", """
    defmodule X do
      def x(assigns), do: ~H|<button class="btn bg-red-500">x</button>|
    end
    """)

    assert paths(CheckUiClasses.violations(tmp)) == [{"lib/helmsman_web/components/x.ex", 2}]
  end

  @tag :tmp_dir
  test "run/1 raises Mix.Error on violations", %{tmp_dir: tmp} do
    write!(tmp, "lib/helmsman_web/live/bad.html.heex", ~s(<b class="badge">x</b>\n))

    assert_raise Mix.Error, ~r"lib/helmsman_web/live/bad.html.heex:1:", fn ->
      CheckUiClasses.run(["--root", tmp])
    end
  end
end
