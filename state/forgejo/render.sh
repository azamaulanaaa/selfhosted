#!/bin/sh
# Render a Forgejo template without a Consul agent.
# This script is the smoke-test renderer. The container always renders the
# templates with consul-template.
# This script supports the small template subset in state/forgejo/*.tpl:
#   {{ env "NAME" }}
#   {{ or (env "NAME") "default" }}
#   {{ file "PATH" | trimSpace }}
#   {{ if eq (env "NAME") "VALUE" }} ... {{ else }} ... {{ end }}
#   {{ if eq (env "NAME") "VALUE" }}A{{ else }}B{{ end }}
# Lines between the peer block markers are dropped. This script never prints a
# secret value.
# Usage: render.sh <template> <output>
set -eu

template_file="$1"
output_file="$2"

# Print the value of one environment variable. Print nothing when it is unset.
env_value() {
  printenv "$1" 2>/dev/null || true
}

# Print the value of one supported template expression.
expression_value() {
  expr="$1"
  case "$expr" in
  '"'*'"')
    literal="${expr#\"}"
    literal="${literal%\"}"
    printf '%s' "$literal"
    ;;
  'env "'*'"')
    name="${expr#env \"}"
    name="${name%\"}"
    env_value "$name"
    ;;
  'or (env "'*'") "'*'"')
    name="${expr#or (env \"}"
    name="${name%%\")*}"
    default="${expr#*\") \"}"
    default="${default%\"}"
    value="$(env_value "$name")"
    if [ -n "$value" ]; then
      printf '%s' "$value"
    else
      printf '%s' "$default"
    fi
    ;;
  'file "'*'" | trimSpace')
    path="${expr#file \"}"
    path="${path%\" | trimSpace}"
    # The smoke test redirects mounted secret paths into a scratch tree.
    if [ -n "${SECRET_FILE_ROOT:-}" ]; then
      case "$path" in
      /etc/forgejo/secrets/*) path="${SECRET_FILE_ROOT}/${path##*/}" ;;
      esac
    fi
    if [ -r "$path" ]; then
      tr -d '\r\n' <"$path"
    fi
    ;;
  *)
    # Unsupported expressions render as empty text.
    ;;
  esac
}

# Replace every template expression on one line.
substitute_line() {
  remaining="$1"
  result=""
  while :; do
    case "$remaining" in
    *'{{'*'}}'*)
      prefix="${remaining%%'{{'*}"
      rest="${remaining#*'{{'}"
      expr="${rest%%'}}'*}"
      expr="$(printf '%s\n' "$expr" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
      remaining="${rest#*'}}'}"
      result="${result}${prefix}$(expression_value "$expr")"
      ;;
    *)
      result="${result}${remaining}"
      break
      ;;
    esac
  done
  printf '%s' "$result"
}

: >"$output_file"
active=1
parent_active=1
branch_active=1
in_peer_block=0

# Check that a line holds one inline conditional.
is_inline_conditional() {
  case "$1" in
  *'{{ if eq'*'{{ end }}'*) return 0 ;;
  *)
    return 1
    ;;
  esac
}

# Render one line that holds an inline conditional. The line holds one
# {{ if eq (env "NAME") "VALUE" }} expression, one optional {{ else }}
# expression, and one {{ end }} expression.
render_inline_conditional() {
  line="$1"
  prefix="${line%%"{{ if eq"*}"
  rest="${line#*"{{ if eq"}"
  expression="${rest%%"}}"*}"
  rest="${rest#*"}}"}"
  var="$(printf '%s\n' "$expression" | sed -n 's/.*env "\([^"]*\)".*/\1/p')"
  want="$(printf '%s\n' "$expression" | sed -n 's/.*) "\([^"]*\)".*/\1/p')"
  case "$rest" in
  *'{{ else }}'*)
    then_body="${rest%%"{{ else }}"*}"
    rest="${rest#*"{{ else }}"}"
    else_body="${rest%%"{{ end }}"*}"
    suffix="${rest#*"{{ end }}"}"
    ;;
  *)
    then_body="${rest%%"{{ end }}"*}"
    else_body=""
    suffix="${rest#*"{{ end }}"}"
    ;;
  esac
  if [ "$(env_value "$var")" = "$want" ]; then
    body="$then_body"
  else
    body="$else_body"
  fi
  rendered="$(substitute_line "${prefix}${body}${suffix}")"
  # An empty result drops the line. consul-template renders no blank line.
  if [ -z "$rendered" ]; then
    return 0
  fi
  printf '%s\n' "$rendered"
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
  '# BEGIN CONSUL PEER BLOCK'*)
    in_peer_block=1
    continue
    ;;
  '# END CONSUL PEER BLOCK'*)
    in_peer_block=0
    continue
    ;;
  esac
  if [ "$in_peer_block" -eq 1 ]; then
    continue
  fi

  if is_inline_conditional "$line"; then
    if [ "$active" -eq 1 ]; then
      render_inline_conditional "$line" >>"$output_file"
    fi
    continue
  fi

  cond_var="$(printf '%s\n' "$line" | sed -n 's/.*{{ if eq (env "\([^"]*\)") "\([^"]*\)" }}.*/\1/p')"
  if [ -n "$cond_var" ]; then
    cond_value="$(printf '%s\n' "$line" | sed -n 's/.*{{ if eq (env "\([^"]*\)") "\([^"]*\)" }}.*/\2/p')"
    actual="$(env_value "$cond_var")"
    if [ "$actual" = "$cond_value" ]; then
      branch_active=1
    else
      branch_active=0
    fi
    parent_active="$active"
    active=$((parent_active * branch_active))
    continue
  fi

  case "$line" in
  *'{{ else }}'*)
    active=$((parent_active * (1 - branch_active)))
    continue
    ;;
  *'{{ end }}'*)
    active="$parent_active"
    continue
    ;;
  esac

  if [ "$active" -eq 1 ]; then
    printf '%s\n' "$(substitute_line "$line")" >>"$output_file"
  fi
done <"$template_file"
