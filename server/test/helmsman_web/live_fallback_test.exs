defmodule HelmsmanWeb.LiveFallbackTest do
  # Compiles throwaway LiveView modules; not async because of the global compiler state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defp compile(name, body) do
    module = Module.concat(__MODULE__, name)

    source = """
    defmodule #{inspect(module)} do
      use HelmsmanWeb, :live_view

      @impl true
      def render(assigns), do: ~H"<p>x</p>"

      #{body}
    end
    """

    {_result, diagnostics} =
      Code.with_diagnostics(fn -> Code.compile_string(source, "live_fallback_test.ex") end)

    {module, diagnostics}
  end

  defp socket, do: %Phoenix.LiveView.Socket{}

  test "partial clauses get a fallback that ignores other messages" do
    {module, diagnostics} =
      compile(Partial, """
      @impl true
      def handle_info({:members_changed}, socket), do: {:noreply, Phoenix.Component.assign(socket, :hit, true)}
      """)

    assert diagnostics == []
    assert {:noreply, %{assigns: %{hit: true}}} = module.handle_info({:members_changed}, socket())

    Logger.put_module_level(module, :debug)
    on_exit(fn -> Logger.delete_module_level(module) end)

    log =
      capture_log([level: :debug], fn ->
        assert {:noreply, _} = module.handle_info({:unknown_event, 1}, socket())
      end)

    assert log =~ "ignored message {:unknown_event, 1}"
  end

  test "a page's own catch-all wins and nothing is appended" do
    {module, diagnostics} =
      compile(OwnCatchAll, """
      @impl true
      def handle_info({:members_changed}, socket), do: {:noreply, socket}
      def handle_info(_msg, socket), do: {:noreply, Phoenix.Component.assign(socket, :own, true)}
      """)

    assert diagnostics == []
    assert {:noreply, %{assigns: %{own: true}}} = module.handle_info(:anything, socket())
  end

  test "a guarded variable clause is not a catch-all" do
    {module, diagnostics} =
      compile(Guarded, """
      @impl true
      def handle_info(msg, socket) when is_tuple(msg), do: {:noreply, Phoenix.Component.assign(socket, :tuple, true)}
      """)

    assert diagnostics == []
    assert {:noreply, %{assigns: %{tuple: true}}} = module.handle_info({:x}, socket())
    assert {:noreply, socket} = module.handle_info(:not_a_tuple, socket())
    refute Map.has_key?(socket.assigns, :tuple)
  end

  test "pages without handle_info/2 get none" do
    {module, diagnostics} = compile(NoInfo, "")
    assert diagnostics == []
    refute function_exported?(module, :handle_info, 2)
  end

  test "errors inside a matching clause are not caught" do
    {module, []} =
      compile(Raises, """
      @impl true
      def handle_info(:boom, _socket), do: raise("boom")
      """)

    assert_raise RuntimeError, "boom", fn -> module.handle_info(:boom, socket()) end
  end
end
