defmodule Circuits.GPIO.MixProject do
  use Mix.Project

  def project do
    [
      app: :circuits_gpio,
      version: "0.3.1",
      elixir: "~> 1.6",
      description: description(),
      package: package(),
      source_url: "https://github.com/elixir-circuits/circuits_gpio",
      compilers: [:elixir_make | Mix.compilers()],
      make_targets: ["all"],
      make_clean: ["clean"],
      docs: [extras: ["README.md", "PORTING.md"], main: "readme"],
      aliases: [docs: ["docs", &copy_images/1], format: [&format_c/1, "format"]],
      start_permanent: Mix.env() == :prod,
      build_embedded: true,
      deps: deps()
    ]
  end

  def application, do: []

  defp description do
    "Use GPIOs in Elixir"
  end

  defp package do
    %{
      files: [
        "lib",
        "src/*.[ch]",
        "src/*.sh",
        "mix.exs",
        "README.md",
        "PORTING.md",
        "LICENSE",
        "Makefile"
      ],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/elixir-circuits/circuits_gpio"}
    }
  end

  defp deps do
    [
      {:elixir_make, "~> 0.5", runtime: false},
      {:ex_doc, "~> 0.11", only: :dev, runtime: false},
      {:dialyxir, "1.0.0-rc.4", only: :dev, runtime: false}
    ]
  end

  # Copy the images referenced by docs, since ex_doc doesn't do this.
  defp copy_images(_) do
    File.cp_r("assets", "doc/assets")
  end

  defp format_c([]) do
    astyle =
      System.find_executable("astyle") ||
        Mix.raise("""
        Could not format C code since astyle is not available.
        """)

    System.cmd(astyle, ["-n", "src/*.c", "src/*.h"], into: IO.stream(:stdio, :line))
  end

  defp format_c(_args), do: true
end
