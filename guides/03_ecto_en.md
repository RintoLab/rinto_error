# 3. Ecto validation errors

In Elixir applications using Ecto, database operations often return `{:error, %Ecto.Changeset{}}` when validation fails. This guide shows how to integrate that result into the application's shared Error while retaining field-level details for callers and frontends.

## Register changesets explicitly

This guide assumes the application already uses Ecto. RintoError's Ecto support is optional; its standard `RintoError.Source` implementation is available when Ecto is present at library compilation and has not been excluded by configuration.

Register Ecto changesets explicitly in your Error module, choosing the business kind and public name:

```elixir
defmodule MyApp.Error do
  use RintoError

  catalog do
    entry_for Ecto.Changeset, :checkout_invalid,
      as: :invalid_input,
      http_status: 422
  end
end
```

The built-in handler stores the changeset in `raw` during construction and expands field errors when output is requested:

```elixir
require MyApp.Error, as: Error

changeset =
  Ecto.Changeset.change({%{}, %{email: :string}})
  |> Ecto.Changeset.validate_required([:email])

error = Error.new(changeset)
Error.to_payload(error)
# %{
#   kind: :invalid_input,
#   data: %{},
#   errors: [%{kind: :required, data: %{path: ["email"]}, errors: []}]
# }
Error.http_status(error) # 422
```

In a repository workflow, the changeset in `{:error, changeset}` can be passed to `MyApp.Error.new/1` in the same way. Decide in your application whether to wrap it at the context boundary or return it to another caller unchanged.

## Separate the business failure from field details

The outer `:checkout_invalid` belongs to the catalog and maps to `:invalid_input`. A field classification such as `:required`, `:cast`, or `:length` does not need a catalog entry and is never renamed by that catalog.

Nested associations and embeds produce field paths. For example, `["items", 0, "name"]` identifies `name` on the first item; list indices are zero-based. The adapter returns a flat list of field payloads with `errors: []`, rather than nested application Error structs.

The original Ecto message string stays in the raw changeset. Public details carry the classification and structured metadata, allowing consumers to choose their own wording.

## Add a domain-specific field classification

```elixir
changeset =
  Ecto.Changeset.change({%{}, %{coupon: :string}})
  |> RintoError.Changeset.add_error(:coupon, :expired, message: "Coupon expired")

RintoError.Changeset.to_errors(changeset)
# [%{kind: :expired, data: %{path: ["coupon"]}, errors: []}]
```

The classification must be an atom other than `nil`, `true`, or `false`. `add_error/4` and `to_errors/1` can also be used without an Error module or source registration.

## Read structured validation metadata

This data is suitable for frontend integration: use `data.path` to locate a form field, its `kind` to select a message, and type and validation parameters to provide guidance or localized text without parsing backend error strings. For example, `kind: :required` with the path `["email"]` lets the frontend show a required-field message beside the email input.

When field metadata contains a type, `data.type` uses a `t` discriminator:

| Meaning | Example |
| --- | --- |
| Integer | `%{t: :integer}` |
| UUID | `%{t: :uuid}` |
| Array of integers | `%{t: :array, of: %{t: :integer}}` |
| Enum | `%{t: :enum, values: ["reader", "editor"]}` |

Interpret type information with the field kind: a cast error describes the expected type; a length error describes what is counted. A list-length error does not infer element types. Fields without type metadata do not gain a type key.

The adapter also describes supported validation values, such as ranges in inclusion checks and decimal bounds in number checks. See `RintoError.Changeset` for the full contract. This is not general JSON normalization of all application data; original metadata remains in the raw changeset.

## Replace the supplied protocol implementation

Changeset is an example of the same extension mechanism used by custom structs: a `defimpl RintoError.Source` implementing `build/1` and `to_payload/2`. Construction and output both use protocol dispatch; there is no special Changeset routing in the Error module. Registration alone enables the supplied behavior.

If you prefer different behavior, exclude the supplied implementation at library compilation and define your own in `lib/`:

```elixir
# config/config.exs — before compiling :rinto_error
import Config
config :rinto_error, exclude_default_sources: [Ecto.Changeset]
```

```elixir
# lib/my_app/changeset_source.ex
defimpl RintoError.Source, for: Ecto.Changeset do
  @impl true
  def build(changeset), do: %{raw: changeset}

  @impl true
  def to_payload(_source, error) do
    %{
      data: %{form: "checkout"},
      errors: RintoError.Changeset.to_errors(error.raw)
    }
  end
end

defmodule MyApp.CheckoutError do
  use RintoError

  catalog do
    entry_for Ecto.Changeset, :checkout_invalid, as: :invalid_input, http_status: 422
  end
end
```

After changing the configuration for an already compiled dependency, run:

```sh
mix deps.compile rinto_error --force
mix compile
```

This is compile-time application configuration, not a `use RintoError` option or a runtime switch. Exclusion prevents the library from defining the implementation; it does not disable Ecto or remove `RintoError.Changeset` helpers. Without a replacement, registering Ecto fails build validation. The replacement applies to all Error modules that register `Ecto.Changeset`. Define exactly one implementation per source type before protocol consolidation. Use a wrapper struct with its own implementation when different behaviors must coexist.

`to_payload/2` receives an empty Changeset as its first argument for type dispatch, not the original input. Read the current Error from its second argument. Explicit Error data takes precedence over converter data, so an existing `error.data.form` wins over `"checkout"`. Returned field details replace stored `error.errors`. The application-facing output API remains `MyApp.CheckoutError.to_payload(error)`.

---

[中文](03_ecto_cn.md) · [Previous: Define and use application errors](02_application_errors_en.md) · [Next: Integrate custom error structs](04_custom_structs_en.md)
