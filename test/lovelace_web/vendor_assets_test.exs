defmodule LovelaceWeb.VendorAssetsTest do
  use ExUnit.Case, async: true

  @vendor_path Path.expand("../../assets/vendor/gsap", __DIR__)

  test "GSAP and its upstream metadata match the pinned vendored distribution" do
    checksums = [
      {"gsap.js", "01effe0e121c22ba0f885a3f091f3dc6d1f0d445c4fba37dcb298e314eca5cfb"},
      {"upstream-package.json",
       "85cc13e31f7a3cd124b587a40f545f265f47d0dfb9a556bb122d70fc0fca3459"}
    ]

    for {file, expected} <- checksums do
      actual =
        @vendor_path
        |> Path.join(file)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert actual == expected
    end

    metadata =
      @vendor_path |> Path.join("upstream-package.json") |> File.read!() |> Jason.decode!()

    assert metadata["name"] == "gsap"
    assert metadata["version"] == "3.15.0"
  end

  test "the vendored distribution retains its custom license and copyright notice" do
    license = @vendor_path |> Path.join("LICENSE.txt") |> File.read!()
    source = @vendor_path |> Path.join("gsap.js") |> File.read!()

    assert license =~ ~s(Standard "No Charge" GSAP License)
    assert license =~ "III. RESTRICTIONS"
    assert license =~ "Copyright (©) 2025, Webflow"
    assert source =~ "@license Copyright 2008-2026, GreenSock. All rights reserved."
    assert source =~ "https://gsap.com/standard-license"
  end
end
