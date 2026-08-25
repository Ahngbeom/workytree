cmd_repos() {
  require_config
  all_repos "$WT_PROJECT_OPT" | while IFS=$'\t' read -r n p repo_path; do
    printf '%s\t%s\t%s\n' "$n" "$p" "$repo_path"
  done
}
