# crypto-bar

原生 macOS 菜单栏小应用，显示所选 OKX 现货交易对的最新价格，**每 30 秒刷新一次**。

菜单栏示例：`BTC $81,461.70` 或 `ETH $2,402.94`。默认 BTC/USDT，可搜索并切换 OKX 当前支持的 **USDT 现货交易对**。价格前的 `$` 是显示样式，实际计价单位为 USDT，菜单和悬停提示会注明。

## 使用

1. 将 `BTC Price.app` 拖到“应用程序”，或直接双击运行。无需注册或 API Key。
2. 点击菜单栏价格，选择“选择交易对…”。窗口会从 OKX 获取当前可交易的现货列表。
3. 输入币种或交易对，例如 `ETH`、`SOL`、`ETH/USDT`。选择结果后点击“使用此交易对”，也可双击或按回车确认。
   列表提供“最新价格”一列，打开时立即获取报价，之后每 30 秒批量刷新；搜索过程中价格也会自动更新。
4. 切换后立即刷新价格，之后每 30 秒刷新；会记住选择，下次启动自动恢复。
5. 可在搜索窗口刷新远程列表。加载失败时可以重试；搜索结果来自 OKX 实际目录，无硬编码币种列表。
6. 点击价格菜单可手动刷新或退出。首次显示在菜单栏右侧，可按住 Command 拖动调整，位置会被记住。

要求 macOS 13 或更新版本，支持 Apple 芯片和 Intel。没有 Dock 图标或常驻窗口；选择交易对时才打开搜索窗口。

本应用在本机编译并使用临时签名，未使用 Apple Developer ID 公证。如 macOS 拦截，请在 Finder 中按住 Control 点击应用并选择“打开”。

## 刷新与异常处理

- 启动、切换交易对后立即请求；之后每 30 秒刷新，Mac 唤醒时立即尝试刷新。
- 显示 OKX 现货 ticker 的 `last` 最新成交价；按交易对价格精度显示，小额币种不会被固定两位小数舍入成零。
- 菜单栏加载中显示 `BTC $…`（使用所选币种）；未取得价格且请求失败时显示 `BTC $—`。请求失败会保留当前交易对的上次价格并灰显，菜单中可查看原因。
- 搜索列表价格通过一次批量请求获取。请求失败时保留上次价格并灰显，窗口关闭后停止列表报价刷新。
- 切换交易对时清空旧价格并取消旧请求，避免把旧币种价格显示到新币种上。
- 行情超过 3 分钟会灰显；旧时间戳响应不会覆盖新行情。
- HTTP 429 / 接口限流时遵循 `Retry-After` 并自动延迟重试，正常后恢复 30 秒刷新。
- 请求有超时且不会重叠；休眠期间不请求，不阻止 Mac 正常休眠。

## 公开接口

```
GET https://www.okx.com/api/v5/public/instruments?instType=SPOT
GET https://www.okx.com/api/v5/market/ticker?instId=<所选交易对>
GET https://www.okx.com/api/v5/market/tickers?instType=SPOT
```

以上接口均无需认证。目录只显示 `instType=SPOT`、`state=live`、`quoteCcy=USDT` 的产品。

OKX 没有现货 symbol 模糊查询接口；搜索窗口每次打开时从远程获取当前产品目录，再即时匹配输入。

官方文档：[交易产品目录](https://www.okx.com/docs-v5/en/#public-data-rest-api-get-instruments)、[现货 ticker](https://www.okx.com/docs-v5/en/#order-book-trading-market-data-get-ticker)。

## 从源码构建

需要 macOS 和 Xcode Command Line Tools，无第三方依赖：

```sh
chmod +x build.sh verify.sh
./build.sh
open "dist/BTC Price.app"
```

同时编译 arm64 / x86_64 并合并为 Universal 应用。可用 `./build.sh /绝对路径/输出目录` 指定输出目录。

验证核心行为：

```sh
./verify.sh
```

安装完整 Xcode 后也可运行标准 XCTest：

```sh
swift test
```

`Sources/BTCPriceCore` 包含公开行情请求、交易对目录、搜索匹配和价格格式；`Sources/BTCPrice` 是原生 AppKit 菜单栏及搜索窗口。
