#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 1 ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 0.2.0"
  exit 1
fi

NEW_VERSION="$1"

# build.zig.zon
sed -i.bak -E "s/(\.version = \")[^\"]*(\",)/\1${NEW_VERSION}\2/" build.zig.zon
rm -f build.zig.zon.bak

# npm/chaza/package.json (version + optionalDependencies)
node -e "
const fs = require('fs');
const path = 'npm/chaza/package.json';
const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
pkg.version = '${NEW_VERSION}';
for (const key of Object.keys(pkg.optionalDependencies)) {
  pkg.optionalDependencies[key] = '${NEW_VERSION}';
}
fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + '\n');
"

echo "Bumped to ${NEW_VERSION}"
echo ""
echo "Changed files:"
git diff --stat
