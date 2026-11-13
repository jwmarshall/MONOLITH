defmodule Monolith.TestSupport.PNG do
  @moduledoc "Small valid static PNG fixtures; no provider or private content."

  def image(width \\ 2, height \\ 2) do
    header = <<width::32, height::32, 8, 6, 0, 0, 0>>
    row = <<0>> <> :binary.copy(<<24, 24, 24, 255>>, width)
    pixels = :binary.copy(row, height)

    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      chunk("IHDR", header),
      chunk("IDAT", :zlib.compress(pixels)),
      chunk("IEND", "")
    ])
  end

  @doc false
  def chunk(type, data) do
    <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32([type, data])::32>>
  end
end
