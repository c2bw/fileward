defmodule FileWard.MixProject do
  use Mix.Project

  @version "0.1.0"
  @url "https://github.com/c2bw/fileward"

  def project do
    [
      app: :file_ward,
      name: "FileWard",
      version: @version,
      source_url: @url,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      description: "Bounded file intake, pinned HTTPS retrieval and private ZIP extraction"
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto, :public_key, :ssl], mod: {FileWard.Application, []}]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:mint, "~> 1.11.0"},
      {:plug, "~> 1.19", optional: true},
      {:telemetry, "~> 1.3", optional: true},
      {:stream_data, "~> 1.2", only: :test}
    ]
  end

  defp package do
    [
      name: "file_ward",
      files: ~w(lib docs mix.exs README.md CHANGELOG.md LICENSE),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @url,
        "Documentation" => "https://hexdocs.pm/file_ward"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      canonical: "https://hexdocs.pm/file_ward",
      source_ref: "v#{@version}",
      extras:
        ~w(README.md docs/USAGE.md docs/LIMITS.md docs/SECURITY.md docs/THREAT_MODEL.md CHANGELOG.md)
    ]
  end
end
