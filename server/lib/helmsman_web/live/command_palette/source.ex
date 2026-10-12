defmodule HelmsmanWeb.CommandPalette.Source do
  @moduledoc """
  A result source of the command palette. Feature changes add a module implementing
  this behaviour to `HelmsmanWeb.CommandPalette.sources/0` (e.g. `TaskSearch`, `Agents`).

  `ctx` carries `:nav` (resolved navigation groups), `:recent_tasks` and
  `:can_create_task?`.

  A result is a map with `:group` (heading), `:label`, optional `:sublabel` and `:icon`,
  and either `:path` (navigate there) or `:action` (`{name, params}` handled on the
  client, see `assets/js/app.js`).
  """

  @type result :: %{
          required(:group) => String.t(),
          required(:label) => String.t(),
          optional(:sublabel) => String.t(),
          optional(:icon) => String.t(),
          optional(:path) => String.t(),
          optional(:action) => {String.t(), map()}
        }

  @callback search(scope :: map() | nil, query :: String.t(), ctx :: map()) :: [result()]
end
