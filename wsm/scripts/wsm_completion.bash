_wsm_complete() {
  local cur prev words cword
  _init_completion -n : || return

  local long_commands="help create attach list inspect log cleanup kill"
  local global_flags="--workspace"

  __wsm_ids() {
    local root_override=""
    local i=1
    while [[ $i -lt ${#words[@]} ]]; do
      if [[ "${words[$i]}" == "--workspace" && $((i+1)) -lt ${#words[@]} ]]; then
        root_override="${words[$((i+1))]}"
        break
      elif [[ "${words[$i]}" == --workspace=* ]]; then
        root_override="${words[$i]#--workspace=}"
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
      return 0
    fi

    [[ -d "$root" ]] || return 0
    find "$root" \( -type s -o -type f \) -name '*.wsm' 2>/dev/null | while IFS= read -r path; do
      local rel="${path#$root/}"
      [[ "$rel" == "$path" ]] && rel="$(basename -- "$path")"
      printf '%s\n' "${rel%.wsm}"
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

  if [[ "$cur" == --workspace=* ]]; then
    local root_prefix="--workspace="
    local root_cur="${cur#--workspace=}"
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

  if [[ "$prev" == "--workspace" ]]; then
    _filedir -d
    return
  fi

  local cmd_index=1
  if [[ "${words[1]}" == "--workspace" ]]; then
    if [[ $cword -eq 2 ]]; then
      _filedir -d
      return
    fi
    if [[ $cword -eq 3 ]]; then
      COMPREPLY=( $(compgen -W "$long_commands $global_flags" -- "$cur") )
      return
    fi
    cmd_index=3
  elif [[ "${words[1]}" == --workspace=* ]]; then
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
    create|attach|inspect|log|kill)
      if [[ $cword -eq $((cmd_index + 1)) ]]; then
        mapfile -t COMPREPLY < <(__wsm_pathish_candidates "$cur")
        return
      fi
      ;;
    help|list|cleanup)
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
