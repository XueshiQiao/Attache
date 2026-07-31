# 调试检查接口（Debug Inspector）

TmuxGUI 在 **Debug 构建**里可以开一个本机 HTTP 服务，把 app 内部状态以 JSON
吐出来，并允许改动少量设置。端口默认 **47623**，只绑 `127.0.0.1`。

> 本仓库其余文档一律英文（见 CLAUDE.md 的 Conventions）。这一份是应要求写的
> 中文版，所以文件名带 `.zh` 后缀，不占用英文文档的位置。

---

## 1. 它解决什么问题

一个没有眼睛的 agent 要在这个 app 上查 bug，缺的不是日志，而是**当前状态的
真值**。这个接口回答的就是三类问题：

| 问题 | 走哪条路由 | 实际用过的例子 |
|---|---|---|
| 键盘现在在谁那里？ | `/views` 的 `firstResponder` | 定位「侧边栏改名框自己关闭」——发现每次 tmux 通知都会把焦点抢走 |
| 某个视图的真实位置和大小是多少？ | `/views` 的 `frameInWindow` | 确认「把状态栏那一行顶出窗口」的做法方向反了：视图被往上顶而不是往下挪 |
| app 现在认为 tmux 是什么样？ | `/tmux` | 和 `tmux list-windows` 对拍，检查 app 有没有自己编造状态 |

它取代的是一个闭源 UI 检查器：那个只有配套 app 能读，对 agent 毫无用处。

## 2. 怎么开、怎么关

**只有 Debug 构建有这段代码。** 整个 `TmuxGUI/Debug/` 目录包在 `#if DEBUG`
里，正式构建里不存在——不是「默认关闭」，是编译不进去。

Debug 构建里，满足任一条件才会启动：

```sh
# 方式一：启动时带环境变量（不会被记住，退出即止）
TMUXGUI_INSPECT=1 /path/to/TmuxGUI.app/Contents/MacOS/TmuxGUI

# 方式二：菜单 Debug → Inspector Server（⌥⇧⌘I）。这个会被记住，下次自动开
```

换端口用 `TMUXGUI_INSPECT_PORT=47624`，用于两个 Debug 构建同时跑。

关掉：再按一次 ⌥⇧⌘I。想确认「记住的开关」当前状态：

```sh
defaults read dev.xueshi.TmuxGUI debug.inspector.enabled   # 无输出＝没记住，不会自动开
```

## 3. 安全边界

**能确定的：**

- **只绑回环。** `lsof -nP -iTCP:47623` 显示 `127.0.0.1:47623 (LISTEN)`，不是
  `*:47623`。从本机局域网 IP 连它连不上——局域网和外网都够不着。
- **写操作挡住了浏览器。** 读是普通 `GET`；写必须是 `POST` 且带
  `X-TmuxGUI-Inspect` 请求头。这一对浏览器造不出来：设自定义头会触发预检，而这个
  服务不回应预检。另外带 `Origin` 的请求一律拒绝，`Host` 必须是回环地址（这条堵
  DNS 重绑定）。

**必须知道的：**

**跟你同一用户身份运行的任何进程都能调它。** 回环不是身份认证，这里没有密码。
这是刻意的取舍——它的用途就是让在这台机器上干活的 agent 能读能驱动，代价是同机
的其他程序也能。所以它只存在于 Debug 构建。

历史上踩过一次：曾经有一条 `/embed` 路由接受任意命令字符串，等于让沙盒里的进程
借这个不带沙盒的 app 执行命令（Codex 评审发现）。修法是不再接受命令、只收白名单
参数；后来这条路由整个删掉了。**新增写路由时，不要接受可执行的字符串。**

## 4. 路由一览

以下为当前实现（2026-07-31）。改动了记得同步这张表。

### 只读（直接 `curl`）

| 路由 | 内容 |
|---|---|
| `/` 或 `/snapshot` | 全量：`generatedAt` + `windows`（视图树）+ `tmux`（tmux 状态） |
| `/views` | 只有视图树 |
| `/tmux` | 只有 tmux 状态 |
| `/settings` | 当前设置 + 推导出的主题配色 |
| `/settings-window?page=<页>` | **离屏**构建设置窗口并返回其视图树。不会抢焦点，用于确认某一页不崩、布局正常。`page` 取 `terminal` / `appearance` / `behaviour` / `quickactions` / `about` |

```sh
curl -s http://127.0.0.1:47623/tmux | python3 -m json.tool | head -40
```

**`/views` 每个节点的字段**：`type`、`identifier`、`accessibilityLabel`、
`frameInWindow`、`bounds`、`isHidden`、`isEffectivelyHidden`、`alpha`、
`wantsLayer`、`mouseDownCanMoveWindow`、`layer`（含 `overhang`）、`subviews`。
窗口层还有 `firstResponder`。

其中两个字段是踩坑踩出来的，别忽略：

- **`layer.overhang`** —— macOS 26 上一个会绘制的视图，其图层比自身高 66pt，且
  溢出部分不裁剪，谁最后加进去谁盖住谁。所以一个 frame 正确、`isHidden` 为 false、
  alpha 为 1 的视图，可能什么都看不见。先看这个字段。
- **`mouseDownCanMoveWindow`** —— AppKit 在派发 `mouseDown` **之前**先问命中视图
  这个问题，默认继承为 true。所以一个鼠标处理写得完全正确的视图可能一个事件都收
  不到。当年 pane 分隔线拖不动、文字选不中，都是这一个原因。

**`/tmux` 的结构**：`tmux.shownSession`（当前显示的 session）、`tmux.sessions`
（每个含 `sessionID` / `name` / `activeWindowID` / `focusedPaneID` /
`hiddenWindowIDs` / `windows`）、`tmux.sessionControllers`（app 实际持有的
session 模型）、`tmux.tmuxPath`。

`sessionControllers` 存在的理由：`sessions` 是按 tmux 现状生成的，所以「tmux 已经
没有、app 却还留着」的泄漏在 `sessions` 里看不见。两张表一对比就能发现。

### 写（必须 POST + 请求头）

统一格式：

```sh
curl -s -X POST -H 'X-TmuxGUI-Inspect: 1' "http://127.0.0.1:47623/<路由>?<参数>"
```

| 路由 | 参数 | 作用 |
|---|---|---|
| `/settings` | `fontSize` `fontFamily` `appearance` `lightTheme` `darkTheme` `windowOpacity` `blur` `frost` `rail` `style` `liquidClear` | 改设置，不用点界面 |
| `/window` | `size=1200x800` `position=x,y` `screen=primary` | 改主窗口的大小和位置 |
| `/select` | `session=<名字>` | 切换到某个 session |
| `/paste` | `run=1` `session=<名字>` | 执行一次 ⌘V 的粘贴 |
| `/shot` | `path=….png` `method=window\|view` `subview=<类名>` | 截图 |

**不带任何参数时，写路由只读不写**（`/shot` 除外，它总要写文件）。所以
`curl http://127.0.0.1:47623/settings` 是安全的读。

两条各自有教训：

- **`/paste` 的 `session` 参数是必填的，这不是洁癖。** 它一开始作用于「当前显示的
  session」，而那是坐在机器前的人随手一点就会变的值。2026-07-28 实测时，一张测试
  图片因此粘进了用户自己正在工作的 session。**会写东西的调试路由必须点名写到哪里。**
- **`/settings` 的字号有钳制。** 字号决定字符单元大小，单元小到把网格算成 1×1 时，
  app 会向 tmux 发 `refresh-client -C 1x1`，那个 session 里每个窗口连同里面跑着的
  程序会被重排成一列。这类伤害发生在 app 之外，没有撤销。

## 5. 它做不到的事

- **截自己的图看不到自己底下的东西。** `/shot` 用 `CGWindowListCreateImage`，只合成
  该窗口自身，不含它背后的画面。所以在半透明窗口上，它返回的是材质在「没有背景」时
  的灰色——同一张图在两个相距一千点的位置拍出来只差 1/255。凡是涉及透明、模糊、
  桌面透过来的效果，必须用 `screencapture`（需要屏幕录制权限）或者叫人来看。
- **合成事件送不进终端视图。** 用 `cliclick` 合成的右键，`onContextMenu` 一次都没
  被调用过（加日志验证过），而人手动右键是正常的。合成的双击也打不开侧边栏改名框：
  这个仓库的行视图故意不认合成事件（它们的 `clickCount` 是 0）。所以**涉及终端视图
  和侧边栏行的交互，脚本验证不了，只能人来点。**
- **屏幕睡着时截图会失败**，且失败的样子和「app 什么都没画」一模一样。先查：
  `system_profiler SPDisplaysDataType | grep -i 'display asleep'`。

## 6. 维护须知

代码在两个文件：

- `TmuxGUI/Debug/DebugInspectorServer.swift` —— HTTP 服务、路由分发、写操作的门槛。
- `TmuxGUI/Debug/DebugInspector.swift` —— 各路由的内容生成。

**加一条新路由要同时改四处**，漏一处就会出现「路由存在但被 405 挡住」或者
「本该受保护的写操作没受保护」：

1. `DebugInspector` 里写生成函数；
2. `DebugInspectorServer.respond` 里加分发；
3. 若会改变状态，把路径加进 `writeRoutes`（有参数才算写）或 `alwaysWriteRoutes`
   （总是写）；
4. `describeEndpoint()` 和 404 的提示文本里补上，否则启动日志和错误提示会骗人。

**删路由时**同样四处一起删。已经删过两条，都是因为它们服务的功能没了：`/grid`
（给已删除的 app 侧 pane 网格用的）、`/embed`（开内嵌原型窗口用的，现在主窗口本身
就是内嵌方案）。

**不要给写路由加「执行任意字符串」的能力**——理由见第 3 节。
