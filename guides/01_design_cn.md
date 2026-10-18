# 1. 设计思想与错误模型

## 从应用自己的错误词汇开始

支付服务可能超时、返回供应商专有的失败响应，或者返回意料之外的值。应用需要稳定地表达这些失败，而不必让每个调用方都理解供应商的细节。

RintoError 允许应用定义自己的 Error 模块和 catalog。Catalog 声明应用接受的内部 kind；库负责构造、payload 转换和异常文本，应用负责赋予错误业务含义。

```elixir
defmodule MyApp.Error do
  use RintoError

  catalog do
    entry :payment_timeout, as: :payment_unavailable, http_status: 503
    entry :payment_rejected, as: :payment_unavailable, http_status: 502
    entry :reconciliation_failed
  end
end
```

业务代码仍然能够区分 `:payment_timeout` 和 `:payment_rejected`，客户端则统一看到 `:payment_unavailable`。内部的对账错误也可以不配置 HTTP 状态。

## 将三个决定分开

1. **发生了什么？** 存储在错误上的 `kind` 属于应用的 catalog。
2. **对外表达什么？** `as:` 可选地将内部 kind 映射成输出名称。Payload 仅包含 `kind`、`data` 和 `errors`。
3. **传输层如何响应？** `http_status:` 可选地提供 HTTP 状态。Payload 同样可以用于 RPC、队列等场景。

输出名称不会自动成为可构造的 kind。映射只执行一次，HTTP 状态始终按存储的内部 kind 查询。这样，应用可以细化内部分类，同时有意识地维护稳定的对外词汇。

## 给每个字段明确的职责

| 字段 | 用途 | 是否进入公开 payload |
| --- | --- | --- |
| `kind` | 内部错误分类 | 是，可经过名称映射 |
| `data` | 提供给消费者的结构化信息 | 是 |
| `errors` | 调用方或 source 定义的详情 | 是 |
| `raw` | 原始失败或诊断值 | 否 |
| `message` | 供人阅读的诊断文本 | 否 |
| `metadata` | 上下文，包括 `new` 记录的调用位置 | 否 |
| `__source__` | 选择已注册 source 的转换逻辑 | 否 |

这些是输出边界，并不代表自动脱敏。放入 `data`、`errors` 或由 source converter 返回的内容都可能公开。默认异常文本也会包含 `data`、`errors`、`metadata`，以及 kind 和 message。

## 在业务中构造，在边界处转换

对于已注册的 struct，`build/1` 将来源对象转换成 Error 的构造属性。之后，协议函数 `to_payload/2` 才将完整 Error 转换成公开数据和详情，第一个参数仅用于选择 source 类型。两个协议函数都必须实现；构造不会触发转换，仅用于异常和日志的 source 可以明确拒绝公开输出。

原始 struct 不必存放在 `raw` 中，保留哪些信息由 builder 决定。输出时由 `__source__` 选择 converter，不会根据 `raw` 的类型推断。

`errors` 列表不是自动遍历的业务 Error 树。每个 source 自己定义详情格式，库不会对详情递归转换，也不会应用 catalog 的名称映射。例如，Ecto 适配器输出的是带字段路径的详情。

## 由应用决定处理策略

RintoError 不预设业务 kind，不把所有失败都变成 HTTP 500，不主动记录日志，也不安装 Phoenix 错误处理器。预期内的失败可以通过 `{:error, error}` 返回；需要抛出异常时，同一个 Error 也可以用于 `raise`。应用负责这些策略，catalog 则让共享的错误词汇变得明确。

---

[English](01_design_en.md) · [下一篇: 定义与使用应用错误](02_application_errors_cn.md)
