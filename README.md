# TmuxGUI

把 tmux 的 session / window / pane 映射到原生 macOS 界面上。底层完全是真正的
tmux——从任何普通终端 `tmux attach` 上去，看到的还是原来的 tmux，进程照跑。

```
tmux session  →  左侧竖排的一级 tab
tmux window   →  顶部横排的二级 tab
tmux pane     →  内容区的分屏
```

界面不持有任何状态。点击、换序、改名、拆分全部翻译成 tmux 命令，等 tmux 回报了
才生效——所以在别的终端里敲 `prefix + c`，这边照样会多出一个 tab，走的是同一条路。

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

## 功能

- **三层映射**，双向同步。在 tmux 里做的任何改动都会反映到界面上，反之亦然。
- **分屏按 tmux 的字符网格定位**。位于第 (x, y) 格、大小 columns × rows 的窗格，
  就摆在 (x·单元宽, y·单元高)。两边共用一张网格，分割线不会对不齐。
- **拖分割线改布局** → `resize-pane`，tmux 跟着 GUI 走。
- **拖 tab 换顺序** → `move-window`；**双击改名** → `rename-window`。
- **关 tab 只是隐藏，绝不杀东西。** 窗口里可能正跑着 AI Agent。要杀有单独的右键
  菜单项，措辞明确并带确认。隐藏的窗口在 tab 栏右侧一键找回。
- **往上滚看历史**。首次显示窗格时把 tmux 的 scrollback 灌进来。
- **快捷键**：⌘T 新建窗口、⌘W 隐藏标签、⌘1-9 切窗口、⌘⇧[ ] 前后切；
  ⌃⌘1-9 切 session、⌃⌘[ ] 前后切、⌘⇧N 新建 session；
  Shift+PageUp/PageDown/Home/End 翻历史。这些和你自己的 tmux `prefix` 绑定并存。
- **「有新输出」提示点**用的是 tmux 自己的 activity flag，含义和状态栏里的 `#` 一致。

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

测的是**字节到达 app 的时刻**，不含渲染。本地 socket，tmux 3.6a / Apple Silicon。
跨 ssh 的情况还没测。

## 代码结构

`TmuxGUI/Tmux/` —— 跟界面无关的那一半：

- `TmuxOctal.swift` — 字节层编解码。tmux 把控制字符和反斜杠转成 `\ooo` 八进制，
  但 UTF-8 多字节原样透传，所以解码必须走字节；经过 `String` 会把非法 UTF-8 片段
  替换成 U+FFFD 而损坏数据流。
- `TmuxNotification.swift` — 控制模式消息解析。
- `TmuxLayout.swift` — 窗口布局字符串解析（`{}` 左右排、`[]` 上下排）。
- `TmuxControlClient.swift` — 子进程 + 读写循环 + 命令应答配对。
- `TmuxOutputRouter.swift` — 线程安全的 pane id → surface 映射，`%output` 直达不经主线程。
- `TmuxSessionConnection.swift` — 一个 session 一条连接，维护窗口列表和布局。
- `TmuxServer.swift` — 所有 session 的连接。
- `TmuxMetrics.swift` — 吞吐与卡顿测量。

`TmuxGUI/UI/` —— 界面那一半。

`Tools/LayoutCheck/` —— 布局解析器的交叉验证：遍历活着的 tmux 服务器上每一个窗口，
把解析出的每个窗格几何和 tmux 自己 `list-panes` 报的逐个比对。

```sh
swiftc -O -o /tmp/layoutcheck TmuxGUI/Tmux/TmuxLayout.swift Tools/LayoutCheck/main.swift
/tmp/layoutcheck
```

## 构建

需要 Xcode 和 tmux。

```sh
git clone --recurse-submodules https://github.com/XueshiQiao/tmux-gui.git && cd tmux-gui
xcodebuild -project TmuxGUI.xcodeproj -scheme TmuxGUI -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

已经 clone 过了：`git submodule update --init --recursive`。

**app sandbox 必须关着。** 沙盒里既起不了 tmux 子进程，也读不到
`/private/tmp/tmux-<uid>/` 下的 socket。

## 几个踩过的坑（都写在对应代码的注释里）

- macOS 26 上，一个会绘制的兄弟视图会拿到比自身高 66pt 的 backing layer（服务于
  标题栏的滚动边缘模糊），这块溢出不裁剪。谁后 `addSubview` 谁在上面——tab 栏一开始
  完全看不见就是被内容区糊住了。
- libghostty 的终端视图会在主菜单之前消费 ⌘ 组合键。子类化让菜单先挑。
- `%client-session-changed` 的第一个字段是**客户端名**，不是 session id，而且它是
  广播的。和 `%session-changed` 合并解析会让每条连接都指向别人的 session。
- `move-window` 的目标必须写成 `session:index`，少一个冒号 tmux 一声不吭地什么也不做。
- 点 tab 如果在 mouseDown 就 select，tmux 回报会重建整条 tab 栏，把正在拖的那个
  item 当场销毁。要在 mouseUp 才动。

## 已知边界

- 窗格内容在几何变化后靠 `capture-pane` 重新抓一次。tmux 改布局时会 reflow，
  但不会让里面的程序重绘。
- 压测结果用 `NSAlert.runModal()` 弹出，模态运行循环期间投递到主队列的回调会排队。
- 标题栏那个「卡顿 p99」只在窗格持续输出时才有意义；窗格闲着时数值会虚高。
  真正的判断看菜单里的 A/B 压测。
- `capture-pane` 的回复经过 `String` 解码，遇到非法 UTF-8 会被替换成 U+FFFD。
  只影响快照那一次；实时的 `%output` 走字节路径，不受影响。
- 还没做：搜索、复制模式、配置界面、多窗口。
