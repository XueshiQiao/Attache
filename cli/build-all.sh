#!/bin/sh
# Builds attache-cli for every host the phone and the desktop install it on,
# into dist/<os>-<arch>/attache-cli, named the way `uname -s` and `uname -m`
# say them (lowercased), so a client picks the build from one `uname -sm`.
# Linux builds are static (musl); see .cargo/config.toml.
set -eu
cd "$(dirname "$0")"
rustup target add aarch64-apple-darwin x86_64-apple-darwin \
  aarch64-unknown-linux-musl x86_64-unknown-linux-musl >/dev/null
for pair in \
  aarch64-apple-darwin:darwin-arm64 \
  x86_64-apple-darwin:darwin-x86_64 \
  aarch64-unknown-linux-musl:linux-aarch64 \
  x86_64-unknown-linux-musl:linux-x86_64
do
  target=${pair%%:*}
  name=${pair#*:}
  cargo build --release --target "$target"
  mkdir -p "dist/$name"
  cp "target/$target/release/attache-cli" "dist/$name/attache-cli"
done
ls -l dist/*/attache-cli
