defmodule RintoError.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/RintoLab/rinto_error"

  def project do
    [
      app: :rinto_error,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      dialyzer: dialyzer(),
      description:
        "Reusable error struct for construction, public payloads, log formatting, and changeset traversal.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [preferred_envs: [check: :test, dialyzer: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      check: ["format --check-formatted", "compile --warnings-as-errors", "test", "dialyzer"]
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "_build/plts"
    ]
  end

  defp deps do
    [
      {:ecto, "~> 3.13", optional: true},
      {:jason, "~> 1.4", optional: true},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end
end
