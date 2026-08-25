#!/usr/bin/env zsh
source "${0:A:h}/helpers.zsh"

test_install_from_checkout_links_and_registers() {
  print '# existing' > "$HOME/.zshrc"
  WORKYTREE_INSTALL_DIR="$WT_TEST_ROOT" sh "$WT_TEST_ROOT/install.sh" >/dev/null 2>&1
  assert_eq "$?" 0
  assert_eq "$(readlink "$HOME/.local/bin/workytree")" "$WT_TEST_ROOT/bin/workytree"
  assert_eq "$(grep -c 'shell/workytree.zsh' "$HOME/.zshrc")" "1"
  assert_contains "$(cat "$HOME/.zshrc")" "# existing"
  assert_eq "$(ls "$HOME"/.zshrc.bak-* | wc -l | tr -d ' ')" "1"
  # idempotent
  WORKYTREE_INSTALL_DIR="$WT_TEST_ROOT" sh "$WT_TEST_ROOT/install.sh" >/dev/null 2>&1
  assert_eq "$(grep -c 'shell/workytree.zsh' "$HOME/.zshrc")" "1"
  assert_eq "$(ls "$HOME"/.zshrc.bak-* | wc -l | tr -d ' ')" "1"
  assert_eq "$(readlink "$HOME/.local/bin/workytree")" "$WT_TEST_ROOT/bin/workytree"
  assert_eq "$("$HOME/.local/bin/workytree" --version | cut -d' ' -f1)" "workytree"
}

run_tests
