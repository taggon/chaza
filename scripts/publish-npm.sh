#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Publish a package to npm only if its (name, version) is not already
# on the registry. Safe to re-run on every main push.
publish_if_new() {
  local dir="$1"
  local name version
  name=$(node -p "require('./$dir/package.json').name")
  version=$(node -p "require('./$dir/package.json').version")

  if npm view "$name@$version" >/dev/null 2>&1; then
    echo "↩  skip   $name@$version (already published)"
  else
    echo "→  publish $name@$version"
    npm publish "$dir" --access public
  fi
}

# Platform-specific binaries produced by build-npm.sh (published first so the
# main package's optionalDependencies all exist before it goes live).
for dir in npm/@chaza-cli/*/; do
  [ -d "$dir" ] || continue
  publish_if_new "${dir%/}"
done

# Main package (loader + bin shim). Requires a prior `npm ci` + `npm run build`.
publish_if_new npm/chaza
