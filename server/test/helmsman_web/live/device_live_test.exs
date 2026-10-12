defmodule HelmsmanWeb.DeviceLiveTest do
  @moduledoc "Spec web-runtimes 设备码确认页."
  use HelmsmanWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Helmsman.AccountsFixtures
  import Helmsman.WorkspacesFixtures

  alias Helmsman.{Daemons, Repo}
  alias Helmsman.Daemons.DeviceCode
  alias Helmsman.Workspaces
  alias HelmsmanProtocol.DeviceAuth.CodeRequest
  alias HelmsmanProtocol.Machine

  setup %{conn: conn} do
    _admin = user_fixture()
    alice = user_fixture(%{display_name: "alice"})

    acme =
      workspace_fixture(alice, %{name: "Acme", slug: "acme#{System.unique_integer([:positive])}"})

    %{conn: log_in_user(conn, alice), alice: alice, acme: acme}
  end

  defp start_code do
    {:ok, machine} =
      Machine.new(%{
        machine_id: "m-#{System.unique_integer([:positive])}",
        name: "mbp",
        os: "darwin",
        arch: "arm64",
        daemon_version: "1.4.2"
      })

    {:ok, request} = CodeRequest.new(%{protocol: HelmsmanProtocol.version(), machine: machine})
    {:ok, code} = Daemons.start_device_auth(request)
    code
  end

  # "ABCD-2345" → "abcd2345"
  defp sloppy(user_code), do: user_code |> String.replace("-", "") |> String.downcase()

  defp beta(alice, role) do
    owner = user_fixture()
    beta = workspace_fixture(owner, %{name: "Beta"})
    member_fixture(beta, alice, role)
    beta
  end

  test "a code in the address goes straight to the confirmation", %{conn: conn, acme: acme} do
    code = start_code()
    {:ok, view, _html} = live(conn, "/device?code=#{sloppy(code.user_code)}")

    assert has_element?(view, "#device-confirm")
    assert has_element?(view, "[data-machine-name]", "mbp")
    assert has_element?(view, "[data-machine-os]", "darwin / arm64")
    assert has_element?(view, "[data-machine-version]", "1.4.2")
    assert has_element?(view, "#device-workspace-#{acme.id} input:not([disabled])")
    # The only selectable workspace is checked.
    assert has_element?(view, "#device-workspace-#{acme.id} input[checked]")
  end

  test "a visitor comes back to the address with its code after logging in" do
    code = start_code()
    path = "/device?code=#{code.user_code}"
    conn = get(build_conn(), path)
    assert redirected_to(conn) == "/users/log-in"

    user = set_password(user_fixture())

    conn =
      post(recycle(conn), "/users/log-in", %{
        "user" => %{"email" => user.email, "password" => valid_user_password()}
      })

    assert redirected_to(conn) == path
  end

  test "approving shows the runtime links and the daemon gets its token",
       %{conn: conn, acme: acme} do
    code = start_code()
    {:ok, view, _html} = live(conn, "/device?code=#{code.user_code}")

    view
    |> form("#device-approve-form", %{"workspace_ids" => ["", to_string(acme.id)]})
    |> render_submit()

    assert has_element?(view, "#device-approved", "已授权 mbp")

    assert has_element?(
             view,
             ~s(#device-runtimes-#{acme.slug}[href="/w/#{acme.slug}/settings/runtimes"])
           )

    assert {:ok, _token} = Daemons.exchange_device_code(code.device_code)
  end

  test "a viewer's workspace is greyed out", %{conn: conn, alice: alice, acme: acme} do
    beta = beta(alice, :viewer)
    code = start_code()
    {:ok, view, _html} = live(conn, "/device?code=#{code.user_code}")

    assert has_element?(view, "#device-workspace-#{beta.id} input[disabled]")
    assert has_element?(view, "#device-workspace-#{beta.id}", "viewer 不能运行 Agent")
    assert has_element?(view, "#device-workspace-#{acme.id} input[checked]")
  end

  test "denying", %{conn: conn} do
    code = start_code()
    {:ok, view, _html} = live(conn, "/device?code=#{code.user_code}")

    view |> element("#device-deny") |> render_click()
    assert has_element?(view, "#device-denied", "已拒绝这次登录")
    assert {:error, :access_denied} = Daemons.exchange_device_code(code.device_code)
  end

  test "an expired code keeps the input", %{conn: conn} do
    code = start_code()

    Repo.update_all(from(c in DeviceCode, where: c.user_code == ^code.user_code),
      set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)]
    )

    {:ok, view, _html} = live(conn, "/device")
    view |> form("#device-code-form", %{"code" => code.user_code}) |> render_submit()

    assert has_element?(view, "#device-enter", "设备码无效或已过期，请在终端重新执行 helmsman login")
    assert has_element?(view, ~s(#device-code[value="#{code.user_code}"]))
  end

  test "workspaces refused at approval are marked and the others stay checked",
       %{conn: conn, alice: alice, acme: acme} do
    beta = beta(alice, :member)
    code = start_code()
    {:ok, view, _html} = live(conn, "/device?code=#{code.user_code}")

    # Two selectable workspaces: nothing checked by default, 授权 disabled.
    refute has_element?(view, "#device-approve-form input[checked]")
    assert has_element?(view, "#device-approve[disabled]")

    ids = ["", to_string(acme.id), to_string(beta.id)]
    view |> form("#device-approve-form", %{"workspace_ids" => ids}) |> render_change()
    refute has_element?(view, "#device-approve[disabled]")

    membership = Workspaces.get_membership(acme.id, alice.id)
    Repo.update!(Ecto.Changeset.change(membership, role: :viewer))

    view |> form("#device-approve-form", %{"workspace_ids" => ids}) |> render_submit()

    assert has_element?(view, "#device-confirm")
    assert has_element?(view, ~s(#device-workspace-#{acme.id}[data-rejected]))
    assert has_element?(view, "#device-workspace-#{beta.id} input[checked]")
    refute has_element?(view, "#device-workspace-#{acme.id} input[checked]")
  end
end
