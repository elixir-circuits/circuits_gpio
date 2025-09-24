defmodule Circuits.GPIO.MixProject do
  use Mix.Project

  @app :circuits_gpio
  @version "2.1.3"
  @description "Use GPIOs in Elixir"
  @source_url "https://github.com/elixir-circuits/#{@app}"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.13",
      description: @description,
      package: package(),
      source_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      docs: docs(),
      aliases: [format: [&format_c/1, "format"]],
      start_permanent: Mix.env() == :prod,
      dialyzer: dialyzer(),
      deps: deps(),
      preferred_cli_env: %{
        docs: :docs,
        "hex.publish": :docs,
        "hex.build": :docs
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    # IMPORTANT: This provides a default at runtime and at compile-time when
    # circuits_gpio is pulled in as a dependency.
    [env: [backends: default_backends()], extra_applications: [:logger]]
  end

  defp package do
    %{
      files: [
        "CHANGELOG.md",
        "c_src/*.[ch]",
        "c_src/linux/gpio.h",
        "lib",
        "LICENSES/*",
        "Makefile",
        "mix.exs",
        "NOTICE",
        "PORTING.md",
        "README.md",
        "REUSE.toml"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/#{@app}/changelog.html",
        "GitHub" => @source_url,
        "REUSE Compliance" =>
          "https://api.reuse.software/info/github.com/elixir-circuits/#{@app}"
      }
    }
  end

  defp deps() do
    [
      {:ex_doc, "~> 0.22", only: :docs, runtime: false},
      {:credo, "~> 1.6", only: :dev, runtime: false},
      {:dialyxir, "~> 1.2", only: :dev, runtime: false},
      {:elixir_make, "~> 0.6", runtime: false}
    ]
  end

  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs],
      list_unused_filters: true,
      plt_file: {:no_warn, "_build/plts/dialyzer.plt"}
    ]
  end

  defp docs do
    [
      assets: %{"assets" => "assets"},
      extras: ["README.md", "PORTING.md", "CHANGELOG.md"],
      main: "readme",
      skip_code_autolink_to: ["Circuits.GPIO.pin/1"],
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp default_backends(), do: default_backends(Mix.env(), Mix.target())
  defp default_backends(:test, _target), do: []
  defp default_backends(:docs, _target), do: []

  defp default_backends(_env, :host) do
    case :os.type() do
      {:unix, :linux} -> [Circuits.GPIO.CDev]
      _ -> []
    end
  end

  # MIX_TARGET set to something besides host
  defp default_backends(env, _not_host) do
    # If CROSSCOMPILE is set, then the Makefile will use the crosscompiler and
    # assume a Linux/Nerves build If not, then the NIF will be build for the
    # host, so use the default host backend
    case System.fetch_env("CROSSCOMPILE") do
      {:ok, _} -> [Circuits.GPIO.CDev]
      :error -> default_backends(env, :host)
    end
  end

  defp format_c([]) do
    case System.find_executable("astyle") do
      nil ->
        Mix.Shell.IO.info("Install astyle to format C code.")

      astyle ->
        System.cmd(astyle, ["-n", "c_src/*.c"], into: IO.stream(:stdio, :line))
    end
  end

  defp format_c(_args), do: true
end
