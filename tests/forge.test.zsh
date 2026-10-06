#!/usr/bin/env zsh
# lib/forge.zsh, sourced directly. gh/glab are stubbed as shell functions: bin/workytree puts
# the system dirs first on PATH, so a fake executable on PATH could not shadow a real install.
source "${0:A:h}/helpers.zsh"
source "$WT_TEST_ROOT/lib/forge.zsh"

# repo_with_origin <url>: a repo whose origin points at <url> (never contacted).
repo_with_origin() {
  make_repo "$HOME/r"
  git -C "$HOME/r" remote add origin "$1"
}

unstub() { unfunction gh glab 2>/dev/null; true; }

test_host_path_parses_https_ssh_and_scp_forms() {
  forge_host_path https://github.com/o/r.git;            assert_eq "${reply[*]}" "github.com o/r" https
  forge_host_path https://user:tok@gl.example.com/g/s/r;  assert_eq "${reply[*]}" "gl.example.com g/s/r" https-creds
  forge_host_path ssh://git@gl.example.com:2222/g/r.git;  assert_eq "${reply[*]}" "gl.example.com g/r" ssh-port
  forge_host_path git@github.com:o/r.git;                 assert_eq "${reply[*]}" "github.com o/r" scp
  forge_host_path /srv/git/r.git;                         assert_eq "$?" 1 local-path
  forge_host_path https://github.com;                     assert_eq "$?" 1 no-path
}

test_kind_by_known_host_then_by_logged_in_cli() {
  unstub; WT_FORGE_KINDS=()
  assert_eq "$(forge_kind github.com)" github
  assert_eq "$(forge_kind gitlab.com)" gitlab
  gh()   { return 1; }
  glab() { [[ "$*" == "auth status --hostname gl.example.com" ]]; }
  assert_eq "$(forge_kind gl.example.com)" gitlab self-hosted-gitlab
  gh()   { [[ "$*" == "auth status --hostname ghe.example.com" ]]; }
  WT_FORGE_KINDS=()
  assert_eq "$(forge_kind ghe.example.com)" github self-hosted-github
  assert_eq "$(forge_kind other.example.com)" none
  unstub
}

test_github_rows_are_normalized_and_deduplicated() {
  repo_with_origin https://github.com/o/r.git
  gh() {
    print -r -- "$*" > "$HOME/gh.args"
    print -r -- $'fix/A\t#3\tclosed\thttps://x/3\t2026-01-01T00:00:00Z'
    print -r -- $'fix/A\t#7\tmerged\thttps://x/7\t2026-03-01T00:00:00Z'
    print -r -- $'fix/A\t#5\topen\thttps://x/5\t2026-02-01T00:00:00Z'
    print -r -- $'feat/B\t#9\tdraft\thttps://x/9\t2026-01-05T00:00:00Z'
  }
  local out; out="$(forge_pr_rows "$HOME/r")"
  assert_eq "$?" 0
  assert_eq "$out" $'fix/A\t#7\tmerged\thttps://x/7\nfeat/B\t#9\tdraft\thttps://x/9'
  assert_contains "$(<"$HOME/gh.args")" "pr list -R github.com/o/r --state all"
  unstub
}

test_gitlab_passes_origin_url_to_glab() {
  repo_with_origin git@gitlab.com:g/s/r.git
  glab() { print -r -- "$*" > "$HOME/glab.args"; print -r -- $'fix/A\t!4\topen\thttps://x/4\t2026-01-01T00:00:00.000Z'; }
  assert_eq "$(forge_pr_rows "$HOME/r")" $'fix/A\t!4\topen\thttps://x/4'
  assert_contains "$(<"$HOME/glab.args")" "mr list -R git@gitlab.com:g/s/r.git --all"
  unstub
}

test_failures_return_1_with_one_reason_line() {
  local err
  make_repo "$HOME/r"
  git -C "$HOME/r" remote add origin https://github.com/o/r.git
  gh() { print -u2 "HTTP 401: Bad credentials"; return 4; }
  err="$(forge_pr_rows "$HOME/r" 2>&1 >/dev/null)"
  assert_eq "$?" 1 gh-fails
  assert_eq "$err" "github lookup failed (exit 4): HTTP 401: Bad credentials"
  unstub

  git -C "$HOME/r" remote set-url origin https://other.example.com/o/r.git
  gh() { return 1; }; glab() { return 1; }
  err="$(forge_pr_rows "$HOME/r" 2>&1 >/dev/null)"
  assert_contains "$err" "not a GitHub/GitLab host"
  unstub
}

test_repo_without_origin_yields_nothing_silently() {
  make_repo "$HOME/r"
  local out; out="$(forge_pr_rows "$HOME/r" 2>&1)"
  assert_eq "$?" 0
  assert_eq "$out" ""
}

test_missing_cli_is_reported_not_run() {
  repo_with_origin https://github.com/o/r.git
  unstub
  local err; err="$(path=(/usr/bin /bin); forge_pr_rows "$HOME/r" 2>&1 >/dev/null)"
  assert_eq "$err" "gh is not installed; PR lookup skipped"
}

test_hung_cli_is_killed_after_timeout() {
  repo_with_origin https://github.com/o/r.git
  gh() { sleep 5; print -r -- $'fix/A\t#1\topen\tu\tt'; }
  local err; err="$(WT_FORGE_TIMEOUT=1; forge_pr_rows "$HOME/r" 2>&1 >/dev/null)"
  assert_eq "$err" "github lookup timed out after 1s; PR column left empty"
  unstub
}

test_kind_is_detected_once_per_host() {
  unstub
  WT_FORGE_KINDS=()
  glab() { print -r -- x >> "$HOME/glab.calls"; [[ "$1 $2" == "auth status" ]]; }
  gh() { return 1; }
  forge_kind gl.example.com >/dev/null
  forge_kind gl.example.com >/dev/null
  assert_eq "$(forge_kind gl.example.com)" gitlab
  assert_eq "$(wc -l < "$HOME/glab.calls" | tr -d ' ')" 1
  WT_FORGE_KINDS=()
  unstub
}

run_tests
