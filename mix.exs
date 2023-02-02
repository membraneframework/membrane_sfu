defmodule Membrane.RTC.Engine.MixProject do
  use Mix.Project

  @version "0.9.0"
  @github_url "https://github.com/jellyfish-dev/membrane_rtc_engine"

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
      homepage_url: "https://membrane.stream",
      docs: docs(),

      # test coverage
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ],

      # dialyzer
      # this is because of optional dependencies
      # they are not included in PLT
      dialyzer: [
        plt_add_apps: [
          :membrane_http_adaptive_stream_plugin
        ]
      ]
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
      {:membrane_opentelemetry, "~> 0.1.0"},
      {:membrane_core, "~> 0.11.2"},
      {:membrane_telemetry_metrics, "~> 0.1.0"},
      {:membrane_webrtc_plugin, github: "membraneframework/membrane_webrtc_plugin"},
      {:membrane_rtp_format, "~> 0.6.0"},
      {:membrane_rtp_vp8_plugin, "~> 0.7.0"},
      {:membrane_rtp_opus_plugin, "~> 0.7.0"},
      {:membrane_rtp_h264_plugin, "~> 0.14.0"},
      {:membrane_tee_plugin, "~> 0.10.0"},
      {:uuid, "~> 1.1"},
      {:qex, "~> 0.5"},
      {:jason, "~> 1.2"},
      {:unifex, "~> 1.0"},
      {:dialyxir, "1.1.0", only: :dev, runtime: false},
      {:ex_doc, "0.28.3", only: :dev, runtime: false},
      {:credo, "~> 1.6", only: :dev, runtime: false},
      {:statistics, "~> 0.6.0"},

      # Optional deps for HLS endpoint
      {:membrane_http_adaptive_stream_plugin, "~> 0.10.0", optional: true},
      {:membrane_aac_plugin, "~> 0.13.0", optional: true},
      {:membrane_aac_fdk_plugin, "~> 0.14.0", optional: true},
      {:membrane_opus_plugin, "~> 0.16.0", optional: true},
      {:membrane_h264_ffmpeg_plugin, "~> 0.25.2", optional: true},
      {:membrane_video_compositor_plugin, "~> 0.1.0", optional: true},
      {:membrane_audio_mix_plugin, "~> 0.12.0", optional: true},
      {:membrane_generator_plugin,
       github: "membraneframework/membrane_generator_plugin", branch: "core-v0.11", optional: true},
      {:membrane_realtimer_plugin, "~> 0.6.0", optional: true},
      {:membrane_audio_filler_plugin, "~> 0.1.0"},

      # Test deps
      {:membrane_file_plugin, "~> 0.13.0"},
      {:excoveralls, "~> 0.15.0", only: :test, runtime: false},

      # Otel
      {:opentelemetry_api, "~> 1.0.0"},
      {:opentelemetry, "~> 1.0.0"}
    ]
  end

  defp aliases() do
    [
      integration_test: &run_integration_tests/1
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membrane.stream"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: extras(),
      formatters: ["html"],
      groups_for_extras: groups_for_extras(),
      assets: "internal_docs/assets",
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [
        Membrane.RTC.Engine,
        Membrane.RTC.Engine.Endpoint,
        Membrane.RTC.Engine.Event,
        Membrane.RTC.Engine.Exception,
        Membrane.RTC.Engine.Message
      ],
      before_closing_body_tag: &before_closing_body_tag/1,
      groups_for_modules: [
        Engine: [
          Membrane.RTC.Engine,
          Membrane.RTC.Engine.Metrics,
          Membrane.RTC.Engine.Message,
          Membrane.RTC.Engine.Notifications.TrackNotification,
          Membrane.RTC.Engine.Peer,
          Membrane.RTC.Engine.Track,
          Membrane.RTC.Engine.Track.BitrateEstimation
        ],
        Endpoints: [
          ~r/^Membrane\.RTC\.Engine\.Endpoint\.WebRTC($|\.)/,
          ~r/^Membrane\.RTC\.Engine\.Endpoint\.HLS($|\.)/
        ],
        Events: [
          ~r/^Membrane\.RTC\.Engine\.Event($|\.)/
        ],
        Messages: [
          ~r/^Membrane\.RTC\.Engine\.Message($|\.)/
        ],
        Exceptions: [
          ~r/^Membrane\.RTC\.Engine\.Exception($|\.)/
        ]
      ]
    ]
  end

  defp extras() do
    [
      "README.md",
      "LICENSE",

      # guides
      "guides/track_lifecycle.md",
      "guides/custom_endpoints.md",
      "guides/simulcast.md",
      "guides/logs.md",
      "guides/metrics.md",
      "guides/traces.md",
      "guides/vad.md",

      # internal docs
      "internal_docs/webrtc_media_events.md",
      "internal_docs/protocol.md",
      "internal_docs/webrtc_endpoint.md",
      "internal_docs/simulcast.md": [filename: "internal_simulcast"],
      "internal_docs/engine_architecture.md": [filename: "internal_engine_architecture"]
    ]
  end

  defp groups_for_extras() do
    [
      {"Developer docs", ~r/internal_docs\//},
      {"Guides", ~r/guides\//}
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script src="https://cdn.jsdelivr.net/npm/mermaid@9.1.1/dist/mermaid.min.js"></script>
    <style>
      .diagramWrapper svg {
        background-color: white;
      }
    </style>
    <script>
      document.addEventListener("DOMContentLoaded", function () {
        mermaid.initialize({ startOnLoad: false });
        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          graphEl.classList.add("diagramWrapper");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition, function (svgSource, bindListeners) {
            graphEl.innerHTML = svgSource;
            bindListeners && bindListeners(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp run_integration_tests(_cli_args) do
    Mix.shell().info("Getting mix dependencies in test_videoroom")

    {_io_stream, exit_status} =
      System.cmd("mix", ["deps.get"], cd: "integration_test/test_videoroom", into: IO.stream())

    if exit_status != 0, do: raise("Failed to get dependencies in test_videoroom")

    Mix.shell().info("Installing npm dependencies in test_videoroom")

    if packages_installed?("integration_test/test_videoroom/assets") do
      Mix.shell().info("* Already installed")
    else
      {_io_stream, exit_status} =
        System.cmd("npm", ["ci"], cd: "integration_test/test_videoroom/assets", into: IO.stream())

      if exit_status != 0, do: raise("Failed to install npm dependecies in test_videoroom")
    end

    Mix.shell().info("Running integration tests")

    {_io_stream, exit_status} =
      System.cmd("mix", ["test"], cd: "integration_test/test_videoroom", into: IO.stream())

    if exit_status != 0, do: raise("Failed to run integration tests")
  end

  defp packages_installed?(dir) do
    System.cmd("npm", ["ls", "--prefix", dir, "--prefer-offline"], stderr_to_stdout: true)
    |> case do
      {output, 0} ->
        missing =
          output
          |> String.split("\n")
          |> Enum.filter(&Regex.match?(~r/UNMET DEPENDENCY|empty/, &1))

        if length(missing) > 0,
          do: false,
          else: true

      {_output, _} ->
        false
    end
  end
end
