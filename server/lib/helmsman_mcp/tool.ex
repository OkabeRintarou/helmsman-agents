defmodule HelmsmanMCP.Tool do
  @moduledoc """
  An MCP tool (designs/08 §2), independent of the MCP library.

      use HelmsmanMCP.Tool,
        name: "whoami",
        description: "Show the identity your writes are recorded as.",
        schema: %{},
        mode: :read

  `schema` uses the anubis notation (`%{name: {:required, :string,
  description: "..."}}`). A `:write` tool gets an optional `actor`
  argument; the pipeline resolves the writer from it and removes it before
  `call/2`. `:read` tools run with the current session identity in
  `scope.actor`.
  """

  alias HelmsmanMCP.Context

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback input_schema() :: map()
  @callback mode() :: :read | :write
  @callback call(args :: %{String.t() => term()}, Context.t()) ::
              {:ok, term()} | {:error, term()}

  @actor_field {:string,
                description:
                  "Write as this agent of yours instead of the session identity " <>
                    "(e.g. keel/dev)."}

  @doc false
  def actor_field, do: @actor_field

  defmacro __using__(opts) do
    name = Keyword.fetch!(opts, :name)
    description = Keyword.fetch!(opts, :description)
    schema = Keyword.fetch!(opts, :schema)
    mode = Keyword.fetch!(opts, :mode)

    unless mode in [:read, :write] do
      raise ArgumentError, "mode must be :read or :write, got: #{inspect(mode)}"
    end

    schema =
      if mode == :write,
        do: quote(do: Map.put_new(unquote(schema), :actor, HelmsmanMCP.Tool.actor_field())),
        else: schema

    quote do
      @behaviour HelmsmanMCP.Tool

      @impl HelmsmanMCP.Tool
      def name, do: unquote(name)

      @impl HelmsmanMCP.Tool
      def description, do: unquote(description)

      @impl HelmsmanMCP.Tool
      def mode, do: unquote(mode)

      @impl HelmsmanMCP.Tool
      def input_schema, do: unquote(schema)
    end
  end
end
