# SPDX-FileCopyrightText: 2026 One Raven, Inc.
# SPDX-FileContributor: Ben Youngblood
#
# SPDX-License-Identifier: Apache-2.0

defmodule Bonjex.MixProject do
  use Mix.Project

  @version "0.1.0"
  @description "DNS-SD (Bonjour) for Elixir through the system mDNS responder"
  @source_url "https://github.com/one-raven/bonjex"

  def project do
    [
      app: :bonjex,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      make_error_message: """
      Failed to build c_src/bonjex_port.c.

      It needs <dns_sd.h> and libdns_sd. On macOS they are in the SDK and
      libSystem. On Linux and Nerves, they come from Apple's mDNSResponder:
      https://github.com/apple-oss-distributions/mDNSResponder
      """,
      deps: deps(),
      description: @description,
      dialyzer: [
        flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs]
      ],
      docs: docs(),
      package: package(),
      aliases: aliases()
    ]
  end

  def cli do
    [
      preferred_envs: %{
        docs: :docs,
        "hex.publish": :docs,
        "hex.build": :docs
      }
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:elixir_make, "~> 0.9", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.29", only: :docs, runtime: false}
    ]
  end

  defp package do
    %{
      files: [
        "lib",
        "c_src",
        "Makefile",
        "mix.exs",
        "README*",
        "CHANGELOG*",
        "LICENSES"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url
      }
    }
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp aliases do
    [
      lint: ["format", "deps.unlock --unused", "credo", "dialyzer"]
    ]
  end
end
