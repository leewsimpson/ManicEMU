#!/bin/bash
# Make a restored DerivedData cache usable for an incremental build.
#
# A fresh checkout gives every file a new mtime, so Xcode would rebuild
# everything. Instead, date every tracked file (submodules included) to a
# fixed old time, then mark only the files that changed since the cached
# build as new. The cached build's commit is read from <DerivedData>/.source-sha.
#
# Usage: set-mtimes.sh <DerivedData dir>
set -euo pipefail

DERIVED_DATA="$1"
OLD=200001010000

AGE="git ls-files -z | xargs -0 touch -h -c -t $OLD"
eval "$AGE"
git submodule foreach --quiet --recursive "$AGE"

SHA_FILE="$DERIVED_DATA/.source-sha"
if [[ ! -f "$SHA_FILE" ]]; then
    echo "No cached build: full build."
    exit 0
fi

CACHED="$(cat "$SHA_FILE")"
if ! git cat-file -e "$CACHED^{commit}" 2>/dev/null &&
    ! git fetch --quiet --depth=1 origin "$CACHED"; then
    echo "Cached build's commit $CACHED isn't fetchable: clearing the cache."
    rm -rf "$DERIVED_DATA"
    exit 0
fi

echo "Cached build is from $CACHED. Changed since then:"
git diff --name-only --no-renames "$CACHED" HEAD | while IFS= read -r path; do
    if [[ -d "$path" ]]; then
        # A submodule moved: treat all of it as changed.
        echo "  $path/ (submodule)"
        (cd "$path" && git ls-files -z | xargs -0 touch -h -c)
    elif [[ -e "$path" ]]; then
        echo "  $path"
        touch -h -c "$path"
    fi
done
