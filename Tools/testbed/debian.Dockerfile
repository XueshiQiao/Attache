# One image, four personas: TMUX_BUILD picks what tmux (if any) the machine
# carries. "apt" is the distribution's own (bookworm: 3.3a in /usr/bin),
# "none" ships no tmux at all, and a version number ("3.1c", "3.5a") builds
# that release from source into /usr/local/bin — which is also how the
# machines that keep an old tmux around actually got theirs.
FROM debian:bookworm-slim
ARG TMUX_BUILD=apt
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server ca-certificates \
    && if [ "$TMUX_BUILD" = "apt" ]; then \
        apt-get install -y --no-install-recommends tmux; \
    fi \
    && if [ "$TMUX_BUILD" != "apt" ] && [ "$TMUX_BUILD" != "none" ]; then \
        apt-get install -y --no-install-recommends \
            curl gcc make libevent-dev libncurses-dev bison pkg-config \
        && curl -fsSL "https://github.com/tmux/tmux/releases/download/${TMUX_BUILD}/tmux-${TMUX_BUILD}.tar.gz" \
            -o /tmp/tmux.tar.gz \
        && tar -xzf /tmp/tmux.tar.gz -C /tmp \
        && cd "/tmp/tmux-${TMUX_BUILD}" && ./configure && make -j4 && make install \
        && cd / && rm -rf /tmp/tmux*; \
    fi \
    && rm -rf /var/lib/apt/lists/*
COPY entry.sh /entry.sh
RUN chmod +x /entry.sh
EXPOSE 22
CMD ["/entry.sh"]
