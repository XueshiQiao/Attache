# The remote-host testbed

Eight ssh servers in containers, each one machine with one deliberate
defect. They exist because the feature they test — `[[host]]` blocks, the
Hosts settings page, tmux-path discovery, the connection lifecycle — has
most of its bugs at the edges: machines that are slow, old, locked down, or
missing tmux entirely. One healthy Mac mini cannot say anything about
those, and plenty of real machines people will point this app at *are*
Linux containers.

```sh
./testbed.sh up        # build + start + write testbed.sshconfig
./testbed.sh status    # is every persona answering
./testbed.sh down      # stop the fleet
```

One manual step, once: put this at the **top** of `~/.ssh/config` (Include
is only global before the first `Host` block):

```
Include /Users/joey/Code/tmux-gui/Tools/testbed/testbed.sshconfig
```

Then add hosts in the app — "+ Add server…" in the rail, ssh destination
`attache-test-<persona>`, everything else empty. Removing that Include line
retires the whole testbed; nothing else on the machine is touched. The
client key lives in `keys/` (gitignored), is minted by `up`, and logs into
nothing outside these containers.

## The personas, and what the app owes each

| ssh destination | defect | what the app should do |
|---|---|---|
| `attache-test-plain` | none — Debian, tmux 3.3a at `/usr/bin/tmux` | connect; discovery finds `/usr/bin/tmux` via `command -v`; badges live |
| `attache-test-old-tmux` | tmux **3.1c** (before subscriptions) | connect, one warning notice; sessions and windows work, rail badges stay blank rather than wrong |
| `attache-test-tmux35` | tmux **3.5a** (last octal-escaping release) | connect; window lists intact — a `\001` that leaks says the version-gated decode broke |
| `attache-test-no-tmux` | no tmux anywhere | discovery reports "not found" with the places it looked; a saved host sits down with the same words, never a silent empty block |
| `attache-test-password-only` | keys refused, password required | fail fast and say so (BatchMode); never hang waiting for a prompt nobody can type into |
| `attache-test-max-sessions` | `MaxSessions 1` | the master takes the one slot; data channels get the "session limit (MaxSessions) is exhausted" wording, not a generic error |
| `attache-test-slow-banner` | three-line login banner + every command through a shell that sleeps 2s | banner must not corrupt the control stream; states show "connecting…" honestly instead of flickering; nothing times out at 2s |
| `attache-test-alpine` | busybox sh, musl | discovery, probe and the helper loop all run — this is the strictest POSIX audience they have |

Worth testing *across* personas: add several at once and watch the rail
keep them apart; kill one container mid-session (`docker compose stop
plain`) and watch its block go down with ssh's own words while the others
stay up; `docker compose start plain` and click the row to retry.

## Sharp edges

- `up` clears `keys/known_hosts` because recreated containers mint new
  host keys, and a *changed* key is a hard ssh error that
  `StrictHostKeyChecking accept-new` does not cover.
- The password for `attache` on every container is `attache` — for
  manually poking the password-only persona (`ssh -F testbed.sshconfig
  attache-test-password-only`); the app itself can never type it, which is
  that persona's whole point.
- `testbed.sshconfig` is generated with absolute paths and is gitignored;
  run `up` again after moving the checkout.
- Ports 2210–2217 on 127.0.0.1. Nothing binds beyond loopback.
