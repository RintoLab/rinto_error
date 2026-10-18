defmodule RintoError.Source.Validator do
  @moduledoc false

  # Fresh modules register after verification. Previously built modules register
  # through __mix_recompile__?/0, including no-op builds and deleted handlers.
  # Always inspect final artifacts in Mix's callback, after all modules compile.
  def __after_verify__(module), do: register(module)

  def register(module) do
    if Code.ensure_loaded?(Mix.Project) and Process.whereis(Mix.ProjectStack) != nil and
         Mix.Project.get() do
      compile_path = Mix.Project.compile_path()

      case :code.which(module) do
        beam when is_list(beam) and beam != [] ->
          beam = List.to_string(beam)

          if Path.dirname(beam) == compile_path do
            Mix.Task.Compiler.after_compiler(:elixir, &check_build(&1, beam))
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  defp check_build({status, previous_diagnostics}, beam) do
    # A recompiled module may register twice; keep diagnostics unique.
    diagnostics = check_error_module(beam) -- previous_diagnostics

    Enum.each(diagnostics, fn diagnostic ->
      Mix.shell().error("#{diagnostic.file}:#{diagnostic.position}: #{diagnostic.message}")
    end)

    if diagnostics == [],
      do: {status, previous_diagnostics},
      else: {:error, previous_diagnostics ++ diagnostics}
  end

  defp check_error_module(beam) do
    case :beam_lib.chunks(String.to_charlist(beam), [:attributes]) do
      {:ok, {error_module, [attributes: attributes]}} ->
        check_contracts(error_module, Keyword.get(attributes, :rinto_error_source_contracts, []))

      {:error, :beam_lib, {:file_error, _, :enoent}} ->
        # The Error module itself may have been removed in this build.
        []
    end
  end

  defp check_contracts(error_module, contracts) do
    contracts
    |> List.flatten()
    |> Enum.flat_map(fn contract ->
      case check_handler(contract.implementation, contract.source) do
        :ok ->
          []

        {:error, reason} ->
          [
            %Mix.Task.Compiler.Diagnostic{
              compiler_name: "rinto_error",
              severity: :error,
              file: Path.expand(contract.file),
              position: contract.line,
              message:
                "#{inspect(error_module)} registers source #{inspect(contract.source)}, " <>
                  "but handler #{inspect(contract.implementation)} #{reason}"
            }
          ]
      end
    end)
  end

  defp check_handler(implementation, source) do
    filename = Atom.to_charlist(implementation) ++ ~c".beam"

    case :code.where_is_file(filename) do
      :non_existing ->
        {:error,
         "is unavailable; define a RintoError.Source defimpl with build/1 and to_payload/2"}

      beam ->
        case :beam_lib.chunks(beam, [:attributes, :exports]) do
          {:ok, {^implementation, [attributes: attributes, exports: exports]}} ->
            metadata = Keyword.get(attributes, :__impl__, [])

            cond do
              {:build, 1} not in exports ->
                {:error, "does not export build/1"}

              {:to_payload, 2} not in exports ->
                {:error, "does not export to_payload/2"}

              {:__impl__, 1} not in exports or
                Keyword.get(metadata, :protocol) != RintoError.Source or
                  Keyword.get(metadata, :for) != source ->
                {:error, "is not a RintoError.Source defimpl for #{inspect(source)}"}

              true ->
                :ok
            end

          _ ->
            {:error, "has no readable BEAM exports"}
        end
    end
  end
end
