# 4. 接入自定义错误 struct

## 将 source 适配到应用 Error

自定义 source struct 表达它所在领域中的失败，最终的 `MyApp.Error` 则提供应用 catalog、公开名称和异常行为。Source 本身不必是 exception。

将以下定义放入应用的 `lib/` 目录。本例保留支付服务响应用于诊断，对外只提供是否适合重试的信息：

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

模块编译完成后，便可以使用这个 source：

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

## 理解两个接口约定

**构建（build）**：接收原始 struct，提取构造应用 Error 所需的属性，返回 map 或 keyword list。库负责生成最终 Error，并默认采用注册的 kind。上例将支付失败存入 `raw`，将诊断信息放入 message 和 metadata；也可以只保留业务处理需要的字段，不必保存整个输入。

**输出（to payload）**：第一个参数是用于协议分派的空 source struct，第二个参数是完整 Error，返回面向消费者的 `%{data: map(), errors: [term()]}`。上例从原始失败推导 `retryable`，不公开支付服务的请求 ID。Error 模块负责补充映射后的公开 kind。

构建与输出彼此分离：只有请求 payload 或 JSON 编码时才进行转换，而且每次都会执行，因此转换应保持无副作用。显式 `error.data` 优先于转换返回的数据；返回的详情替换原有 `error.errors`，不做递归转换。

`build/1` 和 `to_payload/2` 都是 `RintoError.Source` 必须实现的协议函数，在同一个 `defimpl` 中定义，调用时均通过协议分派。输出的第一个参数是 `struct(error.__source__)`，字段取默认值，并非原始输入，即使 raw 中保留了原始输入也是如此。转换所需的数据应从第二个参数 Error 读取，这样手动构造 Error、修改 raw、builder 丢弃原始输入等情况都保持一致。完整契约见 `RintoError.Source`。

## 显式注册，明确选择转换逻辑

存在 protocol 实现，并不意味着所有 Error 模块都接受该 struct；每个模块都必须通过 `entry_for` 注册其确切类型。构造时由输入 struct 的类型选择 builder，输出时由最终 `__source__` 选择 converter。仅改变 `raw` 不会切换 converter。

直接使用 atom `:payment_failed` 构造也合法，但 `__source__` 保持为 `nil`，采用普通 payload 输出。Builder 也可以显式返回 `__source__: nil` 来选择这种行为。

## 必要时通过手动属性构造

Map 和 keyword 输入会绕过 `build/1`。显式 selector 可以提供注册的默认 kind，并选择转换逻辑：

```elixir
manual = MyApp.Error.exception(
  __source__: MyApp.PaymentFailure,
  raw: failure,
  data: %{retryable: false}
)

MyApp.Error.to_payload(manual)
# %{kind: :payment_unavailable, data: %{retryable: false}, errors: []}
```

此时调用方必须提供本 converter 所需的 `raw` 值。只有 builder 才会填充的 metadata 不会自动出现。如果省略 `__source__`，`raw` 就只是普通诊断数据，不会触发 converter。

## 仅构造错误，不提供公开输出

即使 source 只用于异常和日志，两个协议函数也都必须实现。可以在实现中明确拒绝公开输出：

```elixir
@impl true
def to_payload(_source, _error), do: raise(ArgumentError, "public output is not supported")
```

构造不会调用转换函数。自定义 builder 和 converter 抛出的异常会原样传播。

将实现放在 `lib/` 中，确保它在协议 consolidation 之前编译。普通 Mix 构建会自动检查注册的协议实现是否提供两个函数；业务行为和公开输出仍需要测试。构建校验的具体边界见 `RintoError.Source`。

## 测试公开约定

将模块定义放入 `lib/` 后，可以将下面的测试保存为 `test/payment_failure_test.exs`：

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

还应覆盖应用支持的各种 source reason，以及依赖的显式 data 覆盖行为。测试重点是最终 Error 和公开 payload，而不是生成的实现模块名称。

---

[English](04_custom_structs_en.md) · [上一篇: Ecto 校验错误实践](03_ecto_cn.md) · [下一篇: 输出、日志与应用边界](05_output_and_logging_cn.md)
