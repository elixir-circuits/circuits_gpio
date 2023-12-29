defmodule Circuits.GPIO.MixProject do
  use Mix.Project

  @version "2.0.0-pre.0"
  @description "Use GPIOs in Elixir"
  @source_url "https://github.com/elixir-circuits/circuits_gpio"

  def project do
    [
      app: :circuits_gpio,
      version: @version,
      elixir: "~> 1.11",
      description: @description,
      package: package(),
      source_url: @source_url,
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      make_env: make_env(),
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

  def application do
    # IMPORTANT: This provides a default at runtime and at compile-time when
    # circuits_gpio is pulled in as a dependency.
    [env: [default_backend: default_backend()], extra_applications: [:logger]]
  end

  defp package do
    %{
      files: [
        "lib",
        "c_src/*.[ch]",
        "mix.exs",
        "README.md",
        "PORTING.md",
        "LICENSES/*",
        "CHANGELOG.md",
        "Makefile"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
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
      assets: "assets",
      extras: ["README.md", "PORTING.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end

  defp default_backend(), do: default_backend(Mix.env(), Mix.target())
  defp default_backend(:test, _target), do: {Circuits.GPIO.CDev, test: true}

  defp default_backend(_env, :host) do
    case :os.type() do
      {:unix, :linux} -> Circuits.GPIO.CDev
      _ -> {Circuits.GPIO.CDev, test: true}
    end
  end

  # Assume Nerves for a default
  defp default_backend(_env, _not_host), do: Circuits.GPIO.CDev

  defp make_env() do
    # Since user configuration hasn't been loaded into the application
    # environment when `project/1` is called, load it here for building
    # the NIF.
    backend = Application.get_env(:circuits_gpio, :default_backend, default_backend())

    %{"CIRCUITS_GPIO_BACKEND" => cdev_compile_mode(backend)}
  end

  defp cdev_compile_mode({Circuits.GPIO.CDev, options}) do
    if Keyword.get(options, :test) do
      "test"
    else
      "cdev"
    end
  end

  defp cdev_compile_mode(Circuits.GPIO.CDev) do
    "cdev"
  end

  defp cdev_compile_mode(_other) do
    "disabled"
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
