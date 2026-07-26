# TmuxGUI

把 tmux 的 session / window / pane 映射到原生 macOS 界面上的实验。底层完全是真正的
tmux——从任何普通终端 `tmux attach` 上去，看到的还是原来的 tmux，进程照跑。

目前是**可行性验证阶段**：一个窗口显示一个 tmux 窗格，能看能打字能改大小，
并测量控制模式的吞吐和卡顿。

## 它是怎么工作的

tmux 自带一个叫**控制模式**的开关（`tmux -C`）。打开后 tmux 不再自己画界面，
改成用一套纯文本消息跟外部程序对话。渲染交给 [libghostty](https://ghostty.org)——
通过 [`libghostty-spm`](https://github.com/Lakr233/libghostty-spm) 这个 Swift Package
使用，它的 `.inMemory` 后端不需要 pty，只要你喂字节给它。

于是只有三根线：

| 方向 | tmux 那边 | 本 app 这边 |
|---|---|---|
| 输出 | `%output %42 <字节>` | `InMemoryTerminalSession.receive(data)` |
| 输入 | `send-keys -t %42 -H <十六进制>` | `write` 回调 |
| 尺寸 | `refresh-client -C 宽x高` | `resize` 回调 |

代码在 [`TmuxGUI/Tmux/`](TmuxGUI/Tmux/)：

- `TmuxOctal.swift` — 字节层编解码（tmux 把控制字符和反斜杠转成 `\ooo` 八进制，
  但 UTF-8 多字节原样透传，所以不能用 `String` 解码）
- `TmuxNotification.swift` — 控制模式消息解析
- `TmuxControlClient.swift` — 子进程 + 读写循环 + 命令应答配对
- `TmuxPaneSession.swift` — 把一个窗格接到一个 libghostty 表面上
- `TmuxMetrics.swift` — 吞吐与卡顿测量

## 构建

需要 Xcode 和 tmux。

```sh
git clone --recurse-submodules <repo> && cd tmux-gui
xcodebuild -project TmuxGUI.xcodeproj -scheme TmuxGUI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

已经 clone 过了：`git submodule update --init --recursive`。

**app sandbox 必须关着。** 沙盒里既起不了 tmux 子进程，也读不到
`/private/tmp/tmux-<uid>/` 下的 socket。示例工程默认是开着沙盒的，本工程已改成关闭。

## 运行

默认连上 tmux 报的第一个 session。指定别的：

```sh
TMUX_GUI_SESSION=dev open -a TmuxGUI     # 或直接跑 .app 里的可执行文件
```

窗口标题显示当前跟着哪个窗格，副标题是实时吞吐和卡顿 p99。

## 吞吐压测结果（2026-07-26 实测）

菜单「测量 → 跑一轮吞吐压测」做一次 A/B：先测一个每 50ms 输出一个字节的心跳窗格，
再在**同一个 session** 里开另一个窗格全速刷屏，看心跳被拖慢多少。控制模式把整个
session 所有窗格的输出挤在一根管子里传，所以这是这套设计唯一可能致命的地方。

| | 到达间隔中位 | p99 | 最差 | 刷屏窗格产出 |
|---|---|---|---|---|
| A · 只有心跳 | 57 ms | 59 ms | 59 ms | — |
| B · 心跳 + 全速刷屏 | 57 ms | 58 ms | 59 ms | 170 MB / 8 秒（**19.4 MB/s**） |

**没有劣化。** 基线是 57ms 而不是 50ms，因为 `printf .; sleep 0.05` 这个循环本身有约 7ms
的 shell 开销——真正的心跳周期就是 57ms，而它在 19.4 MB/s 的干扰下**一点没变**。

测的是**字节到达 app 的时刻**，不含渲染。另外只渲染了一个窗格，本地 socket，
tmux 3.6a / Apple Silicon。跨 ssh 或同时渲染很多窗格的情况还没测。

## 已知边界

- 只显示**一个**窗格——当前窗口的活跃窗格。在 tmux 里切窗口或切窗格，本 app 会跟着走。
- 如果那个 tmux 窗口有多个窗格，画面会对不齐：本 app 按整个视图大小去设 `refresh-client -C`，
  而 tmux 会把这个尺寸分给窗口里所有窗格。这正是「tmux 窗口尺寸和 GUI 分屏对不上」
  那个固有问题，后面要专门设计。
- 初始画面用 `capture-pane` 抓一次快照。tmux 在客户端接入时不会重放历史，
  没有这一步窗格是空白的。
- 标题栏那个「卡顿 p99」只在窗格持续输出时才有意义。窗格闲着的时候，两次输出之间
  天然隔着好几秒，会显示成很大的数值——那不是卡，是没东西可发。真正的判断看
  菜单里的 A/B 压测，那里的心跳是恒定的，偏离多少一目了然。
- 压测结果用 `NSAlert.runModal()` 弹出，模态运行循环期间投递到主队列的回调会排队，
  所以对话框开着的时候标题不刷新。改成非模态窗口即可。
- `capture-pane` 的回复经过 `String` 解码，遇到非法 UTF-8 会被替换成 U+FFFD。
  只影响初始快照那一次；实时的 `%output` 走的是字节路径，不受影响。
