#!/usr/bin/env bash
# See README.md for what this checks, how it works, and its limits.
# Usage: GH_TOKEN=... GITHUB_REPOSITORY=owner/repo verify_commits.sh <pr-number>
set -euo pipefail

: "${GH_TOKEN:?GH_TOKEN required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
PR_NUMBER="${1:?usage: $0 <pr-number>}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

WEBFLOW_EMAIL="noreply@github.com"
WEBFLOW_BOT_LOGINS=("renovate[bot]" "github-actions[bot]" "cow-github-bot[bot]")
ALLOWED_AUTOMATED_LOGINS=("cow-protocol")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALLOWED_SIGNERS_FILE="${ALLOWED_SIGNERS_FILE:-$SCRIPT_DIR/allowed_signers}"

log() { printf '[verify-commits] %s\n' "$*" >&2; }

is_allowed_automated_account() {
  local author_login="$1" author_email="$2" signature_file="$3" payload_file="$4"
  printf '%s\n' "${ALLOWED_AUTOMATED_LOGINS[@]}" | grep -qxF "$author_login" || return 1
  in_allowed_signers_registry "$author_email" "$signature_file" "$payload_file"
}

is_verified_webflow() {
  local author_login="$1" committer_email="$2" verified="$3"
  [[ "$committer_email" == "$WEBFLOW_EMAIL" && "$verified" == "true" ]] || return 1
  printf '%s\n' "${WEBFLOW_BOT_LOGINS[@]}" | grep -qxF "$author_login"
}

fingerprint_of_key() {
  local key_line="$1"
  printf '%s\n' "$key_line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{ print $2 }'
}

in_allowed_signers_registry() {
  local author_email="$1" signature_file="$2" payload_file="$3"
  ssh-keygen -Y verify -f "$ALLOWED_SIGNERS_FILE" -I "$author_email" \
    -n git -s "$signature_file" <"$payload_file" >/dev/null 2>&1
}

list_author_sk_fingerprints() {
  local login="$1"
  local cache="$WORKDIR/fingerprints-$login"
  if [[ -f "$cache" ]]; then
    cat "$cache"
    return 0
  fi

  local keys_file="$WORKDIR/keys-$login"
  if [[ ! -f "$keys_file" ]]; then
    if ! gh api --paginate "users/$login/ssh_signing_keys" --jq '.[].key' >"$keys_file" 2>/dev/null; then
      return 1
    fi
  fi

  : >"$cache"
  local key_line key_algorithm fingerprint
  while IFS= read -r key_line; do
    [[ -z "$key_line" ]] && continue
    key_algorithm="$(printf '%s\n' "$key_line" | awk '{ print $1 }')"
    [[ "$key_algorithm" != sk-* ]] && continue
    fingerprint="$(fingerprint_of_key "$key_line" || true)"
    if [[ -n "$fingerprint" ]]; then
      printf '%s\n' "$fingerprint" >>"$cache"
    fi
  done <"$keys_file"

  cat "$cache"
}

verified_signer_fingerprint() {
  local signature_file="$1"
  local payload_file="$2"
  if [[ ! -s "$signature_file" ]]; then
    return 1
  fi

  local check_output
  if ! check_output="$(ssh-keygen -Y check-novalidate -n git -s "$signature_file" <"$payload_file" 2>&1)"; then
    return 1
  fi

  local fingerprint
  fingerprint="$(printf '%s\n' "$check_output" | grep -oE 'SHA256:[A-Za-z0-9+/]+' | head -n1)"
  if [[ -z "$fingerprint" ]]; then
    return 1
  fi

  printf '%s\n' "$fingerprint"
}

signature_has_touch() {
  local signature_file="$1" flags
  flags="$(grep -v '^-----' "$signature_file" | base64 -d 2>/dev/null | tail -c 5 | head -c 1 | od -An -tu1 | tr -d ' ' || true)"
  [[ -n "$flags" && $((flags & 1)) -eq 1 ]]
}

REASON=""
check_commit_sk_signed() {
  local author_login="$1"
  local author_email="$2"
  local signature_file="$3"
  local payload_file="$4"
  REASON=""

  if [[ -z "$author_login" ]]; then
    REASON="author $author_email is not linked to any GitHub account"
    return 1
  fi

  local author_fingerprints
  if ! author_fingerprints="$(list_author_sk_fingerprints "$author_login")"; then
    REASON="could not fetch @$author_login's signing keys from GitHub"
    return 1
  fi
  if [[ -z "$author_fingerprints" ]]; then
    REASON="@$author_login has no sk- (hardware-backed) signing key on GitHub"
    return 1
  fi

  local signer_fingerprint
  signer_fingerprint="$(verified_signer_fingerprint "$signature_file" "$payload_file" || true)"
  if [[ -z "$signer_fingerprint" ]]; then
    REASON="commit is unsigned or its signature is not a valid SSH signature"
    return 1
  fi

  if ! printf '%s\n' "$author_fingerprints" | grep -qxF "$signer_fingerprint"; then
    REASON="not signed by an sk- (hardware-backed) key belonging to @$author_login"
    return 1
  fi

  if ! in_allowed_signers_registry "$author_email" "$signature_file" "$payload_file"; then
    REASON="signing key is not enrolled in the allowed_signers registry for $author_email"
    return 1
  fi

  if ! signature_has_touch "$signature_file"; then
    REASON="commit was signed without a touch (user-presence flag not set)"
    return 1
  fi

  return 0
}

COMMITS_FILE="$WORKDIR/commits.tsv"
gh api --paginate "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/commits" \
  --jq '.[] | [
      .sha,
      (.author.login // ""),
      .commit.author.email,
      .commit.committer.email,
      (.commit.verification.verified | tostring),
      (.commit.verification.signature // "" | @base64),
      (.commit.verification.payload   // "" | @base64)
    ] | @tsv' >"$COMMITS_FILE"


commit_count="$(gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" --jq '.commits')"
log "PR #$PR_NUMBER: verifying $commit_count commit(s)"
if [[ "$commit_count" -gt 250 ]]; then # the GitHub API limits to 250
  echo "::error::PR has $commit_count commits; only the first 250 are returned by the API and can be verified — split the PR or squash commits"
  exit 1
fi

[[ -s "$ALLOWED_SIGNERS_FILE" ]] ||
  log "warning: allowed_signers registry missing or empty ($ALLOWED_SIGNERS_FILE) — every human commit will fail the registry check"

ok=0
warned=0
failed=0
while IFS=$'\t' read -r sha author_login author_email committer_email verified signature_b64 payload_b64; do
  [[ -z "$sha" ]] && continue
  short_sha="${sha:0:9}"

  base64 -d <<<"$signature_b64" >"$WORKDIR/sig" 2>/dev/null || true
  base64 -d <<<"$payload_b64" >"$WORKDIR/payload" 2>/dev/null || true

  exempt_reason=""
  if is_verified_webflow "$author_login" "$committer_email" "$verified"; then
    exempt_reason="web-flow bot @$author_login"
  elif is_allowed_automated_account "$author_login" "$author_email" "$WORKDIR/sig" "$WORKDIR/payload"; then
    exempt_reason="allowed automated account @$author_login"
  fi

  if check_commit_sk_signed "$author_login" "$author_email" "$WORKDIR/sig" "$WORKDIR/payload"; then
    echo "OK    $short_sha  @$author_login"
    ok=$((ok + 1))
  elif [[ -n "$exempt_reason" ]]; then
    echo "::warning::$short_sha: $REASON — not an sk- key, allowed ($exempt_reason)"
    warned=$((warned + 1))
  else
    echo "::error::$short_sha: $REASON"
    failed=$((failed + 1))
  fi
done <"$COMMITS_FILE"

log "done: $ok ok, $warned warning(s), $failed failure(s)"
if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
