defmodule RintoError.Catalog do
  @moduledoc false

  @status_range 100..599

  @doc false
  def parse!(ast, caller) do
    entries = collect(ast, caller)
    ensure_unique_kinds!(entries)
    ensure_unique_sources!(entries)
    entries
  end

  @doc false
  def validate_use_options!(opts, caller) do
    validate_options!(opts, [:inspect_opts], "use RintoError", caller.file, caller.line)
  end

  defp collect(nil, _caller), do: []

  defp collect({:__block__, _, nodes}, caller) do
    Enum.flat_map(nodes, &collect(&1, caller))
  end

  defp collect({:entry, meta, args}, caller) do
    [parse_entry(args, caller.file, meta[:line] || caller.line)]
  end

  defp collect({:entry_for, meta, args}, caller) do
    line = meta[:line] || caller.line

    case args do
      [source, kind] ->
        [parse_source_entry(source, kind, [], caller, line)]

      [source, kind, opts] ->
        [parse_source_entry(source, kind, opts, caller, line)]

      _ ->
        compile_error!(
          caller.file,
          line,
          "entry_for expects a struct module, kind, and optional literal keyword options: as, http_status, doc"
        )
    end
  end

  defp collect(ast, caller) do
    compile_error!(
      caller.file,
      caller.line,
      "catalog only accepts entry or entry_for calls, got: #{Macro.to_string(ast)}"
    )
  end

  defp parse_source_entry(source, kind, opts, caller, line) do
    module =
      case source do
        {:__aliases__, _, _} -> Macro.expand(source, caller)
        atom when is_atom(atom) -> atom
        _ -> nil
      end

    unless is_atom(module) and module not in [nil, true, false] and
             Code.ensure_compiled(module) == {:module, module} and
             function_exported?(module, :__struct__, 0) do
      compile_error!(
        caller.file,
        line,
        "entry_for expects an available struct module, got: #{Macro.to_string(source)}"
      )
    end

    parse_entry([kind, opts], caller.file, line)
    |> Map.put(:source, module)
  end

  defp parse_entry([kind], file, line), do: parse_entry([kind, []], file, line)

  defp parse_entry([kind, opts], file, line) when is_list(opts) do
    validate_options!(opts, [:as, :http_status, :doc], "entry", file, line)

    kind = literal_atom!(kind, :kind, file, line)

    %{
      kind: kind,
      as: literal_atom!(Keyword.get(opts, :as, kind), :as, file, line),
      http_status:
        case Keyword.fetch(opts, :http_status) do
          {:ok, status} -> normalize_status!(status, file, line)
          :error -> nil
        end,
      doc:
        case Keyword.fetch(opts, :doc) do
          {:ok, doc} -> literal_doc!(doc, file, line)
          :error -> nil
        end,
      file: file,
      line: line
    }
  end

  defp parse_entry(_args, file, line) do
    compile_error!(
      file,
      line,
      "entry expects a kind and optional literal keyword options: as, http_status, doc"
    )
  end

  defp normalize_status!(status, _file, _line)
       when is_integer(status) and status in @status_range do
    status
  end

  defp normalize_status!(status, file, line) do
    compile_error!(
      file,
      line,
      "http_status must be an integer from 100 to 599, got: #{inspect(status)}"
    )
  end

  defp validate_options!(opts, allowed, context, file, line) do
    unless is_list(opts) and Keyword.keyword?(opts) do
      compile_error!(file, line, "#{context} options must be a literal keyword list")
    end

    Enum.reduce(opts, [], fn {key, _value}, seen ->
      unless key in allowed do
        compile_error!(
          file,
          line,
          "unknown #{context} option #{inspect(key)}; expected one of #{inspect(allowed)}"
        )
      end

      if key in seen do
        compile_error!(file, line, "#{context} option #{inspect(key)} is duplicated")
      end

      [key | seen]
    end)
  end

  defp literal_doc!(value, _file, _line) when is_binary(value), do: value

  defp literal_doc!(value, file, line) do
    compile_error!(file, line, "doc must be a string literal, got: #{inspect(value)}")
  end

  defp literal_atom!(value, _field, _file, _line)
       when is_atom(value) and not is_nil(value) and not is_boolean(value) do
    value
  end

  defp literal_atom!(value, field, file, line) do
    compile_error!(file, line, "#{field} must be an atom literal, got: #{inspect(value)}")
  end

  defp ensure_unique_kinds!(entries) do
    Enum.reduce(entries, %{}, fn entry, seen ->
      if Map.has_key?(seen, entry.kind) do
        compile_error!(entry.file, entry.line, "kind #{inspect(entry.kind)} is already defined")
      else
        Map.put(seen, entry.kind, true)
      end
    end)
  end

  defp ensure_unique_sources!(entries) do
    Enum.reduce(entries, MapSet.new(), fn entry, seen ->
      case Map.get(entry, :source) do
        nil ->
          seen

        source ->
          if MapSet.member?(seen, source) do
            compile_error!(
              entry.file,
              entry.line,
              "struct #{inspect(source)} is already registered"
            )
          end

          MapSet.put(seen, source)
      end
    end)
  end

  defp compile_error!(file, line, description) do
    raise CompileError, file: file, line: line, description: description
  end
end
