#!/bin/sh
#
# Entry point for every testbed container: one sshd, one `attache` user, and
# whatever defect the persona's environment variables ask for. POSIX sh on
# purpose — this same file boots Debian (dash) and Alpine (busybox), and the
# app's own remote scripts make the same promise.
#
set -e

# Fresh host keys on the first boot of this container instance. A recreated
# container gets new ones, which is why `testbed.sh up` clears the client's
# known_hosts file: a changed key is a hard ssh error that accept-new does
# not paper over, and it would read as the app failing.
ssh-keygen -A

# bash when the image has it (Debian), else sh (Alpine's busybox ash, which
# edits lines fine on its own). Debian's /bin/sh is dash, which has no line
# editing at all — an arrow key at its prompt prints ^[[A, which reads as
# the terminal being broken and is only the shell being minimal. The app's
# own remote scripts are unaffected either way: they run through `sh -c`.
LOGIN_SHELL=/bin/sh
[ -x /bin/bash ] && LOGIN_SHELL=/bin/bash

if ! id attache >/dev/null 2>&1; then
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -s "$LOGIN_SHELL" attache
    else
        adduser -D -s "$LOGIN_SHELL" attache
    fi
fi
# A real password, always: it unlocks the account (a locked account refuses
# key auth too), and the password-only persona needs one to exist.
echo "attache:attache" | chpasswd

mkdir -p /home/attache/.ssh
cp /run/testbed/id_ed25519.pub /home/attache/.ssh/authorized_keys
chown -R attache /home/attache/.ssh
chmod 700 /home/attache/.ssh
chmod 600 /home/attache/.ssh/authorized_keys

# sshd takes the FIRST occurrence of a key, so the persona's lines must sit
# above the baseline, and both above the distribution's stock file.
CONF=/etc/ssh/sshd_config
TMP=/etc/ssh/sshd_config.testbed
: > "$TMP"

if [ "${PASSWORD_ONLY:-0}" = "1" ]; then
    {
        echo "PubkeyAuthentication no"
        echo "PasswordAuthentication yes"
        echo "KbdInteractiveAuthentication yes"
    } >> "$TMP"
fi
if [ -n "${MAX_SESSIONS:-}" ]; then
    echo "MaxSessions ${MAX_SESSIONS}" >> "$TMP"
fi
if [ "${BANNER:-0}" = "1" ]; then
    {
        echo "*** attache testbed ***"
        echo "This machine prints a three-line login banner,"
        echo "with a # and a \$ in the text, before auth finishes."
    } > /etc/banner
    echo "Banner /etc/banner" >> "$TMP"
fi
if [ "${SLOW:-0}" = "1" ]; then
    # Every command this user runs goes through a shell that sleeps first —
    # sshd runs remote commands through the login shell, so this delays the
    # probe, the control attach and the helper alike, which is the point.
    printf '#!/bin/sh\nsleep 2\nexec %s "$@"\n' "$LOGIN_SHELL" > /usr/local/bin/slowsh
    chmod +x /usr/local/bin/slowsh
    echo /usr/local/bin/slowsh >> /etc/shells
    if command -v usermod >/dev/null 2>&1; then
        usermod -s /usr/local/bin/slowsh attache
    else
        sed -i 's|attache:[^:]*$|attache:/usr/local/bin/slowsh|' /etc/passwd
    fi
fi

{
    echo "PasswordAuthentication no"
    echo "KbdInteractiveAuthentication no"
    echo "PermitRootLogin no"
} >> "$TMP"

cat "$CONF" >> "$TMP"
mv "$TMP" "$CONF"

mkdir -p /run/sshd 2>/dev/null || true
exec /usr/sbin/sshd -D -e
