defmodule HelmsmanWeb.LiveFallback do
  @moduledoc """
  Catch-all `handle_info/2` clause for LiveViews (add-workspace-settings-ui D8, DR-2).

  The shell subscribes to `workspace:<id>` and passes every message it does not handle
  itself to the page when the page exports `handle_info/2`. A page only writes the
  clauses it cares about; this `@before_compile` hook (added by
  `HelmsmanWeb.live_view/0`) appends a clause ignoring the rest:

    * the page defines no `handle_info/2` → nothing is added (the shell halts instead);
    * the page has its own catch-all (first argument a bare variable, no guard) →
      nothing is added, the page's clause wins;
    * otherwise a clause logging the message at debug level and returning
      `{:noreply, socket}` is appended after the page's clauses.

  Errors raised inside a matching clause are not caught.
  """

  defmacro __before_compile__(env) do
    case Module.get_definition(env.module, {:handle_info, 2}) do
      {:v1, :def, _meta, clauses} ->
        if Enum.any?(clauses, &catch_all?/1), do: nil, else: fallback()

      _ ->
        nil
    end
  end

  defp fallback do
    quote do
      def handle_info(message, socket) do
        require Logger

        Logger.debug(fn ->
          "#{inspect(__MODULE__)} ignored message #{inspect(message, limit: 5)}"
        end)

        {:noreply, socket}
      end
    end
  end

  defp catch_all?({_meta, [message, _socket], [], _body}), do: var?(message)
  defp catch_all?(_clause), do: false

  defp var?({name, _meta, context}) when is_atom(name) and is_atom(context), do: true
  defp var?(_ast), do: false
end
