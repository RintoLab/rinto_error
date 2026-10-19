# 2. Define and use application errors

## Declare the application's error vocabulary

Put these modules under `lib/`. Each guide's Error definition is a standalone example; adapt your existing catalog instead of defining the same module twice.

```elixir
defmodule MyApp.Error do
  use RintoError

  catalog do
    entry :payment_timeout,
      as: :payment_unavailable,
      http_status: 503,
      doc: "The payment provider did not respond in time"

    entry :payment_declined, http_status: 422
    entry :reconciliation_failed
  end
end

defmodule MyApp.Payments do
  require MyApp.Error, as: Error

  def interpret_result({:ok, receipt}, _order_id), do: {:ok, receipt}

  def interpret_result({:error, :timeout}, order_id) do
    {:error,
     Error.new(
       kind: :payment_timeout,
       raw: :timeout,
       data: %{order_id: order_id},
       message: "Timed out while charging the order"
     )}
  end

  def interpret_result({:error, :declined}, order_id) do
    {:error, Error.new(kind: :payment_declined, data: %{order_id: order_id})}
  end
end
```

This example translates two known provider outcomes. Other outcomes remain an explicit application decision; the library does not invent a fallback kind.

## Return errors through ordinary control flow

```elixir
{:error, error} = MyApp.Payments.interpret_result({:error, :timeout}, "order-42")
error.kind # :payment_timeout
error.metadata.origin.module # MyApp.Payments
MyApp.Error.to_payload(error)
# %{kind: :payment_unavailable, data: %{order_id: "order-42"}, errors: []}
```

The caller can pattern-match on `{:ok, receipt}` or `{:error, error}` and decide whether to retry, respond, or propagate the failure. Returning an Error does not log or raise it.

`new/2` is a macro, so the calling module must `require MyApp.Error, as: Error`. It records the module, function, and line in `metadata.origin`, replacing a caller-supplied origin. This location is where the Error is constructed, not necessarily where a remote failure originally occurred.

## Choose the construction form

Each construction expression below returns `%MyApp.Error{}`. For comparison, `Map.take/2` shows the actual values of selected fields; other fields keep their defaults. Every `new` call also records its own `metadata.origin`.

```elixir
require MyApp.Error, as: Error

atom_error = Error.new(:payment_timeout)
Map.take(atom_error, [:kind, :raw, :message])
# %{kind: :payment_timeout, raw: :payment_timeout, message: nil}

message_error = Error.new(:payment_timeout, "Provider request timed out")
Map.take(message_error, [:kind, :raw, :message])
# %{kind: :payment_timeout, raw: :payment_timeout, message: "Provider request timed out"}

keyword_error = Error.new(kind: :payment_declined, data: %{order_id: "order-42"})
Map.take(keyword_error, [:kind, :raw, :data])
# %{kind: :payment_declined, raw: nil, data: %{order_id: "order-42"}}

map_error = Error.new(%{kind: :payment_timeout, raw: {:provider, :timeout}})
Map.take(map_error, [:kind, :raw])
# %{kind: :payment_timeout, raw: {:provider, :timeout}}

exception = Error.exception(kind: :payment_timeout)
Map.take(exception, [:kind, :raw, :metadata])
# %{kind: :payment_timeout, raw: nil, metadata: %{}}

literal = %Error{kind: :payment_timeout, raw: :timeout}
Map.take(literal, [:kind, :raw, :metadata])
# %{kind: :payment_timeout, raw: :timeout, metadata: %{}}
```

Atom input sets both `kind` and `raw`. Keyword and map inputs let you set them separately, with omitted `raw` defaulting to `nil`. The second argument to `new` can supply a diagnostic message.

`exception/1` returns an exception value without raising or recording an origin. Direct struct construction also omits the origin and bypasses catalog validation, so prefer `new` or `exception` in business code.

`raise MyApp.Error, ...` constructs and raises an exception, with no normal return value. This example uses `rescue` to show the captured fields:

```elixir
try do
  raise MyApp.Error, kind: :payment_timeout
rescue
  error in MyApp.Error -> Map.take(error, [:kind, :raw, :metadata])
end
# %{kind: :payment_timeout, raw: nil, metadata: %{}}
```

For an existing error, `raise error` raises that value, preserving its fields and origin. Expected business failures usually travel as `{:error, error}`. Registered structs can also be passed to `new` or `exception`; their builders determine the result, as shown in the Ecto and custom struct guides.

Inside the application, use both `kind` and `raw` for pattern matching: kind provides a shared business classification, while raw retains the original information needed to handle the failure.

```elixir
case {:error, map_error} do
  {:error, %MyApp.Error{kind: :payment_timeout, raw: {:provider, :timeout}}} ->
    :retry_provider

  {:error, %MyApp.Error{kind: :payment_declined}} ->
    :ask_for_another_payment_method

  other ->
    other
end
# :retry_provider
```

Internal logic matches the stored kind; `as:` only changes its name in the public payload.

## Describe error contracts with typespecs

The Error module generates types that your application can reference. Use `MyApp.Error.t()` for ordinary error returns, or `MyApp.Error.t(kind_type)` to constrain the kind, such as `Error.t(:payment_timeout)` or `Error.t(:payment_timeout | :payment_declined)`.

```elixir
defmodule MyApp.PaymentResult do
  require MyApp.Error, as: Error

  @spec from_timeout() :: {:error, Error.t(:payment_timeout)}
  def from_timeout do
    {:error, Error.new(kind: :payment_timeout, raw: :timeout)}
  end

  @spec kind(Error.t()) :: Error.known_kind()
  def kind(%Error{kind: kind}), do: kind

  @spec payload(Error.t()) :: Error.payload()
  def payload(error), do: Error.to_payload(error)
end
```

`Error.t(:payment_timeout)` constrains **kind** to `:payment_timeout`, while raw can hold any value, such as `:timeout` above. `Error.known_kind()` is the union of internal kinds declared in the catalog. `Error.t()` defaults to it and is equivalent to `Error.t(Error.known_kind())`; `Error.payload()` describes public output. These types are all generated in the host Error module, so `t()` can directly reference that module's `known_kind()`.

Typespecs communicate contracts to callers and Dialyzer; they add no runtime checks. An empty catalog has `known_kind()` equal to `none()`, so the default `Error.t()` has no possible values. Use `Error.t(atom())` explicitly to describe directly constructed errors with arbitrary atom kinds. Raw remains `term()`. The construction API validates the actual kind against the catalog.

## Centralize, inspect, and validate errors

The library is designed to bring the application's integrated business errors together in one Error module's catalog. Errors created through the construction API must use declared kinds, and external structs must be explicitly registered. This keeps the error vocabulary from being scattered across business modules.

That catalog provides one place to inspect the integrated errors, their public names, HTTP statuses, and descriptions: `kinds()` lists internal kinds, `kinds(:full)` shows complete declarations, and `kinds(:public)` groups them by public name.

Catalog declarations are validated at compile time. An undeclared literal kind passed directly to `new` fails compilation; dynamic inputs and kinds returned by source builders are validated during construction and raise `ArgumentError` when invalid. Output names do not automatically become constructable kinds.

This enforcement applies to errors integrated through the construction API. The library does not take over arbitrary Elixir exceptions or prevent multiple Error modules. Direct struct construction and map updates bypass validation, so consistently using the construction API maintains the centralized contract.

---

[中文](02_application_errors_cn.md) · [Previous: Design and error model](01_design_en.md) · [Next: Ecto validation errors](03_ecto_en.md)
