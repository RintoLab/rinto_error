defmodule RintoError.SourceBuildValidationTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @moduletag timeout: 60_000

  setup %{tmp_dir: dir} do
    # Exercise the package as a dependency in a real Mix project, with standard
    # compilers and no optional dependencies. Keep dependency builds offline.
    library = Path.join(dir, "vendor/rinto_error")
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(library)

    for file <- ~w(rinto_error.ex rinto_error/source.ex rinto_error/source/validator.ex
                   rinto_error/catalog.ex rinto_error/message.ex) do
      target = Path.join([library, "lib", file])
      File.mkdir_p!(Path.dirname(target))
      File.cp!(Path.expand("lib/#{file}"), target)
    end

    File.write!(Path.join(library, "mix.exs"), """
    defmodule Library.MixProject do
      use Mix.Project
      def project, do: [app: :rinto_error, version: "0.1.0", deps: []]
    end
    """)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Probe.MixProject do
      use Mix.Project
      def project do
        [app: :probe, version: "0.1.0", deps: [{:rinto_error, path: "vendor/rinto_error"}]]
      end
    end
    """)

    write(dir, "source.ex", "defmodule Probe.Source do\n  defstruct []\nend\n")
    :ok
  end

  test "missing handlers fail ordinary builds, unchanged retries, and recover after repair", %{
    tmp_dir: dir
  } do
    write(dir, "error.ex", error_module())

    for _ <- 1..2 do
      output = compile_error!(dir)
      assert output =~ "lib/error.ex:4:"
      assert output =~ "Probe.Error registers source Probe.Source"
      assert output =~ "handler RintoError.Source.Probe.Source is unavailable"
    end

    write(dir, "handler.ex", implementation())
    compile_ok!(dir)
    refute compile_ok!(dir) =~ "Compiling"
  end

  test "both same-file definition orders work with consolidated protocol dispatch", %{
    tmp_dir: dir
  } do
    # The later implementation can also pattern-match the already defined Error.
    write(
      dir,
      "error.ex",
      error_module() <> implementation("def error?(%Probe.Error{}), do: true")
    )

    compile_ok!(dir)

    {output, status} =
      mix(dir, [
        "run",
        "--no-start",
        "-e",
        """
        error = Probe.Error.exception(struct!(Probe.Source))
        :probe = error.kind
        true = RintoError.Source.Probe.Source.error?(error)
        true = Protocol.consolidated?(RintoError.Source)
        %{kind: :probe, data: %{}, errors: []} = Probe.Error.to_payload(error)
        IO.puts("protocol output")
        """
      ])

    assert status == 0, output
    assert output =~ "protocol output"

    write(dir, "error.ex", implementation() <> error_module())
    compile_ok!(dir)
  end

  test "changing only a handler to omit public build/1 rechecks the unchanged Error", %{
    tmp_dir: dir
  } do
    write(dir, "error.ex", error_module())
    write(dir, "handler.ex", implementation())
    compile_ok!(dir)
    original_error = File.read!(Path.join(dir, "lib/error.ex"))

    for invalid_build <- ["def build(_, _), do: %{}", "defp build(_), do: %{}"] do
      write(dir, "handler.ex", """
      defimpl RintoError.Source, for: Probe.Source do
        #{invalid_build}
      end
      """)

      output = compile_error!(dir)
      assert output =~ "handler RintoError.Source.Probe.Source does not export build/1"
      assert File.read!(Path.join(dir, "lib/error.ex")) == original_error
      assert compile_error!(dir) =~ "does not export build/1"

      write(dir, "handler.ex", implementation())
      compile_ok!(dir)
    end
  end

  test "deleting only the implementation fails an incremental build", %{tmp_dir: dir} do
    write(dir, "error.ex", error_module())
    write(dir, "handler.ex", implementation())
    compile_ok!(dir)

    File.rm!(Path.join(dir, "lib/handler.ex"))
    assert compile_error!(dir) =~ "handler RintoError.Source.Probe.Source is unavailable"
    assert compile_error!(dir) =~ "handler RintoError.Source.Probe.Source is unavailable"
  end

  test "a missing output callback fails validation and recovers after repair", %{tmp_dir: dir} do
    write(dir, "error.ex", error_module())
    write(dir, "handler.ex", implementation())
    compile_ok!(dir)

    write(dir, "handler.ex", """
    defimpl RintoError.Source, for: Probe.Source do
      def build(source), do: %{raw: source}
    end
    """)

    assert compile_error!(dir) =~ "does not export to_payload/2"
    assert compile_error!(dir) =~ "does not export to_payload/2"
    write(dir, "handler.ex", implementation())
    compile_ok!(dir)
  end

  test "an application can exclude the supplied Ecto implementation and provide its own", %{
    tmp_dir: dir
  } do
    library = Path.join(dir, "vendor/rinto_error")
    File.cp!("lib/rinto_error/changeset.ex", Path.join(library, "lib/rinto_error/changeset.ex"))

    File.write!(Path.join(library, "mix.exs"), """
    defmodule Library.MixProject do
      use Mix.Project
      def project do
        [app: :rinto_error, version: "0.1.0",
         deps: [{:ecto, path: #{inspect(Path.expand("deps/ecto"))}, optional: true}]]
      end
    end
    """)

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Probe.MixProject do
      use Mix.Project
      def project do
        [app: :probe, version: "0.1.0", deps: [
          {:rinto_error, path: "vendor/rinto_error"},
          {:ecto, path: #{inspect(Path.expand("deps/ecto"))}, override: true},
          {:decimal, path: #{inspect(Path.expand("deps/decimal"))}, override: true},
          {:telemetry, path: #{inspect(Path.expand("deps/telemetry"))}, override: true}
        ]]
      end
    end
    """)

    write(dir, "error.ex", error_module("", "Ecto.Changeset"))
    compile_ok!(dir)

    run_ok!(dir, """
    true = Protocol.consolidated?(RintoError.Source)
    changeset = Ecto.Changeset.change({%{}, %{name: :string}})
    %{raw: ^changeset} = RintoError.Source.build(changeset)
    %{kind: :probe, data: %{}, errors: []} =
      changeset |> Probe.Error.exception() |> Probe.Error.to_payload()
    """)

    File.mkdir_p!(Path.join(dir, "config"))

    File.write!(Path.join(dir, "config/config.exs"), """
    import Config
    config :rinto_error, exclude_default_sources: [Ecto.Changeset]
    """)

    {output, status} = mix(dir, ["deps.compile", "rinto_error", "--force"])
    assert status == 0, output
    refute output =~ "warning:"
    assert compile_error!(dir) =~ "handler RintoError.Source.Ecto.Changeset is unavailable"

    write(dir, "handler.ex", """
    defimpl RintoError.Source, for: Ecto.Changeset do
      @impl true
      def build(changeset), do: %{raw: :custom, metadata: %{changeset: changeset}}

      @impl true
      def to_payload(%Ecto.Changeset{errors: []}, error) do
        %{data: %{custom: true}, errors: RintoError.Changeset.to_errors(error.metadata.changeset)}
      end
    end
    """)

    compile_ok!(dir)
    refute compile_ok!(dir) =~ "Compiling"

    run_ok!(dir, """
    true = Protocol.consolidated?(RintoError.Source)
    changeset = Ecto.Changeset.change({%{}, %{name: :string}})
    changeset = Ecto.Changeset.validate_required(changeset, [:name])
    error = Probe.Error.exception(changeset)
    :custom = error.raw
    %{kind: :probe, data: %{custom: true}, errors: [%{kind: :required}]} =
      Probe.Error.to_payload(error)
    %{data: %{custom: true}} = RintoError.Source.to_payload(struct(Ecto.Changeset), error)
    """)
  end

  test "an existing custom recompile hook is preserved", %{tmp_dir: dir} do
    error =
      String.replace(error_module(), "use RintoError", """
      use RintoError
      def __mix_recompile__?, do: File.exists?("recompile.flag")
      """)

    write(dir, "error.ex", error)
    write(dir, "handler.ex", implementation())
    compile_ok!(dir)
    refute compile_ok!(dir) =~ "Compiling"

    File.write!(Path.join(dir, "recompile.flag"), "")
    assert compile_ok!(dir) =~ "Compiling 1 file"
    File.rm!(Path.join(dir, "recompile.flag"))
    File.rm!(Path.join(dir, "lib/handler.ex"))
    assert compile_error!(dir) =~ "handler RintoError.Source.Probe.Source is unavailable"
  end

  test "callbacks use the final catalog and tolerate removal of an Error module", %{tmp_dir: dir} do
    write(dir, "error.ex", error_module())
    write(dir, "handler.ex", implementation())
    compile_ok!(dir)

    File.rm!(Path.join(dir, "lib/handler.ex"))

    write(
      dir,
      "error.ex",
      String.replace(error_module(), "entry_for Probe.Source, :probe", "entry :probe")
    )

    compile_ok!(dir)

    File.rm!(Path.join(dir, "lib/error.ex"))
    compile_ok!(dir)
  end

  test "unchanged validation errors are reported once when Error is recompiled", %{tmp_dir: dir} do
    write(dir, "error.ex", error_module())
    assert compile_error!(dir) =~ "handler RintoError.Source.Probe.Source is unavailable"

    write(dir, "error.ex", error_module() <> "# trigger recompilation\n")
    output = compile_error!(dir)

    assert length(Regex.scan(~r/handler RintoError.Source.Probe.Source is unavailable/, output)) ==
             1
  end

  test "Changeset requires a protocol implementation just like any other source", %{tmp_dir: dir} do
    write(dir, "ecto.ex", """
    defmodule Ecto.Changeset do
      defstruct []
    end
    defmodule RintoError.Changeset do
      def build(source), do: %{raw: source}
      def to_payload(_source, _error), do: %{data: %{}, errors: []}
    end
    """)

    write(dir, "error.ex", error_module("", "Ecto.Changeset"))
    assert compile_error!(dir) =~ "handler RintoError.Source.Ecto.Changeset is unavailable"

    write(dir, "handler.ex", """
    defimpl RintoError.Source, for: Ecto.Changeset do
      def build(source), do: %{raw: source}
      def to_payload(_source, _error), do: %{data: %{}, errors: []}
    end
    """)

    compile_ok!(dir)
    File.rm!(Path.join(dir, "lib/handler.ex"))
    assert compile_error!(dir) =~ "handler RintoError.Source.Ecto.Changeset is unavailable"
  end

  test "a named module with build/1 cannot substitute for defimpl", %{tmp_dir: dir} do
    write(dir, "error.ex", error_module())

    write(dir, "handler.ex", """
    defmodule RintoError.Source.Probe.Source do
      def build(source), do: %{raw: source}
      def to_payload(_source, _error), do: %{data: %{}, errors: []}
    end
    """)

    assert compile_error!(dir) =~ "is not a RintoError.Source defimpl for Probe.Source"
    write(dir, "handler.ex", implementation())
    compile_ok!(dir)
  end

  test "an ordinary catalog does not require handlers for unregistered structs", %{tmp_dir: dir} do
    write(dir, "error.ex", """
    defmodule Probe.Error do
      use RintoError
      catalog do
        entry :ordinary
      end
    end
    """)

    compile_ok!(dir)
  end

  defp error_module(options \\ "", source \\ "Probe.Source") do
    """
    defmodule Probe.Error do
      use RintoError#{options}
      catalog do
        entry_for #{source}, :probe
      end
    end
    """
  end

  defp implementation(extra \\ "") do
    """
    defimpl RintoError.Source, for: Probe.Source do
      def build(source), do: %{raw: source}
      def to_payload(_source, _error), do: %{data: %{}, errors: []}
      #{extra}
    end
    """
  end

  defp write(dir, file, content), do: File.write!(Path.join([dir, "lib", file]), content)

  defp compile_ok!(dir) do
    {output, status} = mix(dir, ["compile", "--warnings-as-errors"])
    assert status == 0, output
    refute output =~ "warning:"
    output
  end

  defp compile_error!(dir) do
    {output, status} = mix(dir, ["compile"])
    assert status != 0, output
    output
  end

  defp run_ok!(dir, script) do
    {output, status} = mix(dir, ["run", "--no-start", "-e", script])
    assert status == 0, output
    refute output =~ "warning:"
  end

  defp mix(dir, args) do
    System.cmd(System.find_executable("mix"), args,
      cd: dir,
      stderr_to_stdout: true,
      env: [{"MIX_ENV", "dev"}, {"MIX_BUILD_PATH", nil}, {"MIX_DEPS_PATH", nil}]
    )
  end
end
