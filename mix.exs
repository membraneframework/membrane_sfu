defmodule Membrane.RTC.Engine.MixProject do
  use Mix.Project

  @version "0.1.0-alpha"
  @github_url "https://github.com/membraneframework/membrane_rtc_engine"

  def project do
    [
      app: :membrane_rtc_engine,
      version: @version,
      elixir: "~> 1.10",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # hex
      description: "Membrane RTC Engine and its client library",
      package: package(),

      # docs
      name: "Membrane RTC Engine",
      source_url: @github_url,
      homepage_url: "https://membraneframework.org",
      docs: docs()
    ]
  end

  def application do
    [
      mod: {Membrane.RTC.Engine.App, []},
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 0.7.0", override: true},
      {:membrane_webrtc_plugin, "0.1.0-alpha"},
      {:membrane_element_tee, "~> 0.4.1"},
      {:membrane_element_fake, "~> 0.4.0"},
      {:jason, "~> 1.2"},
      {:dialyxir, "1.1.0", only: :dev, runtime: false},
      {:ex_doc, "0.24.2", only: :dev, runtime: false},
      {:credo, "~> 1.4", only: :dev, runtime: false}
    ]
  end

  defp aliases() do
    [
      compile: ["compile", &compile_ts/1],
      docs: ["docs", &generate_ts_docs/1]
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "LICENSE"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [Membrane.RTC.Engine]
    ]
  end

  defp compile_ts(_) do
    Mix.shell().info("Installing npm dependencies")
    {result, exit_status} = System.cmd("npm", ["ci"], cd: "assets")
    Mix.shell().info(result)
    if exit_status != 0, do: raise("Failed to install npm dependecies")

    Mix.shell().info("Compiling TS files")
    {result, exit_status} = System.cmd("npm", ["run", "build"], cd: "assets")
    Mix.shell().info(result)
    if exit_status != 0, do: raise("Failed to compile TS files")
  end

  defp generate_ts_docs(_) do
    Mix.shell().info("Generating TS docs")
    {result, exit_status} = System.cmd("npm", ["run", "docs"], cd: "assets")
    Mix.shell().info(result)
    if exit_status != 0, do: raise("Failed to generate TS docs")
  end
end
