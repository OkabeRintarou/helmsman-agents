defmodule HelmsmanWeb.PageController do
  use HelmsmanWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
