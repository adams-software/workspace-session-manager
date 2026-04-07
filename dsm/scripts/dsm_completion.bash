_dsm_complete() {
  local cur prev words cword
  _init_completion -n : || return

  local commands="c create a attach d detach current f first l last p prev n next terminate wait status exists ls list help -h --help"
  local name_cmds="c create a attach terminate wait status exists"

  __dsm_names() {
    local cwd_override=""
    local i=1
    while [[ $i -lt $cword ]]; do
      if [[ "${words[$i]}" == "--cwd" && $((i+1)) -lt ${#words[@]} ]]; then
        cwd_override="${words[$((i+1))]}"
        break
      fi
      ((i++))
    done

    local dir
    if [[ -n "$cwd_override" ]]; then
      dir="$cwd_override"
    elif [[ -n "${MSR_SESSION:-}" ]]; then
      dir="$(dirname -- "$MSR_SESSION")"
    else
      dir="$PWD"
    fi

    [[ -d "$dir" ]] || return 0
    local f base
    shopt -s nullglob
    for f in "$dir"/*.msr; do
      base="$(basename -- "$f")"
      printf '%s\n' "${base%.msr}"
    done | LC_ALL=C sort -u
  }

  if [[ $cword -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return
  fi

  case "${words[1]}" in
    --cwd)
      if [[ $cword -eq 2 ]]; then
        _filedir -d
        return
      fi
      if [[ $cword -eq 3 ]]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return
      fi
      ;;
  esac

  local cmd_index=1
  if [[ "${words[1]}" == "--cwd" ]]; then
    cmd_index=3
  fi
  local cmd="${words[$cmd_index]}"

  if [[ "$prev" == "--cwd" ]]; then
    _filedir -d
    return
  fi

  case "$cmd" in
    c|create)
      if [[ $cword -eq $((cmd_index + 1)) ]]; then
        COMPREPLY=( $(compgen -W "$(__dsm_names)" -- "$cur") )
        return
      fi
      COMPREPLY=()
      return
      ;;
    a|attach|terminate|wait|status|exists)
      if [[ $cword -eq $((cmd_index + 1)) ]]; then
        COMPREPLY=( $(compgen -W "$(__dsm_names)" -- "$cur") )
        return
      fi
      ;;
    d|detach|current|ls|list|help|-h|--help)
      COMPREPLY=()
      return
      ;;
  esac
}

_dsm_completion_register() {
  complete -F _dsm_complete dsm
  complete -F _dsm_complete ./dsm
}

_dsm_completion_register
