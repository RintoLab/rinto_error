# 2. 定义与使用应用错误

## 声明应用的错误词汇

将下面的模块放在 `lib/` 中。各篇 guide 的 Error 定义都是独立示例；实际接入时应调整已有 catalog，不要重复定义同一个模块。

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

示例转换两种已知的支付服务结果。其他结果如何处理仍由应用明确决定，库不会凭空补出一个兜底 kind。

## 通过普通控制流返回错误

```elixir
{:error, error} = MyApp.Payments.interpret_result({:error, :timeout}, "order-42")
error.kind # :payment_timeout
error.metadata.origin.module # MyApp.Payments
MyApp.Error.to_payload(error)
# %{kind: :payment_unavailable, data: %{order_id: "order-42"}, errors: []}
```

调用方可以匹配 `{:ok, receipt}` 或 `{:error, error}`，决定重试、响应或继续传递失败。返回 Error 不会自动打印日志或抛出异常。

`new/2` 是宏，调用模块需要 `require MyApp.Error, as: Error`。它将模块、函数和行号写入 `metadata.origin`，替换调用方传入的 origin。这里记录的是构造 Error 的位置，不一定是远端失败最初发生的位置。

## 选择合适的构造方式

下面每个构造表达式都返回 `%MyApp.Error{}`。为便于比较，使用 `Map.take/2` 展示关键字段的实际结果；其他字段使用默认值。所有 `new` 调用还会记录各自的 `metadata.origin`。

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

Atom 输入同时设置 `kind` 和 `raw`；keyword 和 map 输入则允许分别设置它们，省略的 `raw` 为 `nil`。`new` 的第二个参数可以设置诊断消息。

`exception/1` 返回异常值，不会主动抛出，也不记录 origin。直接 struct 构造同样不记录 origin，并且绕过 catalog 校验，因此业务代码优先使用 `new` 或 `exception`。

`raise MyApp.Error, ...` 会构造并抛出异常，没有普通返回值。下面通过 `rescue` 展示捕获到的字段：

```elixir
try do
  raise MyApp.Error, kind: :payment_timeout
rescue
  error in MyApp.Error -> Map.take(error, [:kind, :raw, :metadata])
end
# %{kind: :payment_timeout, raw: nil, metadata: %{}}
```

已有错误时，`raise error` 直接抛出该错误，保留已有字段和 origin。预期业务失败通常通过 `{:error, error}` 返回。注册的 struct 也可以传给 `new` 或 `exception`，结果由 builder 决定，见后面的 Ecto 和自定义 struct guide。

在程序内部，可以充分利用 `kind` 和 `raw` 进行模式匹配：kind 表达统一的业务分类，raw 保留处理失败所需的原始信息。

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

内部逻辑按存储的 kind 匹配；`as:` 只影响对外 payload 的名称。

## 用 typespec 表达错误约定

Error 模块会生成可直接引用的类型。业务函数的错误返回通常使用 `MyApp.Error.t()`；明确知道错误类别时，可以用 `MyApp.Error.t(kind_type)` 约束 kind，例如 `Error.t(:payment_timeout)` 或 `Error.t(:payment_timeout | :payment_declined)`。

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

`Error.t(:payment_timeout)` 将 **kind** 约束为 `:payment_timeout`，raw 仍可为任意值，上例中为 `:timeout`。`Error.known_kind()` 是 catalog 声明的内部 kind 联合类型，`Error.t()` 默认使用它，等价于 `Error.t(Error.known_kind())`；`Error.payload()` 描述公开输出。这些类型都生成在宿主 Error 模块中，因此 `t()` 可以直接引用同一模块的 `known_kind()`。

Typespec 为调用方和 Dialyzer 提供约定，不会增加运行时检查。空 catalog 的 `known_kind()` 为 `none()`，因此默认 `Error.t()` 没有可取值；需要描述任意 atom kind 的直接构造对象时，可以显式使用 `Error.t(atom())`。raw 的类型仍为 `term()`；实际 kind 的合法性由构造 API 按 catalog 验证。

## 将错误集中声明、管理和验证

这个库的设计目标，是让应用将接入的业务错误统一收敛到一个 Error 模块的 catalog 中。通过构造 API 创建的错误必须使用已声明的 kind，外部 struct 也必须显式注册，避免错误词汇散落在各个业务模块里。

这样，一处就能查看系统接入了哪些错误、如何对外命名，以及对应的 HTTP 状态和说明：`kinds()` 列出内部 kind，`kinds(:full)` 展示完整声明，`kinds(:public)` 按公开名称分组。

Catalog 声明会在编译时验证。直接传给 `new` 的未声明字面量 kind 会导致编译失败；动态输入和 source builder 返回的 kind 在构造时验证，不合法时抛出 `ArgumentError`。输出名称不会自动成为可构造的 kind。

这种强制约束作用于使用构造 API 接入的错误；库不会接管任意 Elixir 异常，也不阻止应用定义多个 Error 模块。直接 struct 构造或 map 更新会绕过校验，因此统一使用构造 API 才能持续维护这份集中声明。

---

[English](02_application_errors_en.md) · [上一篇: 设计思想与错误模型](01_design_cn.md) · [下一篇: Ecto 校验错误实践](03_ecto_cn.md)
