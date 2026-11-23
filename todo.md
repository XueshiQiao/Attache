# 待办

## 隐私防护开启后，Gemini（agy）在沙箱里一条命令都执行不了

发现时间：2026-11-17。

**已修复（2026-11-23，attache-cli 0.3.21）。** 用的是下面「可以考虑的修法」里的第 1 种，具体做法：

```
钩子（在沙箱外面）读到规则后：
    把规则写成 ~/.local/state/attache/guard/rules-<sha256>.json（0600，和保险库放在一起）
    把命令改写成 attache-cli guard run --agent agy --rules-snapshot <sha256> --sh <原命令>
guard run（在沙箱里面）：
    按 sha256 读这份副本，不再读 ~/.config/attache-guard.toml
    如果 副本不存在，或者内容算出的 sha256 和参数对不上：拒绝执行
```

当时查清的事实：agy 1.5.14 每条命令生成的沙箱规则禁止读整个 `~/.config`，那里只单独放开了 `~/.config/bat`；`~/.local/state` 可以读，而且这份规则允许读写整个家目录，所以副本要靠 sha256 防止被改。验证：`agy --sandbox` 下执行 `head`、`git log` 等命令都成功；在抓到的 agy 沙箱规则下执行 `git log --format=%ae`，邮箱被遮成占位符；`cli/tests/guard_sandbox.rs` 用 `sandbox-exec` 测这个场景，去掉修复后这个测试会失败。

下面是发现问题时的记录。

### 现象

用 `agy --sandbox` 运行 Gemini，并且隐私防护对 agy 生效时，Gemini 的每一条 shell 命令都不会执行，退出码是 125，报错原文：

```text
A pre-tool hook changed the arguments of this tool call before it ran. Changed: CommandLine.
Command exited with code 125.
Command output:
Attaché privacy guard: ~/.config/attache-guard.toml: Operation not permitted (os error 1). The command was not run.
```

连 `cat ~/AGENTS.md` 这样的命令也是同样的报错。

同时，带有隐私值的文件（比如带 GitHub 登录名的 workflow 文件、`project.yml`），隐私防护不让 Gemini 用读文件工具直接读，提示它改用 shell 命令读。shell 命令又执行不了，所以这类文件 Gemini 完全读不到。

实际影响：`~/dotfiles/scripts/agent-roles/run.py` 启动 agy 时固定带 `--sandbox`，所以 Alice 和 Flash 的评审、干活都做不了。2026-11-17 那次评审里，五处改动只读到了两处。

### 原因

```
Gemini 想执行一条命令
    agy 先调用钩子「attache-cli guard hook agy-pre」（配置在 ~/.gemini/config/hooks.json）
        钩子运行在沙箱外面，能读到规则文件 ~/.config/attache-guard.toml
        如果 隐私防护是开启状态：
            把命令改写成「attache-cli guard run --agent agy --sh <原命令>」
            （cli/src/guard/hooks.rs 的 "agy-pre" 分支）
    agy 在自己的沙箱里执行改写后的命令
        attache-cli guard run 启动后先调用 Engine::load()，要读规则文件
        沙箱拒绝读 ~/.config/attache-guard.toml，返回 EPERM
        Rules::load()（cli/src/guard/rules.rs）把「文件存在但读不了」当成错误返回
        run_command()（cli/src/guard/mod.rs）打印报错，不执行原命令
```

拒绝来自 agy 的沙箱，不是文件权限：规则文件的权限是所有人可读，在沙箱外运行 `attache-cli guard status` 能正常读到。

「规则文件读不了就拒绝执行」这个行为本身是对的，不能改成读不了就放行。问题在于：钩子在沙箱外，被它包出来的命令在沙箱内，沙箱内的那一层拿不到规则文件。存放真实值的保险库如果也在沙箱不让读的位置，会遇到同样的问题。

### 还没查清的

- agy 的沙箱具体是哪条规则不让读 `~/.config` 下的这个文件。agy 的沙箱规则没有公开文档（当时的版本是 agy 1.5.10）。
- agy 有没有办法在配置里给沙箱加允许读取的路径。
- 沙箱内的 `attache-cli guard run` 除了规则文件，还需要读写哪些文件（保险库、事件记录），这些在沙箱里是否也被拒绝。
- Codex 的沙箱里有没有同样的问题。

### 可以考虑的修法

1. 由沙箱外的钩子把沙箱内那一层需要的内容传进去（比如放进改写后的命令的参数或环境变量里），让 `guard run` 不需要自己读规则文件和保险库。要注意传进去的内容不能出现在 Gemini 能看到的命令文本里。
2. 让 `guard run` 把「恢复真实值、执行命令、遮住输出」这些事交给沙箱外的一个常驻进程去做，沙箱内只留一个转发的小程序。
3. 如果 agy 支持给沙箱加允许读取的路径，在 `guard install agy` 时把规则文件和保险库的路径加进去。

修好之前的临时办法（都有代价）：

- `attache-cli guard uninstall agy`：Gemini 的对话里不再遮隐私信息。
- 让 `run.py` 不带 `--sandbox`：Gemini 的命令不再受沙箱限制，只剩 `gate.py` 把关。

### 修好后怎么验证

- 隐私防护开启的状态下，用 `agy --sandbox` 让 Gemini 执行 `cat ~/AGENTS.md` 和 `git -C <另一个仓库> show <提交>`，命令能执行，输出里的隐私值被遮住。
- 让 Alice 用评审档重新评审一次带登录名的文件（比如某个仓库的发布 workflow），确认能读到内容。
- 给这个场景补一个测试：规则文件只有钩子能读到、`guard run` 读不到时，命令仍然能在遮住输出的前提下执行。
