#!/usr/bin/env bash
set -euo pipefail

action="${1:?usage: kernel-source.sh <resolve|checkout> <version> [dest_dir] [expected_commit]}"
version="${2:?missing kernel version}"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "ERROR: invalid kernel version: $version" >&2
  exit 1
fi

# Initial X.Y.0 release tag is vX.Y (not vX.Y.0); point releases are vX.Y.Z.
raw_version="$version"
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.0$ ]]; then
  raw_version="${version%.0}"
fi
ref="refs/tags/v$raw_version"

get_remotes() {
  if [[ -n "${KERNEL_GIT_URL:-}" ]]; then
    printf '%s\n' "$KERNEL_GIT_URL"
  else
    printf '%s\n' \
      "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git" \
      "https://github.com/gregkh/linux.git" \
      "https://github.com/torvalds/linux.git"
  fi
}

resolve_from_remote() {
  local remote_url="$1"
  local refs commit
  refs=$(git ls-remote --exit-code --tags "$remote_url" "$ref" "${ref}^{}" 2>/dev/null) || return 1
  commit=$(printf '%s\n' "$refs" | awk -v r="$ref" '
    $2 == r { tag = $1 }
    $2 == r "^{}" { commit = $1 }
    END { print (commit != "" ? commit : tag) }
  ')
  if ! [[ "$commit" =~ ^[0-9a-f]{40}$ ]]; then
    return 1
  fi
  printf '%s\n' "$commit"
}

resolve_commit_and_remote() {
  local remote_url commit
  while IFS= read -r remote_url; do
    [[ -n "$remote_url" ]] || continue
    if commit=$(resolve_from_remote "$remote_url"); then
      printf '%s\t%s\n' "$commit" "$remote_url"
      return 0
    fi
  done < <(get_remotes)
  echo "ERROR: kernel release tag not found in upstream remotes: $ref" >&2
  return 1
}

case "$action" in
  resolve)
    resolved=$(resolve_commit_and_remote)
    printf '%s\n' "${resolved%%$'\t'*}"
    ;;
  checkout)
    destination="${3:?missing destination directory}"
    expected_arg="${4:-}"
    resolved=$(resolve_commit_and_remote)
    resolved_commit="${resolved%%$'\t'*}"
    resolved_remote="${resolved#*$'\t'}"
    expected_commit="${expected_arg:-$resolved_commit}"

    if ! [[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]]; then
      echo "ERROR: invalid expected commit SHA: $expected_commit" >&2
      exit 1
    fi
    if [[ -d "$destination" ]] && [[ -n "$(ls -A "$destination" 2>/dev/null)" ]]; then
      echo "ERROR: destination directory is not empty: $destination" >&2
      exit 1
    fi

    git init --quiet "$destination"
    git -C "$destination" remote add origin "$resolved_remote"
    git -C "$destination" fetch --quiet --depth=1 origin "$ref"
    actual_commit=$(git -C "$destination" rev-parse 'FETCH_HEAD^{commit}')
    if [[ "$actual_commit" != "$expected_commit" ]]; then
      echo "ERROR: tag commit mismatch for $ref: expected $expected_commit, got $actual_commit" >&2
      exit 1
    fi
    git -C "$destination" checkout --quiet --detach "$actual_commit"

    actual_version=$(awk '
      /^VERSION[[:space:]]*=/ { v = $3 }
      /^PATCHLEVEL[[:space:]]*=/ { p = $3 }
      /^SUBLEVEL[[:space:]]*=/ { s = $3 }
      /^EXTRAVERSION[[:space:]]*=/ { extra = $3 }
      END {
        if (v != "" && p != "" && s != "" && extra == "") {
          print v "." p "." s
        }
      }
    ' "$destination/Makefile")

    normalized_version="$version"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
      normalized_version="${version}.0"
    fi
    if [[ "$actual_version" != "$normalized_version" ]]; then
      echo "ERROR: Makefile version mismatch: expected $normalized_version, got ${actual_version:-unknown}" >&2
      exit 1
    fi
    echo "Checked out ${ref} (${actual_commit}) from ${resolved_remote}, verified version ${actual_version}."
    ;;
  *)
    echo "ERROR: unknown action: $action" >&2
    exit 1
    ;;
esac
