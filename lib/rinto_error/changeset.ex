if Code.ensure_loaded?(Ecto.Changeset) do
  defmodule RintoError.Changeset do
    @moduledoc """
    Ecto field-error helpers, available when Ecto is present at library compilation.
    See the [Ecto guide](guides/03_ecto_en.md).

    The library supplies a standard `RintoError.Source` implementation for
    `Ecto.Changeset`. Register it with `entry_for` like any other source type.
    Construction retains the changeset in raw; payload conversion expands its
    field errors with `to_errors/1`.

    To provide your own implementation, set compile-time application configuration
    `config :rinto_error, exclude_default_sources: [Ecto.Changeset]` and recompile
    the dependency. These helpers remain available; see `RintoError.Source`.

    `add_error/4` and `to_errors/1` also work without an Error module or registration.
    Field classifications are independent of catalog kinds and output aliases.
    """

    @doc """
    Adds one field error to a changeset.

    The classification must be an atom other than `nil`, `true`, or `false`;
    invalid values raise `ArgumentError`.

    `message` is taken from opts, or `Atom.to_string(error)` when absent.
    The explicit classification overrides `:error` in opts. The remaining
    opts are passed to Ecto unchanged.
    """
    @spec add_error(Ecto.Changeset.t(), atom(), atom(), keyword()) ::
            Ecto.Changeset.t()
    def add_error(changeset, key, error, opts \\ [])

    def add_error(changeset, key, error, opts)
        when is_atom(error) and not is_nil(error) and not is_boolean(error) do
      {message, opts} = Keyword.pop_lazy(opts, :message, fn -> Atom.to_string(error) end)
      opts = Keyword.put(opts, :error, error)
      Ecto.Changeset.add_error(changeset, key, message, opts)
    end

    def add_error(_changeset, _key, error, _opts) do
      raise ArgumentError, "expected changeset error to be an atom, got: #{inspect(error)}"
    end

    @doc """
    Returns field payloads with kind, data, and empty errors; non-changesets return `[]`.

    Nested associations and embeds are flattened into paths containing string field
    names and zero-based list indices. Field messages remain in the original changeset.
    No business Error structs are constructed or catalog mappings applied.

    Type metadata uses `%{t: type}` for scalars, `%{t: :array | :map, of: type}`
    recursively for collections, and `%{t: :enum, values: [string]}` for enums in
    declaration order. Custom/parameterized types use their underlying Ecto type;
    semantic names such as decimal, uuid, and date remain distinct. Length validation
    keeps its counting type without inferring schema details. Cyclic types raise
    `ArgumentError`; absent type metadata stays absent.

    Inclusion/subset/exclusion candidates and number bounds use these conversions:

    * Range: `%{t: :range, first: integer, last: integer, step: integer}`, not enumerated.
    * Date.Range: the same shape with `t: :date_range` and ISO 8601 date bounds.
    * MapSet: sorted lists; lists and ordinary maps: recursively converted values.
    * Duration: ISO 8601 strings; Decimal: decimal strings.

    Other values are left to the encoder. Other metadata and application Error data
    are unchanged; original metadata remains in the source changeset.
    """
    @spec to_errors(term()) :: [%{kind: atom(), data: map(), errors: []}]
    def to_errors(%Ecto.Changeset{} = changeset) do
      changeset_errors(changeset, [])
    end

    def to_errors(_raw), do: []

    defp changeset_errors(changeset, path) do
      fields =
        Enum.map(changeset.errors, fn {field, {_message, opts}} ->
          {validation, data} = Keyword.pop(opts, :validation, opts[:constraint] || :invalid)
          {kind, data} = Keyword.pop(data, :error, validation)

          %{
            kind: kind,
            errors: [],
            data:
              data
              |> Map.new()
              |> describe_field_type()
              |> describe_validation_data(validation)
              |> Map.put(:path, path ++ [Atom.to_string(field)])
          }
        end)

      fields ++ related_errors(changeset, path)
    end

    defp describe_field_type(%{type: type} = data) do
      %{data | type: describe_type(type)}
    end

    defp describe_field_type(data), do: data

    defp describe_validation_data(%{enum: values} = data, validation)
         when validation in [:inclusion, :subset, :exclusion] do
      %{data | enum: describe_value(values)}
    end

    defp describe_validation_data(%{number: number} = data, :number) do
      %{data | number: describe_value(number)}
    end

    defp describe_validation_data(data, _validation), do: data

    defp describe_value(%Range{first: first, last: last, step: step}) do
      %{t: :range, first: first, last: last, step: step}
    end

    defp describe_value(%Date.Range{first: first, last: last, step: step}) do
      %{
        t: :date_range,
        first: Date.to_iso8601(first),
        last: Date.to_iso8601(last),
        step: step
      }
    end

    defp describe_value(%MapSet{} = values) do
      values |> Enum.sort() |> Enum.map(&describe_value/1)
    end

    defp describe_value(%Duration{} = value), do: Duration.to_iso8601(value)
    defp describe_value(%Decimal{} = value), do: Decimal.to_string(value)

    # Keep custom encoder implementations in control of their struct values.
    defp describe_value(%_{} = value), do: value

    defp describe_value(values) when is_list(values) do
      Enum.map(values, &describe_value/1)
    end

    defp describe_value(values) when is_map(values) do
      Map.new(values, fn {key, value} -> {key, describe_value(value)} end)
    end

    defp describe_value(value), do: value

    defp describe_type(type, seen \\ [])

    defp describe_type({container, type}, seen) when container in [:array, :map] do
      %{t: container, of: describe_type(type, seen)}
    end

    defp describe_type({:parameterized, {Ecto.Enum, _params}} = type, _seen) do
      values =
        %{value: type}
        |> Ecto.Enum.values(:value)
        |> Enum.map(&Atom.to_string/1)

      %{t: :enum, values: values}
    end

    defp describe_type({:parameterized, {_module, _params}} = type, seen) do
      describe_custom_type(type, seen)
    end

    defp describe_type(type, seen) when is_atom(type) do
      cond do
        Ecto.Type.base?(type) ->
          %{t: type}

        Code.ensure_loaded?(type) and function_exported?(type, :type, 0) ->
          describe_custom_type(type, seen)

        true ->
          %{t: type}
      end
    end

    defp describe_type(type, _seen), do: type

    defp describe_custom_type(type, seen) do
      if type in seen do
        raise ArgumentError, "cyclic Ecto type description: #{inspect(type)}"
      end

      type |> Ecto.Type.type() |> describe_type([type | seen])
    end

    defp related_errors(changeset, path) do
      (changeset.types || %{})
      |> Enum.sort_by(fn {field, _type} -> field end)
      |> Enum.flat_map(fn
        {field, {relation, %{cardinality: cardinality}}} when relation in [:assoc, :embed] ->
          value = Map.get(changeset.changes, field)

          related_errors(
            value,
            cardinality,
            path ++ [Atom.to_string(field)]
          )

        _ ->
          []
      end)
    end

    defp related_errors(nil, _cardinality, _path), do: []

    defp related_errors(changeset, :one, path) do
      changeset_errors(changeset, path)
    end

    defp related_errors(changesets, :many, path) do
      changesets
      |> Enum.reject(&(&1.action == :replace))
      |> Enum.with_index()
      |> Enum.flat_map(fn {changeset, index} ->
        changeset_errors(changeset, path ++ [index])
      end)
    end

    if Ecto.Changeset not in Application.compile_env(:rinto_error, :exclude_default_sources, []) do
      defimpl RintoError.Source, for: Ecto.Changeset do
        @impl true
        def build(changeset), do: %{raw: changeset}

        @impl true
        def to_payload(_source, %{raw: raw}) do
          %{data: %{}, errors: RintoError.Changeset.to_errors(raw)}
        end
      end
    end
  end
end
