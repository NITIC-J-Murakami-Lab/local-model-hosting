#!/usr/bin/env bash
# Fetch a model's weights at a pinned revision into $MODELS_DIR/<dir>/.
# Usage: fetch-model.sh <dir> <repo> <revision> [extra hf download args...]
#
# When the download finishes, repo@revision is written to <dir>/.download-complete, and later runs skip it without the network.
# Changing the revision refetches only the files that changed. An interrupted download resumes when run again.
set -euo pipefail

if (($# < 3)); then
  echo "usage: $0 <dir> <repo> <revision> [hf download args...]" >&2
  exit 2
fi
dir="${MODELS_DIR:-/models}/$1" repo=$2 rev=$3
shift 3

# GPU slots that run the same model fetch it at the same time. The lock lets the first one download
# while the others wait, then find the marker and skip.
mkdir -p "$dir"
exec 9>"$dir/.fetch.lock"
flock 9

marker="$dir/.download-complete"
if [[ -f $marker && $(<"$marker") == "$repo@$rev" ]]; then
  echo "skip: $dir (already has $repo@$rev)"
  exit 0
fi
echo "fetch: $repo@$rev -> $dir"
hf download "$repo" "$@" --revision "$rev" --local-dir "$dir"
echo "$repo@$rev" >"$marker"
