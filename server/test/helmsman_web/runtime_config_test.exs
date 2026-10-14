defmodule HelmsmanWeb.RuntimeConfigTest do
  # config/runtime.exs in production (add-release-distribution decision 3).
  # Changes environment variables.
  use ExUnit.Case, async: false

  import Helmsman.RuntimeConfigHelpers

  defp read(overrides), do: read_prod_runtime(prod_env(overrides))

  describe "public URL" do
    test "https on 443 by default" do
      config = read(%{})
      assert config[:helmsman][:public_url] == "https://hm.example.com"
      url = config[:helmsman][HelmsmanWeb.Endpoint][:url]
      assert url[:scheme] == "https" and url[:port] == 443 and url[:host] == "hm.example.com"
      assert config[:helmsman][:secure_cookies] == true
      assert config[:helmsman][:force_ssl] == true
    end

    test "PHX_URL_SCHEME and PHX_URL_PORT" do
      config = read(%{"PHX_URL_SCHEME" => "http", "PHX_URL_PORT" => "8080"})
      assert config[:helmsman][:public_url] == "http://hm.example.com:8080"
      url = config[:helmsman][HelmsmanWeb.Endpoint][:url]
      assert url[:scheme] == "http" and url[:port] == 8080
      assert config[:helmsman][:secure_cookies] == false

      assert read(%{"PHX_URL_SCHEME" => "http"})[:helmsman][:public_url] ==
               "http://hm.example.com"

      assert read(%{"PHX_URL_PORT" => "8443"})[:helmsman][:public_url] ==
               "https://hm.example.com:8443"
    end

    test "empty optional values (NAME= in an env file) take their defaults" do
      config =
        read(%{
          "PHX_URL_SCHEME" => "",
          "PHX_URL_PORT" => "",
          "HELMSMAN_TRUSTED_PROXIES" => "",
          "HELMSMAN_DATA_DIR" => "",
          "HELMSMAN_DAEMON_DIST_DIR" => "",
          "HELMSMAN_DAEMON_DOWNLOAD_URL" => "",
          "HELMSMAN_LOG_FORMAT" => "",
          "HELMSMAN_LOG_LEVEL" => "",
          "RELEASE_NAME" => "helmsman"
        })

      assert config[:helmsman][:public_url] == "https://hm.example.com"
      assert config[:helmsman][:data_dir] == "/var/lib/helmsman"
      assert config[:helmsman][:daemon_dist_dir] == nil
      assert config[:helmsman][:daemon_download_url] == nil
      assert config[:logger][:level] == :info
      assert {LoggerJSON.Formatters.Basic, _} = config[:logger][:default_handler][:formatter]
    end

    test "invalid values name the variable" do
      assert_raise RuntimeError, ~r/PHX_URL_SCHEME/, fn -> read(%{"PHX_URL_SCHEME" => "ftp"}) end
      assert_raise RuntimeError, ~r/PHX_URL_PORT/, fn -> read(%{"PHX_URL_PORT" => "http"}) end
      assert_raise RuntimeError, ~r/PHX_URL_PORT/, fn -> read(%{"PHX_URL_PORT" => "70000"}) end
    end
  end

  describe "required variables" do
    for name <- ~w(DATABASE_URL SECRET_KEY_BASE HELMSMAN_VAULT_KEY PHX_HOST) do
      test "#{name} missing or empty: an error naming it" do
        assert_raise RuntimeError, ~r/#{unquote(name)}/, fn -> read(%{unquote(name) => nil}) end
        assert_raise RuntimeError, ~r/#{unquote(name)}/, fn -> read(%{unquote(name) => ""}) end
      end
    end
  end

  describe "trusted proxies" do
    test "none by default" do
      assert read(%{})[:helmsman][:trusted_proxies] == []
      assert read(%{"HELMSMAN_TRUSTED_PROXIES" => ""})[:helmsman][:trusted_proxies] == []
    end

    test "comma-separated addresses and CIDR ranges" do
      value = " 10.0.0.0/8, 172.16.0.0/12 ,192.0.2.1,fd00::/8"

      assert read(%{"HELMSMAN_TRUSTED_PROXIES" => value})[:helmsman][:trusted_proxies] ==
               ["10.0.0.0/8", "172.16.0.0/12", "192.0.2.1", "fd00::/8"]
    end

    test "an invalid entry names the variable" do
      for bad <- ["10.0.0.0/33", "proxy.example.com", "10.0.0/8", "::1/129", "10.0.0.0/x"] do
        assert_raise RuntimeError, ~r/HELMSMAN_TRUSTED_PROXIES/, fn ->
          read(%{"HELMSMAN_TRUSTED_PROXIES" => bad})
        end
      end
    end
  end

  describe "directories and downloads" do
    test "defaults" do
      config = read(%{})[:helmsman]
      assert config[:data_dir] == "/var/lib/helmsman"
      assert config[:daemon_dist_dir] == nil
      assert config[:daemon_download_url] == nil
    end

    test "HELMSMAN_DATA_DIR, HELMSMAN_DAEMON_DIST_DIR and HELMSMAN_DAEMON_DOWNLOAD_URL" do
      config =
        read(%{
          "HELMSMAN_DATA_DIR" => "/data",
          "HELMSMAN_DAEMON_DIST_DIR" => "/app/daemon-dist",
          "HELMSMAN_DAEMON_DOWNLOAD_URL" => "https://example.com/releases/download/v1/"
        })[:helmsman]

      assert config[:data_dir] == "/data"
      assert config[:daemon_dist_dir] == "/app/daemon-dist"
      assert config[:daemon_download_url] == "https://example.com/releases/download/v1"

      assert_raise RuntimeError, ~r/HELMSMAN_DAEMON_DOWNLOAD_URL/, fn ->
        read(%{"HELMSMAN_DAEMON_DOWNLOAD_URL" => "example.com/x"})
      end
    end
  end

  describe "logging" do
    test "JSON with the metadata allowlist by default in a release; text otherwise" do
      config = read(%{"RELEASE_NAME" => "helmsman"})

      assert {LoggerJSON.Formatters.Basic, %{metadata: metadata}} =
               config[:logger][:default_handler][:formatter]

      assert :request_id in metadata and :mcp_tool in metadata and :run_id in metadata
      assert config[:logger][:level] == :info

      text = read(%{"RELEASE_NAME" => "helmsman", "HELMSMAN_LOG_FORMAT" => "text"})
      refute text[:logger][:default_handler]
      assert :request_id in text[:logger][:default_formatter][:metadata]

      refute read(%{})[:logger][:default_handler]
    end

    test "HELMSMAN_LOG_LEVEL" do
      assert read(%{"HELMSMAN_LOG_LEVEL" => "warning"})[:logger][:level] == :warning

      assert_raise RuntimeError, ~r/HELMSMAN_LOG_LEVEL/, fn ->
        read(%{"HELMSMAN_LOG_LEVEL" => "loud"})
      end

      assert_raise RuntimeError, ~r/HELMSMAN_LOG_FORMAT/, fn ->
        read(%{"HELMSMAN_LOG_FORMAT" => "xml"})
      end
    end
  end
end
