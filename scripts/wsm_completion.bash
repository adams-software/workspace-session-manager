_wsm_complete() {
  local cur prev words cword
  _init_completion -n : || return

  local long_commands="create attach detach current status exists terminate first last prev next list"
  local global_flags="--root"

  __wsm_ids() {
    local root_override=""
    local i=1
    while [[ $i -lt ${#words[@]} ]]; do
      if [[ "${words[$i]}" == "--root" && $((i+1)) -lt ${#words[@]} ]]; then
        root_override="${words[$((i+1))]}"
        break
      elif [[ "${words[$i]}" == --root=* ]]; then
        root_override="${words[$i]#--root=}"
        break
      fi
      ((i++))
    done

    local root
    if [[ -n "$root_override" ]]; then
      root="$root_override"
    elif [[ -n "${WSM_ROOT:-}" ]]; then
      root="$WSM_ROOT"
    else
      root="$PWD"
    fi

    [[ -d "$root" ]] || return 0
    find "$root" \( -type s -o -type f \) -name '*.msr' 2>/dev/null | while IFS= read -r path; do
      local rel="${path#$root/}"
      [[ "$rel" == "$path" ]] && rel="$(basename -- "$path")"
      printf '%s\n' "${rel%.msr}"
    done | LC_ALL=C sort -u
  }

  __wsm_pathish_candidates() {
    local input="$1"
    local ids prefix rest first remainder candidate
    mapfile -t ids < <(__wsm_ids)
    [[ ${#ids[@]} -gt 0 ]] || return 0

    if [[ "$input" == */* ]]; then
      prefix="${input%/*}/"
      rest="${input##*/}"
    else
      prefix=""
      rest="$input"
    fi

    local seen=' '
    for candidate in "${ids[@]}"; do
      [[ "$candidate" == "$prefix"* ]] || continue
      remainder="${candidate#$prefix}"
      first="${remainder%%/*}"
      if [[ "$first" == "$remainder" ]]; then
        [[ "$first" == "$rest"* ]] || continue
        candidate="$prefix$first"
      else
        [[ "$first" == "$rest"* ]] || continue
        candidate="$prefix$first/"
      fi
      if [[ "$seen" != *" $candidate "* ]]; then
        printf '%s\n' "$candidate"
        seen+="$candidate "
      fi
    done | LC_ALL=C sort -u
  }

  if [[ "$cur" == --root=* ]]; then
    local root_prefix="--root="
    local root_cur="${cur#--root=}"
    COMPREPLY=( $(compgen -d -- "$root_cur") )
    local i
    for i in "${!COMPREPLY[@]}"; do
      COMPREPLY[$i]="$root_prefix${COMPREPLY[$i]}"
    done
    return
  fi

  if [[ $cword -eq 1 ]]; then
    COMPREPLY=( $(compgen -W "$long_commands $global_flags" -- "$cur") )
    return
  fi

  if [[ "$prev" == "--root" ]]; then
    _filedir -d
    return
  fi

  local cmd_index=1
  if [[ "${words[1]}" == "--root" ]]; then
    if [[ $cword -eq 2 ]]; then
      _filedir -d
      return
    fi
    if [[ $cword -eq 3 ]]; then
      COMPREPLY=( $(compgen -W "$long_commands $global_flags" -- "$cur") )
      return
    fi
    cmd_index=3
  elif [[ "${words[1]}" == --root=* ]]; then
    if [[ $cword -eq 2 ]]; then
      COMPREPLY=( $(compgen -W "$long_commands $global_flags" -- "$cur") )
      return
    fi
    cmd_index=2
  fi

  local cmd="${words[$cmd_index]:-}"
  if [[ -z "$cmd" ]]; then
    COMPREPLY=( $(compgen -W "$long_commands $global_flags" -- "$cur") )
    return
  fi

  case "$cmd" in
    c|create|a|attach|s|status|e|exists|terminate)
      if [[ $cword -eq $((cmd_index + 1)) ]]; then
        mapfile -t COMPREPLY < <(__wsm_pathish_candidates "$cur")
        return
      fi
      ;;
    detach|current|first|last|prev|next|list|help|--help)
      COMPREPLY=()
      return
      ;;
    *)
      COMPREPLY=( $(compgen -W "$long_commands $global_flags" -- "$cur") )
      return
      ;;
  esac
}

_wsm_completion_register() {
  complete -o nospace -F _wsm_complete wsm
  complete -o nospace -F _wsm_complete ./wsm
}

_wsm_completion_register
