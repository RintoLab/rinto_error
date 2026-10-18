# 4. Integrate custom error structs

## Adapt a source to your application's Error

A custom source struct represents a failure in its own domain. The final `MyApp.Error` provides the application's catalog, public name, and exception behavior. The source itself does not need to be an exception.

Put these definitions in your application's `lib/` directory. This example keeps the provider response for diagnostics and publishes only whether retrying is appropriate:

```elixir
defmodule MyApp.PaymentFailure do
  defstruct [:reason, :provider_request_id]
end

defimpl RintoError.Source, for: MyApp.PaymentFailure do

  @impl true
  def build(failure) do
    %{
      raw: failure,
      message: "Payment provider failed",
      metadata: %{provider_request_id: failure.provider_request_id}
    }
  end

  @impl true
  def to_payload(_source, error) do
    %{
      data: %{retryable: error.raw.reason == :timeout},
      errors: []
    }
  end
end

defmodule MyApp.Error do
  use RintoError

  catalog do
    entry_for MyApp.PaymentFailure, :payment_failed,
      as: :payment_unavailable,
      http_status: 502
  end
end
```

Use the source after the modules have compiled:

```elixir
require MyApp.Error, as: Error

failure = %MyApp.PaymentFailure{reason: :timeout, provider_request_id: "req-42"}
error = Error.new(failure)

error.kind # :payment_failed
error.__source__ # MyApp.PaymentFailure
error.raw == failure # true
Error.to_payload(error)
# %{kind: :payment_unavailable, data: %{retryable: true}, errors: []}
```

## Understand the two contracts

**Build**: receive the original struct and extract the attributes needed to construct the application Error, returning a map or keyword list. The library creates the final Error and defaults to the registered kind. The example stores the payment failure in `raw` and diagnostics in message and metadata. You can instead retain only what business handling needs; keeping the whole input is optional.

**To payload**: receive an empty source struct as the first argument for protocol dispatch and the complete Error as the second argument and return consumer-facing `%{data: map(), errors: [term()]}`. The example derives `retryable` from the original failure without publishing the provider request ID. The Error module supplies the mapped public kind.

Construction and output are separate: conversion only runs when a payload or JSON encoding is requested, and runs each time, so keep it free of side effects. Explicit `error.data` wins over converter data; returned details replace stored `error.errors` without recursive conversion.

Both `build/1` and `to_payload/2` are required functions of `RintoError.Source`, implemented together in a `defimpl`. Both use protocol dispatch. The output selector is `struct(error.__source__)`, with default field values; it is not the original input, even when raw contains that input. Read conversion data from the second argument. This keeps manual Errors, changed raw values, and builders that discard the original input working consistently. See `RintoError.Source` for the complete contract.

## Registration and selection are explicit

A protocol implementation alone does not authorize a struct in every Error module: each module must register its exact type through `entry_for`. At construction, the input struct type selects the builder. At output, the resulting `__source__` selects the converter. Changing only `raw` does not switch the converter.

Direct atom construction with `:payment_failed` is also valid, but leaves `__source__` as `nil` and uses ordinary payload output. A builder can explicitly return `__source__: nil` for the same behavior.

## Construct from manual attributes when necessary

Map and keyword input bypass `build/1`. An explicit selector supplies the registered default kind and selects conversion:

```elixir
manual = MyApp.Error.exception(
  __source__: MyApp.PaymentFailure,
  raw: failure,
  data: %{retryable: false}
)

MyApp.Error.to_payload(manual)
# %{kind: :payment_unavailable, data: %{retryable: false}, errors: []}
```

Here the caller must provide the `raw` value expected by this converter. Builder-only metadata is not automatically populated. If `__source__` were omitted, `raw` would remain ordinary diagnostic data and the converter would not run.

## Support construction without public output

Both functions are required, even for sources used solely for exceptions and logs. Such a source can explicitly reject public output in its implementation:

```elixir
@impl true
def to_payload(_source, _error), do: raise(ArgumentError, "public output is not supported")
```

Construction never invokes conversion. Custom builder and converter exceptions propagate unchanged.

Put implementations in `lib/` so they compile before protocol consolidation. Ordinary Mix builds automatically check that registered protocol implementations provide both functions; business behavior and public output still need tests. See `RintoError.Source` for the scope of build validation.

## Test the public contract

With the definitions in `lib/`, place this test in `test/payment_failure_test.exs`:

```elixir
defmodule MyApp.PaymentFailureTest do
  use ExUnit.Case, async: true
  require MyApp.Error, as: Error

  test "keeps provider diagnostics out of the payload" do
    failure = %MyApp.PaymentFailure{reason: :timeout, provider_request_id: "req-42"}
    error = Error.new(failure)

    assert error.kind == :payment_failed
    assert error.raw == failure
    assert error.metadata.provider_request_id == "req-42"
    assert error.metadata.origin.module == __MODULE__
    assert Error.to_payload(error) == %{
             kind: :payment_unavailable,
             data: %{retryable: true},
             errors: []
           }
  end
end
```

Also cover each supported source reason and any explicit-data overrides your application relies on. Prefer assertions about the resulting Error and public payload over assertions about the implementation module's generated name.

---

[中文](04_custom_structs_cn.md) · [Previous: Ecto validation errors](03_ecto_en.md) · [Next: Output, logging, and application boundaries](05_output_and_logging_en.md)
