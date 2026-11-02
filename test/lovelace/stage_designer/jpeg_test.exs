defmodule Lovelace.StageDesigner.JPEGTest do
  use ExUnit.Case, async: false

  alias Lovelace.StageDesigner.Image
  alias Lovelace.TestSupport.JPEG

  test "fully decodes baseline, progressive, grayscale and widescreen JPEG fixtures" do
    for {width, height, opts} <- [
          {2, 2, []},
          {3, 7, [progressive: true]},
          {8, 8, [bands: 1]},
          {1376, 768, []}
        ] do
      bytes = JPEG.image(width, height, opts)
      assert Image.format(bytes) == :jpeg
      assert Image.extension(:jpeg) == "jpg"
      assert Image.mime_type(:jpeg) == "image/jpeg"
      assert :ok = Image.validate(bytes)
    end
  end

  test "accepts original metadata without rewriting or transcoding bytes" do
    bytes = JPEG.image() |> JPEG.with_metadata()
    assert :ok = Image.validate(bytes)
    assert bytes =~ "Synthetic provenance"
  end

  test "rejects incomplete entropy data even when headers and final EOI are present" do
    bytes = JPEG.image(64, 64)
    {sos, 2} = :binary.match(bytes, <<0xFF, 0xDA>>)
    <<length::16>> = binary_part(bytes, sos + 2, 2)
    header = binary_part(bytes, 0, sos + 2 + length)
    assert {:error, :invalid_image} = Image.validate(header <> <<0xFF, 0xD9>>)
  end

  test "rejects truncation, wrong formats, and trailing container bytes" do
    valid = JPEG.image()

    for bytes <- [
          <<0xFF, 0xD8>>,
          <<0xFF, 0xD8, 0xFF, 0xD9>>,
          binary_part(valid, 0, byte_size(valid) - 1),
          valid <> "trailing",
          <<0xFF, 0xD8, 0xFF, 0xE1, 100::16, 0xFF, 0xD9>>
        ] do
      assert {:error, :invalid_image} = Image.validate(bytes)
    end
  end

  test "preflights byte and dimension limits before native decoding" do
    for {width, height} <- [{0, 1}, {1, 0}, {8193, 1}, {1, 8193}, {4001, 4000}] do
      assert {:error, :invalid_image} = Image.validate(frame(width, height))
    end

    assert {:error, :invalid_image} =
             Image.validate(<<0xFF, 0xD8, :binary.copy(<<0>>, 10 * 1024 * 1024)::binary>>)

    assert {:error, :invalid_image} = Image.validate(frame(1, 1, 12))
  end

  test "rejects excessive header fill markers without allocating native pixels" do
    bytes = <<0xFF, 0xD8>> <> :binary.copy(<<0xFF>>, 1025) <> <<0xD9>>
    assert {:error, :invalid_image} = Image.validate(bytes)
  end

  defp frame(width, height, precision \\ 8) do
    <<0xFF, 0xD8, 0xFF, 0xC0, 11::16, precision, height::16, width::16, 1, 1, 0x11, 0, 0xFF,
      0xD9>>
  end
end
