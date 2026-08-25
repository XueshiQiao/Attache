# The musl/busybox machine: everything the app runs remotely — the helper
# loop, the tmux-path discovery, the probe — goes through busybox sh here,
# which is the strictest POSIX audience it will ever have.
FROM alpine:3.20
RUN apk add --no-cache openssh tmux
COPY entry.sh /entry.sh
RUN chmod +x /entry.sh
EXPOSE 22
CMD ["/entry.sh"]
