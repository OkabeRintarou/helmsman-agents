defmodule Helmsman.VaultTest do
  # Changes environment variables to evaluate config/runtime.exs.
  use ExUnit.Case, async: false

  alias Helmsman.Encrypted.Binary
  alias Helmsman.Vault

  test "encrypted bytes do not contain the plaintext and decrypt back" do
    plaintext = "-----BEGIN RSA PRIVATE KEY----- very secret"

    {:ok, ciphertext} = Vault.encrypt(plaintext)
    refute ciphertext =~ "very secret"
    assert {:ok, ^plaintext} = Vault.decrypt(ciphertext)

    {:ok, dumped} = Binary.dump(plaintext)
    refute dumped =~ "very secret"
    assert {:ok, ^plaintext} = Binary.load(dumped)
  end

  describe "config/runtime.exs in production" do
    @vars ~w(DATABASE_URL SECRET_KEY_BASE HELMSMAN_MAILER_ADAPTER HELMSMAN_VAULT_KEY PHX_HOST)

    setup do
      saved = Map.new(@vars, &{&1, System.get_env(&1)})

      on_exit(fn ->
        Enum.each(saved, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)

      System.put_env(%{
        "DATABASE_URL" => "ecto://u:p@localhost/db",
        "SECRET_KEY_BASE" => String.duplicate("a", 64),
        "HELMSMAN_MAILER_ADAPTER" => "log",
        "PHX_HOST" => "hm.example.com"
      })

      :ok
    end

    defp read_runtime, do: Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)

    test "refuses to start without HELMSMAN_VAULT_KEY" do
      System.delete_env("HELMSMAN_VAULT_KEY")
      assert_raise RuntimeError, ~r/HELMSMAN_VAULT_KEY is missing/, &read_runtime/0
    end

    test "refuses a key that is not 32 bytes" do
      System.put_env("HELMSMAN_VAULT_KEY", Base.encode64("short"))
      assert_raise RuntimeError, ~r/HELMSMAN_VAULT_KEY must be/, &read_runtime/0
    end

    test "uses the decoded key" do
      key = :crypto.strong_rand_bytes(32)
      System.put_env("HELMSMAN_VAULT_KEY", Base.encode64(key))

      assert [default: {Cloak.Ciphers.AES.GCM, opts}] =
               read_runtime()[:helmsman][Helmsman.Vault][:ciphers]

      assert opts[:key] == key and opts[:tag] == "AES.GCM.V1"
    end
  end
end
