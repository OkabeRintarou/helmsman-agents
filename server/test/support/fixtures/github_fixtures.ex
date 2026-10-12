defmodule Helmsman.GitHubFixtures do
  @moduledoc """
  Test helpers for the GitHub integration: the App configuration from
  environment variables (set for the whole run by `test_helper.exs`),
  installations, repositories, webhook signatures and `Req.Test` stubs.
  No real credential is ever used.
  """

  # Test-only helpers used by both domain and web test cases.
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Helmsman.GitHub.Installation
  alias Helmsman.GitHub.Repository
  alias Helmsman.Repo

  @app_id 4242
  @env_vars ~w(GITHUB_APP_ID GITHUB_APP_PRIVATE_KEY GITHUB_WEBHOOK_SECRET
               GITHUB_APP_CLIENT_ID GITHUB_APP_CLIENT_SECRET)

  def app_id, do: @app_id
  def env_vars, do: @env_vars

  @doc "Sets the five App variables, with a fresh RSA key."
  def put_app_env do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    System.put_env(%{
      "GITHUB_APP_ID" => Integer.to_string(@app_id),
      "GITHUB_APP_PRIVATE_KEY" => pem,
      "GITHUB_WEBHOOK_SECRET" => "test-webhook-secret",
      "GITHUB_APP_CLIENT_ID" => "Iv1.testclient",
      "GITHUB_APP_CLIENT_SECRET" => "test-client-secret"
    })
  end

  @doc """
  Removes the App variables for the rest of the test (`async: false`
  tests only); they are restored on exit.
  """
  def without_app_env(names \\ @env_vars) do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(names, &System.delete_env/1)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  def webhook_secret, do: System.fetch_env!("GITHUB_WEBHOOK_SECRET")
  def private_key_pem, do: System.fetch_env!("GITHUB_APP_PRIVATE_KEY")

  def unique_github_id, do: System.unique_integer([:positive]) + 1_000_000

  @doc "Inserts a connected installation of `workspace`."
  def installation_fixture(workspace, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        installation_id: unique_github_id(),
        account_login: "acme",
        account_type: "Organization",
        fetched_at: DateTime.add(DateTime.utc_now(), -3600)
      })

    Repo.insert!(struct!(Installation, Map.put(attrs, :workspace_id, workspace.id)))
  end

  @doc "Inserts a repository of `installation`."
  def repository_fixture(%Installation{} = installation, attrs \\ %{}) do
    github_id = unique_github_id()

    attrs =
      Enum.into(attrs, %{
        github_id: github_id,
        owner: "acme",
        name: "repo#{github_id}",
        default_branch: "main"
      })

    Repo.insert!(
      struct!(
        Repository,
        Map.merge(attrs, %{
          workspace_id: installation.workspace_id,
          installation_id: installation.id
        })
      )
    )
  end

  @doc "A GitHub repository object as the API returns it."
  def github_repo(github_id, owner, name, extra \\ %{}) do
    Map.merge(
      %{
        "id" => github_id,
        "name" => name,
        "full_name" => "#{owner}/#{name}",
        "owner" => %{"login" => owner},
        "default_branch" => "main",
        "archived" => false,
        "private" => true
      },
      extra
    )
  end

  @doc "An installation object as `GET /app/installations/:id` returns it."
  def github_installation(installation_id, extra \\ %{}) do
    Map.merge(
      %{
        "id" => installation_id,
        "account" => %{"login" => "acme", "type" => "Organization"},
        "suspended_at" => nil
      },
      extra
    )
  end

  @doc "Answers an access token request with a token valid one hour."
  def token_response(conn, token \\ "ghs_test_installation_token") do
    expires_at = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    conn
    |> Plug.Conn.put_status(201)
    |> Req.Test.json(%{"token" => token, "expires_at" => expires_at})
  end

  @doc "Sends 404 with GitHub's error body."
  def not_found(conn),
    do: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})

  @doc "Stubs GitHub with `fun.(conn)`, which may dispatch on method and path."
  def stub_github(fun), do: Req.Test.stub(Helmsman.GitHub.Client, fun)

  @doc "Reads and JSON-decodes a stubbed request's body."
  def json_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  @doc "The `X-Hub-Signature-256` of `body` under the test webhook secret."
  def sign(body) do
    mac = :crypto.mac(:hmac, :sha256, webhook_secret(), body)
    "sha256=" <> Base.encode16(mac, case: :lower)
  end
end
