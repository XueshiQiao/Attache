//
//  RemoteHelperScript.swift
//  Attache
//

import Foundation

/// The remote helper: a stateless POSIX `sh` read-eval loop, shipped to the
/// host as one argv word on every connection — nothing is installed remotely,
/// so there is no remote version to skew against.
///
/// Five remote features reduce to "run a small read-only thing over there and
/// get bytes back", and doing each as its own `ssh host cmd` fails on the
/// channel budget, not on speed: `MaxSessions` defaults to 10 per network
/// connection, which is exactly what one ControlMaster multiplexes, and
/// steady state already spends one channel per session's control client plus
/// one per content surface. One long-lived channel answering everything is
/// what keeps the arithmetic from ever reaching the ceiling.
///
/// ## Protocol
///
/// Requests are lines on stdin: `<tag> <verb> [<arg>…]`, followed by
/// verb-specific *path lines* (one path per line — the one shape a path
/// cannot carry). Replies are framed:
///
///     BEGIN <tag>
///     …header lines…
///     BYTES <n>
///     <exactly n raw bytes>\n
///     END <tag> <status>
///
/// Every variable-length payload is length-prefixed, so no byte sequence
/// inside a file can fake a frame line. Tags are matched, not trusted
/// positionally — requests may be pipelined, the loop answers in order, and a
/// tag mismatch on the client is a protocol error that tears the channel
/// down. Status 0 answered, 1 answered "not there", 2 unknown verb, 3 "the
/// question could not be executed here" — a missing git, an unreadable file —
/// which the client maps to the same `unavailable` outcome as a dead channel,
/// because a permission failure rendered as "no data" is the exact dishonesty
/// the three-outcomes rule exists to stop. "Could not ask at all" is the
/// client's own outcome and never appears on the wire.
///
/// The helper is **stateless on purpose**: reconnecting after a dropped
/// channel needs no re-priming, and the git change detection that would have
/// been state here (the stat-triple fingerprints) lives on the client, which
/// compares the answers instead.
///
/// The script contains **no single quote anywhere** — `helperScriptHasNoSingleQuote`
/// is checked by `Tools/HelperCheck` — because the whole text travels inside
/// one level of single-quoting (`TmuxTransport.helperArgv`).
///
/// Verified end-to-end by `Tools/HelperCheck`, which runs this exact string
/// through a local `/bin/sh` — sh is sh; ssh is only the pipe.
enum RemoteHelperScript {
    /// Bumped when the protocol changes shape. The client refuses a HELLO
    /// with a different number rather than guessing at the difference —
    /// which can only happen if two builds of this app share one master.
    static let protocolVersion = 1

    static let script = """
    PROTO=\(protocolVersion)

    if stat -f "%d %i %z %m" / >/dev/null 2>&1; then
      st() { stat -f "%d %i %z %m" -- "$1" 2>/dev/null; }
    else
      st() { stat -c "%d %i %s %Y" -- "$1" 2>/dev/null; }
    fi

    emit_file() {
      tail -c +$(($2 + 1)) -- "$1" 2>/dev/null | head -c "$3"
    }

    say() { printf "%s\\n" "$1"; }

    say "HELLO $PROTO"

    while read -r tag verb a1 a2; do
      case "$verb" in

      PING)
        say "BEGIN $tag"; say "END $tag 0" ;;

      HOME)
        n=$(printf "%s" "$HOME" | wc -c); n=$((n))
        say "BEGIN $tag"; say "BYTES $n"; printf "%s\\n" "$HOME"; say "END $tag 0" ;;

      READ)
        IFS= read -r p || break
        if [ ! -e "$p" ]; then
          say "BEGIN $tag"; say "ABSENT"; say "END $tag 1"
        elif [ -f "$p" ] && [ -r "$p" ]; then
          n=$(wc -c < "$p"); n=$((n)); [ "$n" -gt "$a1" ] && n=$a1
          say "BEGIN $tag"; say "BYTES $n"; emit_file "$p" 0 "$n"; say ""
          say "END $tag 0"
        else
          say "BEGIN $tag"; say "unreadable: $p"; say "END $tag 3"
        fi ;;

      STATTAIL)
        IFS= read -r p || break
        if [ -e "$p" ] && { [ ! -f "$p" ] || [ ! -r "$p" ]; }; then
          say "BEGIN $tag"; say "unreadable: $p"; say "END $tag 3"
          continue
        fi
        s=$(st "$p")
        if [ -n "$s" ] && [ -f "$p" ] && [ -r "$p" ]; then
          set -- $s
          dev=$1; ino=$2; size=$3
          start=$(($a1 - 64)); [ "$start" -lt 0 ] && start=0
          n=$((size - start)); [ "$n" -lt 0 ] && n=0
          say "BEGIN $tag"; say "STAT $dev $ino $size $start"
          say "BYTES $n"; emit_file "$p" "$start" "$n"; say ""
          say "END $tag 0"
        else
          say "BEGIN $tag"; say "ABSENT"; say "END $tag 1"
        fi ;;

      CLASSIFY)
        say "BEGIN $tag"
        i=0
        while [ "$i" -lt "$a1" ] && IFS= read -r p; do
          if [ -d "$p" ]; then say "d"; elif [ -f "$p" ]; then say "f"; else say "-"; fi
          i=$((i + 1))
        done
        say "END $tag 0" ;;

      PROBE)
        IFS= read -r p || break
        r=$(command -v -- "$p" 2>/dev/null)
        if [ -n "$r" ]; then
          n=$(printf "%s" "$r" | wc -c); n=$((n))
          say "BEGIN $tag"; say "BYTES $n"; printf "%s\\n" "$r"; say "END $tag 0"
        else
          say "BEGIN $tag"; say "ABSENT"; say "END $tag 1"
        fi ;;

      GITCHECK)
        say "BEGIN $tag"
        i=0
        while [ "$i" -lt "$a1" ] && IFS= read -r p; do
          g=$(git -C "$p" rev-parse --git-dir 2>&1)
          gs=$?
          if [ "$gs" -ne 0 ] || [ -z "$g" ]; then
            # A confirmed non-repository and a git that could not run are
            # different answers: ! tells the client to skip the compare —
            # a fingerprint invented from a failure would read as change.
            case "$g" in
              *"ot a git repositor"*) say "-" ;;
              *) say "!" ;;
            esac
          else
            g=$(printf "%s" "$g" | tail -n 1)
            case "$g" in /*) ;; *) g="$p/$g" ;; esac
            fp=""
            for f in HEAD index FETCH_HEAD; do
              s=$(st "$g/$f")
              if [ -n "$s" ]; then set -- $s; fp="$fp$3.$4/"; else fp="$fp-/"; fi
            done
            say "$fp"
          fi
          i=$((i + 1))
        done
        say "END $tag 0" ;;

      GITSTATUS)
        if ! command -v git >/dev/null 2>&1; then
          say "BEGIN $tag"; say "git is not installed here"; say "END $tag 3"
          continue
        fi
        say "BEGIN $tag"
        roots=""; m=0; i=0
        while [ "$i" -lt "$a1" ] && IFS= read -r p; do
          r=$(git -C "$p" rev-parse --show-toplevel 2>&1)
          rs=$?
          if [ "$rs" -ne 0 ] || [ -z "$r" ]; then
            # -1 is the *confirmed* non-repository; -2 is git failing to
            # answer for this path — a permission or safe.directory refusal —
            # which must never be cached as either real answer.
            case "$r" in
              *"ot a git repositor"*) say "PATH $i -1" ;;
              *) say "PATH $i -2" ;;
            esac
          else
            r=$(printf "%s" "$r" | tail -n 1)
            j=0; found=-1
            oldIFS=$IFS; IFS="
    "
            for known in $roots; do
              [ "$known" = "$r" ] && found=$j
              j=$((j + 1))
            done
            IFS=$oldIFS
            if [ "$found" -lt 0 ]; then
              found=$m; m=$((m + 1))
              if [ -z "$roots" ]; then roots="$r"; else roots="$roots
    $r"; fi
            fi
            say "PATH $i $found"
          fi
          i=$((i + 1))
        done
        say "NROOTS $m"
        oldIFS=$IFS; IFS="
    "
        for r in $roots; do
          IFS=$oldIFS
          n=$(printf "%s" "$r" | wc -c); n=$((n))
          say "ROOT"; say "BYTES $n"; printf "%s\\n" "$r"
          fh=$(git -C "$r" rev-parse --git-path FETCH_HEAD 2>/dev/null)
          case "$fh" in /*|"") ;; *) fh="$r/$fh" ;; esac
          fs=""
          [ -n "$fh" ] && fs=$(st "$fh")
          if [ -n "$fs" ]; then set -- $fs; say "FETCHED $4"; else say "FETCHED -"; fi
          out=$(GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 git -C "$r" \\
            --no-optional-locks -c core.fsmonitor= -c core.hooksPath=/dev/null \\
            status --porcelain=v2 --branch --untracked-files=normal 2>/dev/null </dev/null)
          os=$?
          if [ "$os" -ne 0 ]; then
            # A failed read is not a clean repository; empty porcelain here
            # would draw one. The client keeps its last summary instead.
            say "STATUSFAIL"
          else
            n=$(printf "%s" "$out" | wc -c); n=$((n))
            say "STATUS"; say "BYTES $n"; printf "%s" "$out"; say ""
          fi
          IFS="
    "
        done
        IFS=$oldIFS
        say "END $tag 0" ;;

      GITFETCH)
        IFS= read -r p || break
        if ! command -v git >/dev/null 2>&1; then
          say "BEGIN $tag"; say "git is not installed here"; say "END $tag 3"
          continue
        fi
        if GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true \\
          SSH_ASKPASS=/usr/bin/true git -C "$p" --no-optional-locks \\
          -c core.fsmonitor= -c core.hooksPath=/dev/null \\
          fetch --quiet --no-tags >/dev/null 2>&1 </dev/null; then
          say "BEGIN $tag"; say "END $tag 0"
        else
          say "BEGIN $tag"; say "ABSENT"; say "END $tag 1"
        fi ;;

      *)
        say "BEGIN $tag"; say "END $tag 2" ;;
      esac
    done
    """
}
