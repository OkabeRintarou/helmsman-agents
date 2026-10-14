defmodule Helmsman.Avatars.ImageTest do
  use ExUnit.Case, async: true

  import Helmsman.AvatarsFixtures

  alias Helmsman.Avatars.Image

  test "accepts square PNG, JPEG and WebP files by their bytes" do
    assert {:ok, %{content_type: "image/png", edge: 64}} = Image.validate(png(64, 64))
    assert {:ok, %{content_type: "image/jpeg", edge: 128}} = Image.validate(jpeg(128, 128))
    assert {:ok, %{content_type: "image/webp", edge: 256}} = Image.validate(webp(256, 256))
    assert {:ok, %{content_type: "image/webp", edge: 32}} = Image.validate(webp(32, 32, :vp8l))

    assert {:ok, %{content_type: "image/webp", edge: 1024}} =
             Image.validate(webp(1024, 1024, :vp8))
  end

  test "a 256×256, 40 KB WebP is accepted" do
    data = webp(256, 256) <> :binary.copy(<<0>>, 40_000)
    assert {:ok, %{content_type: "image/webp", edge: 256}} = Image.validate(data)
  end

  test "not square" do
    assert Image.validate(png(300, 200)) == {:error, :not_square}
    assert Image.validate(jpeg(64, 65)) == {:error, :not_square}
    assert Image.validate(webp(64, 32, :vp8l)) == {:error, :not_square}
  end

  test "edges outside 32 to 1024" do
    assert Image.validate(png(31, 31)) == {:error, :bad_dimensions}
    assert Image.validate(webp(1025, 1025)) == {:error, :bad_dimensions}
    assert Image.validate(jpeg(2048, 2048)) == {:error, :bad_dimensions}
  end

  test "the type comes from the bytes: a GIF named .png is unsupported" do
    assert Image.validate(gif(64, 64)) == {:error, :unsupported_type}

    assert Image.validate("<svg xmlns='http://www.w3.org/2000/svg'/>") ==
             {:error, :unsupported_type}

    assert Image.validate(<<"RIFF", 0::32, "WAVE">>) == {:error, :unsupported_type}
  end

  test "size limit: 262144 bytes is fine, one more is too large" do
    assert byte_size(jpeg(64, 64, 262_144)) == 262_144
    assert {:ok, _} = Image.validate(jpeg(64, 64, 262_144))
    assert byte_size(jpeg(64, 64, 262_145)) == 262_145
    assert Image.validate(jpeg(64, 64, 262_145)) == {:error, :too_large}
  end

  test "animations" do
    assert Image.validate(png(64, 64, apng: true)) == {:error, :animated}
    assert Image.validate(webp(64, 64, :vp8x, animated: true)) == {:error, :animated}
  end

  test "unreadable headers are invalid images" do
    assert Image.validate("") == {:error, :invalid_image}
    assert Image.validate(nil) == {:error, :invalid_image}
    assert Image.validate(binary_part(png(64, 64), 0, 20)) == {:error, :invalid_image}
    assert Image.validate(<<0xFF, 0xD8, 0xFF, 0xD9>>) == {:error, :invalid_image}
    assert Image.validate(<<0xFF, 0xD8, 0xFF, 0xDA, 0, 2>>) == {:error, :invalid_image}

    assert Image.validate(<<"RIFF", 0::32, "WEBP", "VP8X", 10::little-32>>) ==
             {:error, :invalid_image}

    # A PNG that ends before any image data.
    png = png(64, 64)
    assert Image.validate(binary_part(png, 0, 33)) == {:error, :invalid_image}
  end
end
