defmodule MonolithWeb.VendorAssetsTest do
  use ExUnit.Case, async: true

  @vendor_path Path.expand("../../assets/vendor/gsap", __DIR__)
  @topbar_path Path.expand("../../assets/vendor", __DIR__)

  test "Topbar source, full MIT license and metadata match the reviewed records" do
    checksums = [
      {"topbar.js", "5b865680f8fc3f1326859a824f31478ba7f0154d3926ffb1b3cf7f1c50f2fb2e"},
      {"topbar.LICENSE.txt", "c4ad21361d61199361282d25950da9ad9b60a2f8476d4524c4f95524b5278990"},
      {"topbar.upstream-package.json",
       "30d5483d3e1d2c5021b3b5bcefee2dde0e5e176cf3a0fc57eb899c88198ec768"}
    ]

    for {file, expected} <- checksums do
      actual =
        @topbar_path
        |> Path.join(file)
        |> File.read!()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert actual == expected,
             "unexpected vendored bytes in #{file}; review upstream before repinning"
    end

    metadata =
      @topbar_path |> Path.join("topbar.upstream-package.json") |> File.read!() |> Jason.decode!()

    assert metadata["name"] == "topbar"
    assert metadata["version"] == "3.0.0"
    assert metadata["license"] == "MIT"
  end

  test "Topbar retains the full MIT notice in an esbuild-preserved legal comment" do
    source = @topbar_path |> Path.join("topbar.js") |> File.read!()
    license = @topbar_path |> Path.join("topbar.LICENSE.txt") |> File.read!()
    legal_comment = "\n/*! @license\n" <> license <> "*/\n"

    assert license =~ "Copyright (c) 2024 Buu Nguyen"
    assert license =~ "Copyright 2021 Buu Nguyen."
    assert license =~ "Permission is hereby granted, free of charge"
    assert license =~ "The above copyright notice and this permission notice shall be included in"
    assert license =~ ~s(THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND)
    assert String.ends_with?(source, legal_comment)

    # The sole local addition is the full notice; all upstream source bytes remain intact.
    upstream_digest =
      source
      |> String.replace_suffix(legal_comment, "")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert upstream_digest == "5683ab34a4fa482d9bc1227a539c445fd5dc934530a05b68f03d00cd97cae2a0"
    assert source =~ "topbar 3.0.0"

    app = Path.expand("../../assets/js/app.js", __DIR__) |> File.read!()
    assert app =~ ~s(import topbar from "../vendor/topbar")
  end

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
