# cerebro lib: main
# dispatch: usage routing for top-level subcommands
# Sourced by bin/cerebro; not meant to be executed directly.

# ----- dispatch ------------------------------------------------------------

main() {
  if [[ $# -eq 0 ]]; then
    cmd_launch
    return
  fi
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --resume) shift; cmd_resume "${1:-}" ;;
    --observe) shift; cmd_launch_observer "${1:-}" ;;
    list) shift; cmd_list "$@" ;;
    plan) shift; cmd_plan "$@" ;;
    plans) shift; cmd_plans "$@" ;;
    audit) shift; cmd_audit "$@" ;;
    execute) shift; cmd_execute "$@" ;;
    review) shift; cmd_review "$@" ;;
    apply-review) shift; cmd_apply_review "$@" ;;
    doc-write) shift; cmd_doc_write "$@" ;;
    answer) shift; cmd_answer "$@" ;;
    steer) shift; cmd_steer "$@" ;;
    restart) shift; cmd_restart "$@" ;;
    observe) shift; cmd_observe "$@" ;;
    worktrees) shift; cmd_worktrees "$@" ;;
    recall) shift; cmd_recall "$@" ;;
    status) shift; cmd_status "$@" ;;
    spec) shift; cmd_spec "$@" ;;
    learnings)  shift; cmd_learnings "$@" ;;
    learn-note) shift; cmd_learn_note "$@" ;;
    learn-set)  shift; cmd_learn_set "$@" ;;
    git)    shift; cmd_git "$@" ;;
    gh)     shift; cmd_gh "$@" ;;
    read)   shift; cmd_read "$@" ;;
    grep)   shift; cmd_grep "$@" ;;
    ls)     shift; cmd_ls "$@" ;;
    *) die "unknown subcommand: $1 (try --help)" ;;
  esac
}
