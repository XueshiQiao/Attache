# Building Attaché

Needs Xcode, tmux, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
git clone --recurse-submodules https://github.com/XueshiQiao/Attache.git
cd Attache
xcodegen generate
xcodebuild -project Attache.xcodeproj -scheme Attache -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/dd \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

/tmp/dd/Build/Products/Debug/Attaché.app/Contents/MacOS/Attache
```

Already cloned without submodules: `git submodule update --init --recursive`.

Run the binary directly rather than `open`-ing the bundle — stdout stays
attached, which is where the app's log lands.

## Things that will catch you out

**The app is `Attaché`; everything you type at it is `Attache`.** The accent is
on the product only — `Attaché.app`, the menu bar, Finder. The repository, the
source folder, the target, the scheme, the bundle identifier
(`me.xueshi.attache`) and the executable inside the bundle are plain ASCII, so
`pgrep`, `pkill -f` and every path in a build command work without an encoding
to think about. Both spellings are correct and they are not interchangeable.

**`project.yml` is the project; `Attache.xcodeproj` is a build artifact.** It is
gitignored and XcodeGen regenerates it. A build setting changed in Xcode's UI
lasts until the next `xcodegen generate` and then vanishes with no sign it was
ever there — change `project.yml` and regenerate.

`Scripts/normalize-libghostty.sh` needs a regenerate too: XcodeGen copies its
contents into the build phase, so an edited script does nothing until the
project is rebuilt from `project.yml`.

**The app sandbox must stay off.** A sandboxed process can neither spawn tmux
nor reach its socket under `/private/tmp/tmux-<uid>/`.
`Attache/Entitlement.entitlements` is an empty `<dict/>`, so `ENABLE_APP_SANDBOX:
NO` in `project.yml` is the only thing holding it off — and it fails at *launch*,
not at build, so a green build does not tell you it is still right.

**`SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG $(inherited)"`** on the Debug
configuration is load-bearing in the same way. Without it `Attache/Debug/` and
every `#if DEBUG` path compiles away silently and the inspector is simply not
there.

`libghostty-spm` is a git submodule pinned to a known-good commit, not a remote
package. If `Vendor/libghostty-spm` is empty, generation fails.

## Verifying a change

Reading the code is not verification. [CLAUDE.md](CLAUDE.md) has the full list of
what actually works, including several standalone checkers that run a case table
against the pure parts of the tmux layer with no app and no screen, for example:

```sh
swiftc -O -o /tmp/layoutcheck Attache/Tmux/TmuxLayout.swift Tools/LayoutCheck/main.swift
/tmp/layoutcheck
```

**Test against a throwaway tmux *server*, never a throwaway session**, and pass
`-L` on every single command — the create, every query, and the cleanup. The flag
is what picks the server; leaving it off any one command sends that command to
the one holding your real work.

```sh
tmux -L attache-test -f /dev/null new-session -d -s probe
tmux -L attache-test kill-server
```

`TMUX_TMPDIR` is **not** an isolation mechanism. On tmux 3.6a it is honoured only
when `-L` is also given; on its own it is silently ignored and every command
lands on the default server. CLAUDE.md records what that cost once.
