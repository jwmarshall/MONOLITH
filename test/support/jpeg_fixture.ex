defmodule Lovelace.TestSupport.JPEG do
  @moduledoc "Synthetic JPEG fixtures encoded locally by libvips; no provider or private content."

  alias Vix.Vips.{Image, Operation}

  def image(width \\ 2, height \\ 2, opts \\ []) do
    bands = Keyword.get(opts, :bands, 3)
    pixels = :binary.copy(<<24>>, width * height * bands)

    {:ok, image} =
      Image.new_from_binary(pixels, width, height, bands, :VIPS_FORMAT_UCHAR)

    {:ok, bytes} =
      Operation.jpegsave_buffer(image,
        Q: 90,
        interlace: Keyword.get(opts, :progressive, false)
      )

    bytes
  end

  def with_metadata(<<0xFF, 0xD8, rest::binary>>, metadata \\ "Synthetic provenance") do
    <<0xFF, 0xD8, 0xFF, 0xEF, byte_size(metadata) + 2::16, metadata::binary, rest::binary>>
  end
end
