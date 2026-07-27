#!/usr/bin/env bash
# Build the windrose-bot Lambda deployment package.
#
# Installs PyNaCl's precompiled wheel for the LAMBDA runtime (Amazon Linux /
# manylinux, CPython 3.12) — NOT the local interpreter — then drops handler.py
# alongside it. Terraform (infra/lambda.tf) zips bot/build/package for you.
#
# Run this before `terraform apply` and any time handler.py or requirements change.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT_DIR="$REPO_ROOT/bot"
PKG_DIR="$BOT_DIR/build/package"
PY_VERSION="3.12" # must match runtime in infra/lambda.tf

echo "==> Cleaning $PKG_DIR"
rm -rf "$BOT_DIR/build"
mkdir -p "$PKG_DIR"

echo "==> Installing dependencies for the Lambda runtime (cp${PY_VERSION/./}, manylinux2014_x86_64)"
# --require-hashes makes the pins in requirements.txt load-bearing rather than
# decorative: pip aborts if any downloaded artifact's sha256 does not match.
# PyNaCl is this bot's signature-verification code, so a swapped wheel is a
# silent authentication bypass, not just a broken build.
python3 -m pip install \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version "$PY_VERSION" \
  --only-binary=:all: \
  --require-hashes \
  --target "$PKG_DIR" \
  --upgrade \
  -r "$BOT_DIR/requirements.txt"

echo "==> Adding handler.py"
cp "$BOT_DIR/handler.py" "$PKG_DIR/handler.py"

echo "==> Done. Package contents:"
ls "$PKG_DIR"
echo
echo "Next: cd infra && terraform apply   (Terraform zips bot/build/package)"
