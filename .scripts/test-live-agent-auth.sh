#!/usr/bin/env bash
# Run inside a fresh Claude sandbox with a repository path argument. Exercises the
# configured SSH remote without printing its URL or refs.
set -u
repo=${1:?repository path required}

if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  echo "AUTH=INVALID_REPOSITORY"
  exit 1
fi

remote=$(git -C "$repo" remote get-url origin 2>/dev/null)
case "$remote" in
  git@*:*|ssh://*) ;;
  *)
    echo "AUTH=NON_SSH_REMOTE"
    exit 1 ;;
esac

diagnostic=$(mktemp "${TMPDIR%/}/claude-agent-auth.XXXXXX") || exit 1
trap 'rm -f "$diagnostic"' EXIT

if [ "$(command -v git)" != "$HOME/.local/bin/git" ]; then
  echo "AUTH=GIT_SHIM_MISSING"
  exit 1
fi

if git -C "$repo" ls-remote origin HEAD >/dev/null 2>"$diagnostic"; then
  echo "AUTH=READY"
else
  if grep -q 'Operation not permitted' "$diagnostic"; then
    echo "AUTH=SANDBOX_BLOCKED"
  elif grep -Eq 'Could not resolve hostname|nodename nor servname provided' "$diagnostic"; then
    echo "AUTH=DNS_FAILED"
  elif grep -q 'Connection timed out' "$diagnostic"; then
    echo "AUTH=TIMEOUT"
  elif grep -q 'Proxy connection failed: Connection refused' "$diagnostic"; then
    echo "AUTH=LOCAL_PROXY_REFUSED"
  elif grep -q 'Error: proxy request: Connection refused' "$diagnostic"; then
    echo "AUTH=REMOTE_PORT_REFUSED"
  elif grep -q 'Connection refused from proxy' "$diagnostic"; then
    echo "AUTH=REMOTE_PORT_REFUSED"
  elif grep -q 'Connection refused' "$diagnostic"; then
    echo "AUTH=CONNECTION_REFUSED"
  elif grep -q 'Host key verification failed' "$diagnostic"; then
    echo "AUTH=HOST_KEY_FAILED"
  elif grep -q 'Permission denied (publickey)' "$diagnostic"; then
    echo "AUTH=KEY_REJECTED"
  elif grep -Eq 'repository not found|project you were looking for could not be found' "$diagnostic"; then
    echo "AUTH=REMOTE_DENIED"
  elif grep -q 'ssh-sandbox-proxy: unsupported proxy scheme' "$diagnostic"; then
    echo "AUTH=HELPER_UNSUPPORTED_SCHEME"
  elif grep -q 'ssh-sandbox-proxy: authenticated proxy URL required' "$diagnostic"; then
    echo "AUTH=HELPER_MISSING_CREDENTIALS"
  elif grep -q 'ssh-sandbox-proxy: proxy password missing' "$diagnostic"; then
    echo "AUTH=HELPER_MISSING_PASSWORD"
  elif grep -q 'ssh-sandbox-proxy: proxy endpoint is not loopback' "$diagnostic"; then
    echo "AUTH=HELPER_NON_LOOPBACK"
  elif grep -q 'ssh-sandbox-proxy: invalid proxy port' "$diagnostic"; then
    echo "AUTH=HELPER_INVALID_PORT"
  elif grep -q 'Error: authentication failed' "$diagnostic"; then
    echo "AUTH=SOCKS_CREDENTIALS_REJECTED"
  elif grep -q 'Error: proxy selected invalid authentication method' "$diagnostic"; then
    echo "AUTH=SOCKS_INVALID_METHOD"
  elif grep -q 'Error: sending proxy authentication' "$diagnostic"; then
    echo "AUTH=SOCKS_AUTH_SEND_FAILED"
  elif grep -q 'Error: malformed proxy authentication response' "$diagnostic"; then
    echo "AUTH=SOCKS_AUTH_RESPONSE_INVALID"
  elif grep -q 'Error: no acceptable authentication method proposed' "$diagnostic"; then
    echo "AUTH=SOCKS_METHOD_REJECTED"
  elif grep -q 'Proxy connection failed' "$diagnostic"; then
    echo "AUTH=SOCKS_CONNECTION_FAILED"
  elif grep -q 'Could not resolve proxy' "$diagnostic"; then
    echo "AUTH=SOCKS_PROXY_DNS_FAILED"
  else
    echo "AUTH=FAILED_OTHER"
  fi
  exit 1
fi
