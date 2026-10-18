defmodule RintoError.Fixture.PlainSource do
  @moduledoc false
  defstruct [:kind, :raw]
end

defimpl RintoError.Source, for: RintoError.Fixture.PlainSource do
  def build(source), do: %{raw: source}
  def to_payload(_source, _error), do: raise(ArgumentError, "public output is not supported")
end

defmodule RintoError.Fixture.InternalSource do
  @moduledoc false
  defstruct [:reason]
end

defimpl RintoError.Source, for: RintoError.Fixture.InternalSource do
  @impl true
  def build(source), do: %{raw: source, message: "internal diagnostics"}

  @impl true
  def to_payload(_source, _error), do: raise(ArgumentError, "public output is not supported")
end

defmodule RintoError.Fixture.InternalSourceError do
  @moduledoc false
  use RintoError

  catalog do
    entry_for RintoError.Fixture.InternalSource, :internal_source
  end
end

defmodule RintoError.Fixture.AttributeSource do
  @moduledoc false
  defstruct raw: :private_raw,
            message: "private message",
            data: %{},
            errors: [],
            metadata: %{}
end

defimpl RintoError.Source, for: RintoError.Fixture.AttributeSource do
  @impl true
  def build(source), do: Map.from_struct(source)

  @impl true
  def to_payload(_source, error), do: %{data: error.data, errors: error.errors}
end

defmodule RintoError.Fixture.ExtendedPayloadSource do
  @moduledoc false
  defstruct [:value, data: %{}, errors: []]
end

defimpl RintoError.Source, for: RintoError.Fixture.ExtendedPayloadSource do
  @impl true
  def build(source), do: %{raw: source, data: source.data, errors: source.errors}

  @impl true
  def to_payload(_source, %{raw: %{value: {:raise, exception}}}), do: raise(exception)

  def to_payload(_source, error) do
    %{data: Map.put(error.data, :derived, error.raw.value), errors: error.errors}
  end
end

defmodule RintoError.Fixture.AttributeSourceError do
  @moduledoc false
  use RintoError

  catalog do
    entry_for RintoError.Fixture.AttributeSource, :attribute_source, as: :public_source
    entry_for RintoError.Fixture.ExtendedPayloadSource, :extended_source, as: :public_extended
    entry :public_source, as: :remapped_source
    entry :ordinary, as: :public_ordinary
    entry :timeout, as: :public_timeout
    entry :public_timeout, as: :remapped_timeout
  end
end

defmodule RintoError.Fixture.DetailedSource do
  @moduledoc false
  defstruct [:reason, details: []]
end

defimpl RintoError.Source, for: RintoError.Fixture.DetailedSource do
  @impl true
  def build(source), do: %{raw: source}

  @impl true
  def to_payload(_source, %{raw: %{reason: :raise}}), do: raise("expanded at output time")

  def to_payload(_source, %{raw: source, __struct__: error_module}) do
    %{
      data: %{reason: source.reason, context: error_module},
      errors: source.details
    }
  end
end

defmodule RintoError.Fixture.SourceError do
  @moduledoc false
  use RintoError
  alias RintoError.Fixture.{PlainSource, DetailedSource}

  catalog do
    entry :ordinary
    entry_for PlainSource, :plain
    entry :timeout, as: :public_timeout

    entry_for DetailedSource, :detailed,
      as: :public_source,
      http_status: 502,
      doc: "Source detail"

    entry :public_timeout, as: :remapped_timeout
  end
end

defmodule RintoError.Fixture.OtherSourceError do
  @moduledoc false
  use RintoError

  catalog do
    entry_for RintoError.Fixture.DetailedSource, :different, http_status: 400

    entry :timeout, as: :other_timeout
  end
end

defmodule RintoError.Fixture.CheckoutChangeset do
  @moduledoc false
  @enforce_keys [:changeset]
  defstruct [:changeset]
end

defimpl RintoError.Source, for: RintoError.Fixture.CheckoutChangeset do
  @impl true
  def build(%{changeset: changeset}) do
    RintoError.Source.build(changeset)
    |> Map.merge(%{raw: :custom_ecto, message: "custom build", metadata: %{changeset: changeset}})
  end

  @impl true
  def to_payload(_source, %{__struct__: error_module} = error) do
    %{
      data: %{custom: true, context: error_module},
      errors: RintoError.Changeset.to_errors(error.metadata.changeset)
    }
  end
end

defmodule RintoError.Fixture.CustomChangesetError do
  @moduledoc false
  use RintoError

  catalog do
    entry_for RintoError.Fixture.CheckoutChangeset, :validation_error,
      as: :invalid_input,
      http_status: 422
  end
end

defmodule RintoError.Fixture.StoredSource do
  defstruct [:value, :kind]
end

defimpl RintoError.Source, for: RintoError.Fixture.StoredSource do
  @impl true
  def build(%{value: :fail_build}), do: raise("build failed")
  def build(%{value: :defaults}), do: %{}
  def build(%{value: {:attrs, attrs}}), do: attrs

  def build(source) do
    %{
      raw: :opaque,
      message: "built",
      metadata: %{source_value: source.value}
    }
  end

  @impl true
  def to_payload(
        %RintoError.Fixture.StoredSource{value: nil, kind: nil},
        %{metadata: %{source_value: value}, message: message}
      ) do
    %{data: %{value: value, description: message}, errors: []}
  end
end

defmodule RintoError.Fixture.StoredSourceError do
  use RintoError

  catalog do
    entry_for RintoError.Fixture.StoredSource, :stored, as: :public_stored

    entry_for Ecto.Changeset, :invalid
    entry :ordinary
  end
end

defmodule RintoError.Fixture.CustomMessageError do
  use RintoError

  catalog do
    entry :broken
  end

  @impl true
  def message(%{message: "default"} = error), do: super(error)
  def message(error), do: "custom #{error.kind}: #{error.message}"
end
