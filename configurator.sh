#!/usr/bin/env bash
# Copyright (c) 2026 Andrzej Janczak
# SPDX-License-Identifier: MIT

set -uo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${AUTOMERGER_CONFIG:-$SCRIPT_DIR/config.json}"
LINE_DELAY_MS="${AUTOMERGER_CONFIGURATOR_LINE_DELAY_MS:-20}"
SLOW_OUTPUT_PID=""

[[ "$LINE_DELAY_MS" =~ ^[0-9]+$ ]] || LINE_DELAY_MS=20
LINE_DELAY_SECONDS="$(printf '%d.%03d' "$((LINE_DELAY_MS / 1000))" "$((LINE_DELAY_MS % 1000))")"

enable_slow_output() {
    local character
    ((LINE_DELAY_MS > 0)) || return 0
    command -v sleep >/dev/null 2>&1 || return 0
    exec 3>&1 4>&2
    exec > >(
        while IFS= read -r -N 1 character; do
            printf '%s' "$character" >&3
            [[ "$character" == $'\n' ]] && sleep "$LINE_DELAY_SECONDS"
        done
    ) 2>&1
    SLOW_OUTPUT_PID=$!
    trap flush_slow_output EXIT
}

flush_slow_output() {
    [[ -n "$SLOW_OUTPUT_PID" ]] || return 0
    exec 1>&3 2>&4
    wait "$SLOW_OUTPUT_PID" 2>/dev/null || true
    exec 3>&- 4>&-
}

enable_slow_output

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly GREEN=$'\033[32m'
    readonly RED=$'\033[31m'
    readonly YELLOW=$'\033[33m'
    readonly BOLD=$'\033[1m'
    readonly RESET=$'\033[0m'
else
    readonly GREEN="" RED="" YELLOW="" BOLD="" RESET=""
fi

readonly -a REQUIRED_COMMANDS=(git jq flock timeout setsid base64 mktemp realpath sha256sum stat find stty awk sed cut sort sleep openssl gh bwrap)

declare -a MODEL_KEYS=()
declare -a MODEL_PROVIDERS=()
declare -a MODEL_CODE_NAMES=()
declare -a MODEL_EFFORT_OPTIONS=()
declare -a MODEL_DEFAULT_EFFORTS=()
declare -a MODEL_COMMANDS=()
declare -a MODEL_CLOSE_COMMANDS=()
declare -a MODEL_BASE_NAMES=()
declare -a AVAILABLE_MODEL_NAMES=()
declare -a AVAILABLE_MODEL_GROUPS=()
declare -a AVAILABLE_MODEL_EFFORTS=()
declare -a AVAILABLE_MODEL_RAW_NAMES=()

usage() {
    cat <<'EOF'
Użycie:
  configurator.sh [--config PLIK]

Interaktywnie sprawdza środowisko i aktualizuje konfigurację automergera.
EOF
}

while (($# > 0)); do
    case "$1" in
        --config)
            (($# >= 2)) || { printf 'BŁĄD: --config wymaga ścieżki.\n' >&2; exit 2; }
            CONFIG_FILE="$2"
            shift 2
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *)
            printf 'BŁĄD: nieznana opcja: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

wait_for_enter() {
    printf '\nNaciśnij ENTER, aby zakończyć.'
    IFS= read -r _
}

wait_to_continue() {
    printf '\nNaciśnij ENTER, aby przejść dalej.'
    if ! IFS= read -r _; then
        printf '\n'
        return 1
    fi
    printf '\n'
}

check_bwrap_namespaces() {
    command -v bwrap >/dev/null 2>&1 || return 1
    bwrap --unshare-user --unshare-pid --unshare-ipc --unshare-uts --disable-userns \
        --new-session --die-with-parent \
        --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind-try /lib64 /lib64 \
        --proc /proc --dev /dev --clearenv --setenv PATH /usr/bin:/bin -- /bin/true >/dev/null 2>&1
}

check_environment() {
    local skip_wait="${1:-false}" command_name
    local -a available=() missing=()

    printf '%sSprawdzanie środowiska%s\n\n' "$BOLD" "$RESET"
    if ((BASH_VERSINFO[0] >= 5)); then
        printf '%s✓ Bash %s spełnia wymaganie Bash 5+.%s\n' "$GREEN" "$BASH_VERSION" "$RESET"
    else
        printf '%s✗ Bash %s nie spełnia wymagania Bash 5+.%s\n' "$RED" "$BASH_VERSION" "$RESET"
        missing+=("bash>=5")
    fi

    for command_name in "${REQUIRED_COMMANDS[@]}"; do
        if [[ "$command_name" == "bwrap" ]]; then
            if check_bwrap_namespaces; then
                available+=("bwrap (unprivileged user namespaces: OK)")
            else
                missing+=("bwrap (brak albo niedostępne unprivileged user namespaces)")
            fi
        elif command -v "$command_name" >/dev/null 2>&1; then
            available+=("$command_name")
        else
            missing+=("$command_name")
        fi
    done

    printf '\n%sDostępne:%s\n' "$GREEN" "$RESET"
    if ((${#available[@]} == 0)); then
        printf '  (brak)\n'
    else
        printf '%s  ✓ %s%s\n' "$GREEN" "${available[0]}" "$RESET"
        for command_name in "${available[@]:1}"; do
            printf '%s  ✓ %s%s\n' "$GREEN" "$command_name" "$RESET"
        done
    fi

    if ((${#missing[@]} == 0)); then
        printf '\n%sWszystkie wymagane polecenia są dostępne.%s\n' "$GREEN" "$RESET"
        [[ "$skip_wait" == "true" ]] || wait_to_continue
    else
        printf '\n%sNiedostępne:%s\n' "$RED" "$RESET"
        for command_name in "${missing[@]}"; do
            printf '%s  ✗ %s%s\n' "$RED" "$command_name" "$RESET"
        done
        printf '\n%sPrzed uruchomieniem skryptu głównego brakujące programy muszą zostać doinstalowane ręcznie.%s\n' "$RED" "$RESET"
        return 1
    fi
}

shell_quote() {
    printf '%q' "$1"
}

is_safe_relative_path() {
    local path="$1" segment
    local -a segments=()
    [[ -n "$path" && "$path" != /* && "$path" != *//* && "$path" != */ ]] || return 1
    IFS='/' read -r -a segments <<<"$path"
    for segment in "${segments[@]}"; do
        [[ -n "$segment" && "$segment" != "." && "$segment" != ".." ]] || return 1
    done
    [[ ! "$path" =~ [[:cntrl:]] ]]
}

sanitize_model_key() {
    local value="$1"
    value="$(printf '%s' "$value" | sed -E 's/[^A-Za-z0-9_.-]+/-/g; s/^-+//; s/-+$//')"
    printf '%s' "${value:-model}"
}

is_safe_model_identifier() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]*$ ]]
}

model_key_exists() {
    local expected="$1" existing
    for existing in "${MODEL_KEYS[@]}"; do
        [[ "$existing" == "$expected" ]] && return 0
    done
    return 1
}

add_model() {
    local key="$1" provider="$2" code_name="$3" effort_options="$4" default_effort="$5" command="$6" close_command="$7"
    local suffix
    if model_key_exists "$key"; then
        suffix="$(printf '%s:%s:%s' "$provider" "$code_name" "$default_effort" | sha256sum | cut -c1-8)"
        key="$key-$suffix"
        model_key_exists "$key" && return 0
    fi
    MODEL_KEYS+=("$key")
    MODEL_PROVIDERS+=("$provider")
    MODEL_CODE_NAMES+=("$code_name")
    MODEL_EFFORT_OPTIONS+=("$effort_options")
    MODEL_DEFAULT_EFFORTS+=("$default_effort")
    MODEL_COMMANDS+=("$command")
    MODEL_CLOSE_COMMANDS+=("$close_command")
    if [[ -n "$default_effort" && "$key" == *"-$default_effort" ]]; then
        MODEL_BASE_NAMES+=("${key%-$default_effort}")
    else
        MODEL_BASE_NAMES+=("$key")
    fi
}

available_model_exists() {
    local expected="$1" existing
    for existing in "${AVAILABLE_MODEL_NAMES[@]}"; do
        [[ "$existing" == "$expected" ]] && return 0
    done
    return 1
}

add_available_model() {
    local group="$1" name="$2" efforts="${3:-}" raw_name="${4:-$2}" index
    is_safe_model_identifier "$name" || return 1
    if available_model_exists "$name"; then
        for ((index = 0; index < ${#AVAILABLE_MODEL_NAMES[@]}; index++)); do
            [[ "${AVAILABLE_MODEL_NAMES[$index]}" == "$name" ]] || continue
            [[ -n "${AVAILABLE_MODEL_EFFORTS[$index]}" || -z "$efforts" ]] || AVAILABLE_MODEL_EFFORTS[$index]="$efforts"
            return 0
        done
    fi
    AVAILABLE_MODEL_GROUPS+=("$group")
    AVAILABLE_MODEL_NAMES+=("$name")
    AVAILABLE_MODEL_EFFORTS+=("$efforts")
    AVAILABLE_MODEL_RAW_NAMES+=("$raw_name")
}

load_configured_available_models() {
    local config_dir models_relative models_file group name efforts raw_name
    config_dir="$(cd -- "$(dirname -- "$CONFIG_FILE")" && pwd -P)"
    models_relative="$(jq -r '.models_config_file // "models_config.json"' "$CONFIG_FILE" 2>/dev/null || true)"
    is_safe_relative_path "$models_relative" || return 0
    models_file="$config_dir/$models_relative"
    [[ -r "$models_file" ]] || return 0
    while IFS=$'\t' read -r group name efforts; do
        valid_model_group "$group" || continue
        case "$group" in
            codex-like) raw_name="${name#codex-}" ;;
            claude-like) raw_name="${name#claude-}" ;;
            openhands-vllm-like)
                raw_name="${name#openhands-}"
                [[ "$raw_name" != hosted_vllm-* ]] || raw_name="hosted_vllm/${raw_name#hosted_vllm-}"
                ;;
            other) raw_name="$name" ;;
        esac
        add_available_model "$group" "$name" "$efforts" "$raw_name"
    done < <(jq -r '
        (.available_models // {})
        | to_entries[]
        | .key as $group
        | .value | to_entries[]
        | [$group, .key, ((.value // []) | join(","))]
        | @tsv
    ' "$models_file" 2>/dev/null)
}

valid_model_group() {
    case "$1" in
        codex-like | claude-like | openhands-vllm-like | other) return 0 ;;
        *) return 1 ;;
    esac
}

model_group_rank() {
    case "$1" in
        codex-like) printf '1' ;;
        claude-like) printf '2' ;;
        openhands-vllm-like) printf '3' ;;
        other) printf '4' ;;
    esac
}

sort_available_models() {
    local index record group name efforts raw
    local -a records=() sorted_groups=() sorted_names=() sorted_efforts=() sorted_raw=()
    for ((index = 0; index < ${#AVAILABLE_MODEL_NAMES[@]}; index++)); do
        records+=("$(model_group_rank "${AVAILABLE_MODEL_GROUPS[$index]}")|${AVAILABLE_MODEL_NAMES[$index]}|${AVAILABLE_MODEL_GROUPS[$index]}|${AVAILABLE_MODEL_EFFORTS[$index]}|${AVAILABLE_MODEL_RAW_NAMES[$index]}")
    done
    while IFS='|' read -r _ name group efforts raw; do
        [[ -n "$name" ]] || continue
        sorted_names+=("$name"); sorted_groups+=("$group"); sorted_efforts+=("$efforts"); sorted_raw+=("$raw")
    done < <(printf '%s\n' "${records[@]}" | sort -t '|' -k1,1n -k2,2)
    AVAILABLE_MODEL_NAMES=("${sorted_names[@]}")
    AVAILABLE_MODEL_GROUPS=("${sorted_groups[@]}")
    AVAILABLE_MODEL_EFFORTS=("${sorted_efforts[@]}")
    AVAILABLE_MODEL_RAW_NAMES=("${sorted_raw[@]}")
}

normalize_effort_list() {
    local input="${1//[[:space:]]/}" effort result="" seen=","
    local -a parts=()
    [[ -n "$input" ]] || { printf ''; return 0; }
    IFS=',' read -r -a parts <<<"$input"
    for effort in "${parts[@]}"; do
        [[ "$effort" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
        [[ "$seen" == *",$effort,"* ]] && continue
        seen+="$effort,"
        result+="${result:+,}$effort"
    done
    printf '%s' "$result"
}

codex_effort_fallback() {
    case "$1" in
        codex-gpt-5.6-sol | codex-gpt-5.6-terra) printf 'low,medium,high,xhigh,max,ultra' ;;
        codex-gpt-5.6-luna) printf 'low,medium,high,xhigh,max' ;;
        codex-gpt-5.4 | codex-gpt-5.4-mini | codex-gpt-5.5) printf 'low,medium,high,xhigh' ;;
        *) printf '' ;;
    esac
}

discover_codex_models() {
    local cache_file="${AUTOMERGER_CODEX_MODELS_CACHE:-${CODEX_HOME:-${HOME:-}/.codex}/models_cache.json}"
    local slug effort effort_options
    [[ -r "$cache_file" ]] || return 0
    while IFS=$'\t' read -r slug effort effort_options; do
        [[ -n "$slug" ]] || continue
        is_safe_model_identifier "$slug" || continue
        effort="${effort:-medium}"
        effort_options="$(normalize_effort_list "$effort_options" 2>/dev/null || true)"
        [[ -n "$effort_options" ]] || effort_options="$(codex_effort_fallback "codex-$slug")"
        add_available_model "codex-like" "codex-$slug" "$effort_options" "$slug"
    done < <(jq -r '
        .models[]?
        | select((.visibility // "list") == "list")
        | [
            .slug,
            (.default_reasoning_level // "medium"),
            ((.supported_reasoning_levels // []) | map(.effort) | map(select(type == "string")) | join(", "))
        ]
        | @tsv
    ' "$cache_file" 2>/dev/null)
}

discover_claude_models() {
    local help_output alias effort_options=""
    help_output="$(claude --help 2>/dev/null || true)"
    if [[ "$help_output" == *"--effort"* ]]; then
        effort_options="$(printf '%s\n' "$help_output" | sed -n '
            /--effort[[:space:]]*<level>/,/^[[:space:]]*--[[:alnum:]-]/ {
                /([^)]*)/ {
                    s/.*(\([^)]*\)).*/\1/p
                    q
                }
            }
        ')"
    fi
    for alias in sonnet opus fable; do
        [[ "$help_output" == *"$alias"* ]] || continue
        add_available_model "claude-like" "claude-$alias" "$(normalize_effort_list "$effort_options" 2>/dev/null || true)" "$alias"
    done
}

discover_openhands_models() {
    local openhands_home="${AUTOMERGER_OPENHANDS_HOME:-${HOME:-}/.openhands}"
    local settings_file model configured_effort key command
    local -a settings_files=()
    local -A detected_efforts=()
    [[ -f "$openhands_home/agent_settings.json" ]] && settings_files+=("$openhands_home/agent_settings.json")
    [[ -f "$openhands_home/cli_config.json" ]] && settings_files+=("$openhands_home/cli_config.json")
    if [[ -d "$openhands_home/profiles" ]]; then
        while IFS= read -r -d '' settings_file; do
            settings_files+=("$settings_file")
        done < <(find "$openhands_home/profiles" -type f -name '*.json' -print0)
    fi
    while IFS=$'\t' read -r model configured_effort; do
        [[ -n "$model" ]] || continue
        is_safe_model_identifier "$model" || continue
        if [[ ! -v "detected_efforts[$model]" || (-z "${detected_efforts[$model]}" && -n "$configured_effort") ]]; then
            detected_efforts[$model]="$configured_effort"
        fi
    done < <({
        [[ -n "${LLM_MODEL:-}" ]] && printf '%s\t%s\n' "$LLM_MODEL" "${LLM_REASONING_EFFORT:-}"
        for settings_file in "${settings_files[@]}"; do
            jq -r '
                ..
                | objects
                | select((.model? | type) == "string")
                | [.model, (.reasoning_effort // "")]
                | @tsv
            ' "$settings_file" 2>/dev/null || true
        done
    } | sort -u)

    ((${#detected_efforts[@]} > 0)) || return 0
    while IFS= read -r model; do
        configured_effort="${detected_efforts[$model]}"
        key="openhands-$(sanitize_model_key "$model")"
        add_available_model "openhands-vllm-like" "$key" "$(normalize_effort_list "$configured_effort" 2>/dev/null || true)" "$model"
    done < <(printf '%s\n' "${!detected_efforts[@]}" | sort)
}

print_available_models() {
    local index previous_group="" group
    sort_available_models
    printf '\n%sModele bazowe brane pod uwagę:%s\n' "$BOLD" "$RESET"
    for ((index = 0; index < ${#AVAILABLE_MODEL_NAMES[@]}; index++)); do
        group="${AVAILABLE_MODEL_GROUPS[$index]}"
        if [[ "$group" != "$previous_group" ]]; then
            printf '\n  %s%s:%s\n' "$BOLD" "$group" "$RESET"
            previous_group="$group"
        fi
        printf '    %d. %s\n' "$((index + 1))" "${AVAILABLE_MODEL_NAMES[$index]}"
    done
    ((${#AVAILABLE_MODEL_NAMES[@]} > 0)) || printf '  (brak)\n'
}

edit_available_models() {
    local answer action group name index
    while true; do
        print_available_models
        printf '\nENTER/accept = zatwierdź, remove NUMER = usuń, add GRUPA NAZWA = dodaj: '
        IFS= read -r answer || return 1
        answer="$(trim "$answer")"
        [[ -z "$answer" || "${answer,,}" == "accept" ]] && return 0
        read -r action group name _ <<<"$answer"
        case "${action,,}" in
            remove | delete)
                [[ "$group" =~ ^[0-9]+$ ]] || { printf '%sPodaj numer modelu.%s\n' "$RED" "$RESET"; continue; }
                index=$((10#$group - 1))
                if ((index < 0 || index >= ${#AVAILABLE_MODEL_NAMES[@]})); then
                    printf '%sNie ma modelu o takim numerze.%s\n' "$RED" "$RESET"
                    continue
                fi
                unset 'AVAILABLE_MODEL_NAMES[index]' 'AVAILABLE_MODEL_GROUPS[index]' 'AVAILABLE_MODEL_EFFORTS[index]' 'AVAILABLE_MODEL_RAW_NAMES[index]'
                AVAILABLE_MODEL_NAMES=("${AVAILABLE_MODEL_NAMES[@]}")
                AVAILABLE_MODEL_GROUPS=("${AVAILABLE_MODEL_GROUPS[@]}")
                AVAILABLE_MODEL_EFFORTS=("${AVAILABLE_MODEL_EFFORTS[@]}")
                AVAILABLE_MODEL_RAW_NAMES=("${AVAILABLE_MODEL_RAW_NAMES[@]}")
                ;;
            add)
                valid_model_group "$group" && [[ -n "$name" ]] && is_safe_model_identifier "$name" || {
                    printf '%sUżycie: add codex-like|claude-like|openhands-vllm-like|other NAZWA%s\n' "$RED" "$RESET"
                    continue
                }
                if available_model_exists "$name"; then
                    printf '%sModel o tej nazwie już istnieje.%s\n' "$YELLOW" "$RESET"
                    continue
                fi
                case "$group" in
                    codex-like) add_available_model "$group" "$name" "" "${name#codex-}" ;;
                    claude-like) add_available_model "$group" "$name" "" "${name#claude-}" ;;
                    openhands-vllm-like)
                        local openhands_raw="${name#openhands-}"
                        [[ "$openhands_raw" != hosted_vllm-* ]] || openhands_raw="hosted_vllm/${openhands_raw#hosted_vllm-}"
                        add_available_model "$group" "$name" "" "$openhands_raw"
                        ;;
                    other) add_available_model "$group" "$name" "" "$name" ;;
                esac
                ;;
            *) printf '%sNieznana operacja edytora listy.%s\n' "$RED" "$RESET" ;;
        esac
    done
}

configure_available_model_efforts() {
    local index name group detected answer normalized
    printf '\n%sEfforty modeli%s\n' "$BOLD" "$RESET"
    printf 'Zatwierdź wykryte wartości lub podaj własne po przecinku.\n'
    for ((index = 0; index < ${#AVAILABLE_MODEL_NAMES[@]}; index++)); do
        name="${AVAILABLE_MODEL_NAMES[$index]}"
        group="${AVAILABLE_MODEL_GROUPS[$index]}"
        [[ "$group" != "other" ]] || { AVAILABLE_MODEL_EFFORTS[$index]=""; continue; }
        detected="${AVAILABLE_MODEL_EFFORTS[$index]}"
        if [[ -z "$detected" && "$group" == "codex-like" ]]; then
            detected="$(codex_effort_fallback "$name")"
        fi
        while true; do
            if [[ -n "$detected" ]]; then
                printf '%s [%s]: ' "$name" "$detected"
            else
                printf '%s — nie udało się wykryć effortów, podaj je po przecinku: ' "$name"
            fi
            IFS= read -r answer || return 1
            answer="$(trim "$answer")"
            answer="${answer:-$detected}"
            normalized="$(normalize_effort_list "$answer" 2>/dev/null || true)"
            if [[ -n "$normalized" ]]; then
                AVAILABLE_MODEL_EFFORTS[$index]="$normalized"
                break
            fi
            printf '%sPodaj co najmniej jeden effort, np. medium,high,xhigh.%s\n' "$RED" "$RESET"
        done
    done
}

build_model_variants() {
    local index group base raw effort key command efforts
    local -a effort_parts=()
    sort_available_models
    MODEL_KEYS=(); MODEL_PROVIDERS=(); MODEL_CODE_NAMES=(); MODEL_EFFORT_OPTIONS=(); MODEL_DEFAULT_EFFORTS=(); MODEL_COMMANDS=(); MODEL_CLOSE_COMMANDS=(); MODEL_BASE_NAMES=()
    for ((index = 0; index < ${#AVAILABLE_MODEL_NAMES[@]}; index++)); do
        group="${AVAILABLE_MODEL_GROUPS[$index]}"; base="${AVAILABLE_MODEL_NAMES[$index]}"; efforts="${AVAILABLE_MODEL_EFFORTS[$index]}"; raw="${AVAILABLE_MODEL_RAW_NAMES[$index]}"
        if [[ "$group" == "other" ]]; then
            command="printf '%s\\n' $(shell_quote "Model $base nie został skonfigurowany. Uzupełnij models_config.json.") >&2; exit 1"
            add_model "$base" "Other" "$base" "" "" "$command" "true"
            continue
        fi
        IFS=',' read -r -a effort_parts <<<"$efforts"
        for effort in "${effort_parts[@]}"; do
            key="$base-$(sanitize_model_key "$effort")"
            case "$group" in
                codex-like)
                    command="codex exec --model $(shell_quote "$raw") --config $(shell_quote "model_reasoning_effort=\"$effort\"") --config $(shell_quote 'approval_policy="never"') --sandbox danger-full-access --ephemeral {{PROMPT}}"
                    add_model "$key" "Codex" "$raw" "$efforts" "$effort" "$command" "true"
                    ;;
                claude-like)
                    command="claude --model $(shell_quote "$raw") --effort $(shell_quote "$effort") --permission-mode acceptEdits --no-session-persistence --disable-slash-commands --tools \"Read,Edit,Glob,Grep\" --disallowedTools \"Bash,WebFetch,WebSearch,NotebookEdit\" --append-system-prompt \"\$(cat {{PROMPT_FILE}})\" -p {{PROMPT}}"
                    add_model "$key" "Claude" "$raw" "$efforts" "$effort" "$command" "true"
                    ;;
                openhands-vllm-like)
                    command="OPENHANDS_SUPPRESS_BANNER=1 OPENHANDS_CONVERSATIONS_DIR={{MODEL_SESSION_DIR}} LLM_MODEL=$(shell_quote "$raw") LLM_REASONING_EFFORT=$(shell_quote "$effort") openhands --headless --always-approve --exit-without-confirmation --override-with-envs -t {{PROMPT}}"
                    add_model "$key" "OpenHands" "$raw" "$efforts" "$effort" "$command" "rm -rf -- {{MODEL_SESSION_DIR}}"
                    ;;
            esac
        done
    done
}

print_model_details() {
    local index="$1" provider="${MODEL_PROVIDERS[$1]}"
    printf '  %s\n' "${MODEL_CODE_NAMES[$index]}"
    if [[ -n "${MODEL_EFFORT_OPTIONS[$index]}" ]]; then
        if [[ "$provider" == "Claude" ]]; then
            printf '    effort wg klienta: %s' "${MODEL_EFFORT_OPTIONS[$index]}"
        else
            printf '    effort: %s' "${MODEL_EFFORT_OPTIONS[$index]}"
        fi
        if [[ -n "${MODEL_DEFAULT_EFFORTS[$index]}" ]]; then
            printf ' (domyślny: %s)' "${MODEL_DEFAULT_EFFORTS[$index]}"
        fi
        printf '\n'
    elif [[ "$provider" == "OpenHands" && -n "${MODEL_DEFAULT_EFFORTS[$index]}" ]]; then
        printf '    skonfigurowany effort: %s\n' "${MODEL_DEFAULT_EFFORTS[$index]}"
    fi
}

print_grouped_models() {
    local provider index found base previous_base effort
    printf '\n%sWykryte modele:%s\n' "$BOLD" "$RESET"
    for provider in Codex Claude OpenHands; do
        printf '\n%s%s:%s\n' "$BOLD" "$provider" "$RESET"
        found=false
        previous_base=""
        for ((index = 0; index < ${#MODEL_KEYS[@]}; index++)); do
            [[ "${MODEL_PROVIDERS[$index]}" == "$provider" ]] || continue
            found=true
            base="${MODEL_BASE_NAMES[$index]}"
            if [[ "$base" != "$previous_base" ]]; then
                printf '  %s\n' "$base"
                previous_base="$base"
            fi
            effort="${MODEL_DEFAULT_EFFORTS[$index]:-(bez effortu)}"
            printf '    - %s -> %s\n' "$effort" "${MODEL_KEYS[$index]}"
        done
        [[ "$found" == "true" ]] || printf '  (nie wykryto modeli)\n'
    done
}

discover_ai_tools_and_models() {
    local tool_name
    local -a available_tools=() unavailable_tools=()
    for tool_name in codex claude openhands; do
        if command -v "$tool_name" >/dev/null 2>&1; then
            available_tools+=("$tool_name")
        else
            unavailable_tools+=("$tool_name")
        fi
    done

    printf '\n%sDostępne narzędzia AI:%s\n' "$GREEN" "$RESET"
    for tool_name in "${available_tools[@]}"; do
        printf '%s  ✓ %s%s\n' "$GREEN" "$tool_name" "$RESET"
    done
    if ((${#unavailable_tools[@]} > 0 && ${#available_tools[@]} > 0)); then
        printf 'Niewykryte narzędzia opcjonalne: %s\n' "${unavailable_tools[*]}"
    fi
    if ((${#available_tools[@]} == 0)); then
        printf '%sNie wykryto żadnego z narzędzi: codex, claude, openhands. Zainstaluj przynajmniej jedno z nich.%s\n' "$RED" "$RESET"
        return 1
    fi
    wait_to_continue || return 1

    command -v codex >/dev/null 2>&1 && discover_codex_models
    command -v claude >/dev/null 2>&1 && discover_claude_models
    command -v openhands >/dev/null 2>&1 && discover_openhands_models
    load_configured_available_models

    edit_available_models || return 1
    configure_available_model_efforts || return 1
    build_model_variants

    if ((${#MODEL_KEYS[@]} == 0)); then
        printf '%sNie udało się wykryć żadnego modelu w lokalnych cache ani ustawieniach.%s\n' "$YELLOW" "$RESET"
    else
        print_grouped_models
    fi
    wait_to_continue || return 1
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

select_model_order() {
    local policy="$1" explanation="$2" require_model="$3"
    local -n output_ref="$4"
    local answer index provider base effort choose_more selected_index display_name
    local -a selected=() type_options=() base_options=() variant_indexes=()
    local -A seen=() base_seen=()

    printf '\n%sKonfiguracja %s%s\n%s\n' "$BOLD" "$policy" "$RESET" "$explanation"
    if ((${#MODEL_KEYS[@]} == 0)); then
        printf '%sBrak wykrytych modeli — lista pozostanie pusta.%s\n' "$YELLOW" "$RESET"
        [[ "$require_model" == "false" ]] || return 1
        output_ref=()
        return 0
    fi
    while true; do
        type_options=()
        for provider in Codex Claude OpenHands Other; do
            for ((index = 0; index < ${#MODEL_KEYS[@]}; index++)); do
                [[ "${MODEL_PROVIDERS[$index]}" == "$provider" && -z "${seen[$index]:-}" ]] || continue
                type_options+=("$provider")
                break
            done
        done
        if ((${#type_options[@]} == 0)); then
            break
        fi

        printf '\n%sWybór %d dla %s — typ modelu:%s\n' "$BOLD" "$(( ${#selected[@]} + 1 ))" "$policy" "$RESET"
        for ((index = 0; index < ${#type_options[@]}; index++)); do
            printf '  %d. %s\n' "$((index + 1))" "${type_options[$index]}"
        done
        if ((${#selected[@]} == 0)) && [[ "$require_model" == "false" ]]; then
            printf '  0. Brak modeli dla tej polityki\n'
        fi
        while true; do
            printf 'Wybierz typ: '
            IFS= read -r answer || return 1
            answer="$(trim "$answer")"
            if [[ "$answer" == "0" && ${#selected[@]} -eq 0 && "$require_model" == "false" ]]; then
                output_ref=()
                return 0
            fi
            [[ "$answer" =~ ^[0-9]+$ ]] && index=$((10#$answer - 1)) || index=-1
            ((index >= 0 && index < ${#type_options[@]})) && break
            printf '%sWybierz numer dostępnego typu.%s\n' "$RED" "$RESET"
        done
        provider="${type_options[$index]}"

        base_options=(); base_seen=()
        for ((index = 0; index < ${#MODEL_KEYS[@]}; index++)); do
            [[ "${MODEL_PROVIDERS[$index]}" == "$provider" && -z "${seen[$index]:-}" ]] || continue
            base="${MODEL_BASE_NAMES[$index]}"
            [[ -z "${base_seen[$base]:-}" ]] || continue
            base_seen[$base]=1
            base_options+=("$base")
        done
        printf '\n%sModel %s:%s\n' "$BOLD" "$provider" "$RESET"
        for ((index = 0; index < ${#base_options[@]}; index++)); do
            display_name="${base_options[$index]}"
            display_name="${display_name#codex-}"; display_name="${display_name#claude-}"; display_name="${display_name#openhands-}"
            printf '  %d. %s\n' "$((index + 1))" "$display_name"
        done
        while true; do
            printf 'Wybierz model: '
            IFS= read -r answer || return 1
            [[ "$answer" =~ ^[0-9]+$ ]] && index=$((10#$answer - 1)) || index=-1
            ((index >= 0 && index < ${#base_options[@]})) && break
            printf '%sWybierz numer dostępnego modelu.%s\n' "$RED" "$RESET"
        done
        base="${base_options[$index]}"

        variant_indexes=()
        printf '\n%sEffort dla %s:%s\n' "$BOLD" "$base" "$RESET"
        for ((index = 0; index < ${#MODEL_KEYS[@]}; index++)); do
            [[ "${MODEL_BASE_NAMES[$index]}" == "$base" && -z "${seen[$index]:-}" ]] || continue
            variant_indexes+=("$index")
            effort="${MODEL_DEFAULT_EFFORTS[$index]:-(bez effortu)}"
            printf '  %d. %s\n' "${#variant_indexes[@]}" "$effort"
        done
        while true; do
            printf 'Wybierz effort: '
            IFS= read -r answer || return 1
            [[ "$answer" =~ ^[0-9]+$ ]] && index=$((10#$answer - 1)) || index=-1
            ((index >= 0 && index < ${#variant_indexes[@]})) && break
            printf '%sWybierz numer dostępnego effortu.%s\n' "$RED" "$RESET"
        done
        selected_index="${variant_indexes[$index]}"
        seen[$selected_index]=1
        selected+=("${MODEL_KEYS[$selected_index]}")
        printf '%sDodano %s jako wybór nr %d.%s\n' "$GREEN" "${MODEL_KEYS[$selected_index]}" "${#selected[@]}" "$RESET"

        choose_more="$(prompt_boolean "Czy dodać kolejny model jako fallback?" false)" || return 1
        [[ "$choose_more" == "true" ]] || break
    done
    output_ref=("${selected[@]}")
}

prompt_positive_integer() {
    local label="$1" default_value="$2" minimum="$3" answer
    while true; do
        printf '%s [%s]: ' "$label" "$default_value" >&2
        IFS= read -r answer || return 1
        answer="$(trim "$answer")"
        answer="${answer:-$default_value}"
        if [[ "$answer" =~ ^[0-9]+$ ]]; then
            answer=$((10#$answer))
        fi
        if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= minimum)); then
            printf '%s' "$answer"
            return 0
        fi
        printf '%sWymagana jest liczba całkowita nie mniejsza niż %d.%s\n' "$RED" "$minimum" "$RESET" >&2
    done
}

prompt_workdir() {
    local default_value="$1" answer resolved
    while true; do
        printf 'workdir [%s]: ' "$default_value" >&2
        IFS= read -r answer || return 1
        answer="$(trim "$answer")"
        answer="${answer:-$default_value}"
        resolved="$(realpath -e -- "$answer" 2>/dev/null || true)"
        if [[ -n "$resolved" && -d "$resolved" ]] && git -C "$resolved" rev-parse --git-dir >/dev/null 2>&1; then
            printf '%s' "$resolved"
            return 0
        fi
        printf '%sPodaj istniejący katalog będący repozytorium Git.%s\n' "$RED" "$RESET" >&2
    done
}

prompt_boolean() {
    local label="$1" default_value="$2" hint answer
    [[ "$default_value" == "true" ]] && hint="T/n" || hint="t/N"
    while true; do
        printf '%s [%s]: ' "$label" "$hint" >&2
        IFS= read -r answer || return 1
        answer="$(trim "$answer")"
        case "${answer,,}" in
            "") printf '%s' "$default_value"; return 0 ;;
            t | tak | y | yes) printf 'true'; return 0 ;;
            n | nie | no) printf 'false'; return 0 ;;
            *) printf '%sWpisz „tak” albo „nie”.%s\n' "$RED" "$RESET" >&2 ;;
        esac
    done
}

prompt_nonempty() {
    local label="$1" default_value="$2" forbid_whitespace="${3:-false}" answer
    while true; do
        printf '%s [%s]: ' "$label" "$default_value" >&2
        IFS= read -r answer || return 1
        answer="$(trim "$answer")"
        answer="${answer:-$default_value}"
        if [[ -n "$answer" && ! "$answer" =~ [[:cntrl:]] ]] \
            && { [[ "$forbid_whitespace" != "true" ]] || [[ ! "$answer" =~ [[:space:]] ]]; }; then
            printf '%s' "$answer"
            return 0
        fi
        printf '%sWartość nie może być pusta ani zawierać niedozwolonych znaków.%s\n' "$RED" "$RESET" >&2
    done
}

prompt_branch_prefix() {
    local default_value="$1" answer
    while true; do
        printf 'default_branch_prefix — prefiks dopisywany do samego numeru [%s]: ' "$default_value" >&2
        IFS= read -r answer || return 1
        answer="$(trim "$answer")"
        answer="${answer:-$default_value}"
        if [[ ! "$answer" =~ [[:space:][:cntrl:]] ]]; then
            printf '%s' "$answer"
            return 0
        fi
        printf '%sPrefiks nie może zawierać białych ani kontrolnych znaków.%s\n' "$RED" "$RESET" >&2
    done
}

config_integer_default() {
    local jq_path="$1" fallback="$2" minimum="$3" value
    value="$(jq -r "$jq_path // empty" "$CONFIG_FILE" 2>/dev/null || true)"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        value=$((10#$value))
    fi
    if [[ ! "$value" =~ ^[0-9]+$ ]] || ((value < minimum)); then
        value="$fallback"
    fi
    printf '%s' "$value"
}

config_boolean_default() {
    local value
    value="$(jq -r '.push_after_merge // false' "$CONFIG_FILE" 2>/dev/null || true)"
    [[ "$value" == "true" || "$value" == "false" ]] || value=false
    printf '%s' "$value"
}

array_to_json() {
    if (($# == 0)); then
        printf '[]'
    else
        printf '%s\n' "$@" | jq -R . | jq -s -c .
    fi
}

build_commands_json() {
    local kind="$1" result='{}' index value
    for ((index = 0; index < ${#MODEL_KEYS[@]}; index++)); do
        if [[ "$kind" == "start" ]]; then
            value="${MODEL_COMMANDS[$index]}"
        else
            value="${MODEL_CLOSE_COMMANDS[$index]}"
        fi
        result="$(jq -c --arg key "${MODEL_KEYS[$index]}" --arg value "$value" '.[$key]=$value' <<<"$result")"
    done
    printf '%s' "$result"
}

build_available_models_json() {
    local result='{"codex-like":{},"claude-like":{},"openhands-vllm-like":{},"other":{}}'
    local index group name efforts efforts_json
    local -a parts=()
    for ((index = 0; index < ${#AVAILABLE_MODEL_NAMES[@]}; index++)); do
        group="${AVAILABLE_MODEL_GROUPS[$index]}"
        name="${AVAILABLE_MODEL_NAMES[$index]}"
        efforts="${AVAILABLE_MODEL_EFFORTS[$index]}"
        parts=()
        [[ -z "$efforts" ]] || IFS=',' read -r -a parts <<<"$efforts"
        efforts_json="$(array_to_json "${parts[@]}")"
        result="$(jq -c --arg group "$group" --arg name "$name" --argjson efforts "$efforts_json" '.[$group][$name]=$efforts' <<<"$result")"
    done
    printf '%s' "$result"
}

configure_models_and_settings() {
    local require_simple require_all key answer attempts timeout_default attempts_default
    local default_workdir workdir fetch_interval ui_refresh cooldown min_time_between_merges default_model_timeout default_model_attempts
    local branch_prefix push_after merge_without_conflicts_default git_user_name git_user_email show_titles model_logs_retention
    local simple_json all_json title_json ask_json autorepair_json models_json='{}' commands_json close_commands_json available_models_json selected_json
    local config_dir temp_file commands_relative commands_file commands_parent commands_temp
    local main_config_file branches_relative branches_file effective_config
    local -a simple_models=() all_models=() title_models=() ask_models=() autorepair_models=() selected_models=()
    local -A selected_seen=()

    main_config_file="$CONFIG_FILE"
    [[ -r "$main_config_file" ]] || { printf '%sNie można odczytać konfiguracji: %s%s\n' "$RED" "$main_config_file" "$RESET"; return 1; }
    jq -e . "$main_config_file" >/dev/null 2>&1 || { printf '%sKonfiguracja nie jest poprawnym JSON-em: %s%s\n' "$RED" "$main_config_file" "$RESET"; return 1; }
    config_dir="$(cd -- "$(dirname -- "$main_config_file")" && pwd -P)"
    commands_relative="$(jq -r '.models_config_file // "models_config.json"' "$main_config_file")"
    branches_relative="$(jq -r '.branches_config_file // "branches_config.json"' "$main_config_file")"
    is_safe_relative_path "$commands_relative" && is_safe_relative_path "$branches_relative" || {
        printf '%sNiepoprawna ścieżka models_config_file lub branches_config_file.%s\n' "$RED" "$RESET"
        return 1
    }
    commands_file="$config_dir/$commands_relative"
    branches_file="$config_dir/$branches_relative"
    [[ -r "$commands_file" && -r "$branches_file" ]] || {
        printf '%sNie można odczytać models_config.json lub branches_config.json.%s\n' "$RED" "$RESET"
        return 1
    }
    effective_config="$(mktemp "${TMPDIR:-/tmp}/automerger-configurator.XXXXXX")" || return 1
    jq -n --slurpfile main "$main_config_file" --slurpfile models "$commands_file" --slurpfile branches "$branches_file" '
        $main[0] + {
            models:($models[0].models // {}),
            tracked_branches:($branches[0].tracked_branches // {}),
            continuous_nudges:($branches[0].continuous_nudges // {}),
            ui_refresh_ms:$main[0].ui_refresh_ms,
            merge_cooldown_time_m_default:$main[0].merge_cooldown_time_m_default,
            model_max_working_time_s_default:$main[0].model_max_working_time_s_default
        }
    ' >"$effective_config" || { rm -f -- "$effective_config"; return 1; }
    local CONFIG_FILE="$effective_config"
    require_simple="$(jq -r '[.tracked_branches[]?.policy] | any(. == "ai_automerge_simple")' "$CONFIG_FILE")"
    require_all="$(jq -r '[.tracked_branches[]?.policy] | any(. == "ai_automerge_all")' "$CONFIG_FILE")"

    select_model_order "automerge_simple_models" \
        "Modele rozwiązują wyłącznie konflikty w faktycznie konfliktujących plikach pasujących do autoresolve_files_list. Pierwszy model jest podstawowy, kolejne są fallbackami." \
        "$require_simple" simple_models || return 1
    select_model_order "automerge_all_models" \
        "Modele mogą rozwiązywać wszystkie faktycznie konfliktujące pliki. Ta polityka ma szerszy zakres, dlatego warto umieścić najpewniejszy model jako pierwszy." \
        "$require_all" all_models || return 1
    select_model_order "title_maker_models" \
        "Modele przygotowują krótki tytuł brancha na podstawie zmian brancha. Każdy branch używa tej samej kolejności fallbacków, a równolegle działają najwyżej trzy title makery." \
        "false" title_models || return 1
    select_model_order "ask_models" \
        "Modele odpowiadają na pytania o stan automergera, konfigurację i ostatnie logi. Pierwszy model jest podstawowy, kolejne są fallbackami." \
        "false" ask_models || return 1
    select_model_order "autorepair_models" \
        "Modele analizują logi i mogą naprawić kopię automerger.sh. Każda zastosowana poprawka ma kopię bezpieczeństwa." \
        "false" autorepair_models || return 1

    for key in "${simple_models[@]}" "${all_models[@]}" "${title_models[@]}" "${ask_models[@]}" "${autorepair_models[@]}"; do
        [[ -n "$key" && -z "${selected_seen[$key]:-}" ]] || continue
        selected_seen[$key]=1
        selected_models+=("$key")
    done
    if ((${#selected_models[@]} > 0)); then
        printf '\n%sLimit czasu modeli%s\n' "$BOLD" "$RESET"
        printf 'max_working_time to limit jednej próby, a max_attempts to łączna liczba prób przed przejściem do fallbacku.\n'
        for key in "${selected_models[@]}"; do
            timeout_default="$(jq -r --arg key "$key" '.models[$key].max_working_time // .model_max_working_time_s_default // 600' "$CONFIG_FILE")"
            attempts_default="$(jq -r --arg key "$key" '.models[$key].max_attempts // .model_max_attempts_default // 2' "$CONFIG_FILE")"
            models_json="$(jq -c --arg key "$key" --argjson timeout "$timeout_default" --argjson attempts "$attempts_default" \
                '.[$key]={max_working_time:$timeout,max_attempts:$attempts}' <<<"$models_json")"
        done
        for key in "${simple_models[@]}"; do
            timeout_default="$(jq -r --arg key "$key" '
                .models[$key].ai_automerge_simple.max_working_time
                // .models[$key].max_working_time // .model_max_working_time_s_default // 600
            ' "$CONFIG_FILE")"
            attempts_default="$(jq -r --arg key "$key" '
                .models[$key].ai_automerge_simple.max_attempts
                // .models[$key].max_attempts // .model_max_attempts_default // 2
            ' "$CONFIG_FILE")"
            answer="$(prompt_positive_integer "max_working_time dla $key (ai_automerge_simple)" "$timeout_default" 1)" || return 1
            attempts="$(prompt_positive_integer "max_attempts dla $key (ai_automerge_simple)" "$attempts_default" 1)" || return 1
            models_json="$(jq -c --arg key "$key" --argjson timeout "$answer" --argjson attempts "$attempts" '
                .[$key].ai_automerge_simple={max_working_time:$timeout,max_attempts:$attempts}
            ' <<<"$models_json")"
        done
        for key in "${all_models[@]}"; do
            timeout_default="$(jq -r --arg key "$key" '
                .models[$key].ai_automerge_all.max_working_time
                // .models[$key].max_working_time // .model_max_working_time_s_default // 600
            ' "$CONFIG_FILE")"
            attempts_default="$(jq -r --arg key "$key" '
                .models[$key].ai_automerge_all.max_attempts
                // .models[$key].max_attempts // .model_max_attempts_default // 2
            ' "$CONFIG_FILE")"
            answer="$(prompt_positive_integer "max_working_time dla $key (ai_automerge_all)" "$timeout_default" 1)" || return 1
            attempts="$(prompt_positive_integer "max_attempts dla $key (ai_automerge_all)" "$attempts_default" 1)" || return 1
            models_json="$(jq -c --arg key "$key" --argjson timeout "$answer" --argjson attempts "$attempts" '
                .[$key].ai_automerge_all={max_working_time:$timeout,max_attempts:$attempts}
            ' <<<"$models_json")"
        done
        for key in "${title_models[@]}"; do
            timeout_default="$(jq -r --arg key "$key" '
                .models[$key].title_maker.max_working_time
                // .models[$key].max_working_time // .model_max_working_time_s_default // 600
            ' "$CONFIG_FILE")"
            attempts_default="$(jq -r --arg key "$key" '
                .models[$key].title_maker.max_attempts
                // .models[$key].max_attempts // .model_max_attempts_default // 2
            ' "$CONFIG_FILE")"
            answer="$(prompt_positive_integer "max_working_time dla $key (title maker)" "$timeout_default" 1)" || return 1
            attempts="$(prompt_positive_integer "max_attempts dla $key (title maker)" "$attempts_default" 1)" || return 1
            models_json="$(jq -c --arg key "$key" --argjson timeout "$answer" --argjson attempts "$attempts" '
                .[$key].title_maker={max_working_time:$timeout,max_attempts:$attempts}
            ' <<<"$models_json")"
        done
        for key in "${ask_models[@]}"; do
            timeout_default="$(jq -r --arg key "$key" '.models[$key].ask.max_working_time // .models[$key].max_working_time // .model_max_working_time_s_default // 600' "$CONFIG_FILE")"
            attempts_default="$(jq -r --arg key "$key" '.models[$key].ask.max_attempts // .models[$key].max_attempts // .model_max_attempts_default // 2' "$CONFIG_FILE")"
            answer="$(prompt_positive_integer "max_working_time dla $key (ask)" "$timeout_default" 1)" || return 1
            attempts="$(prompt_positive_integer "max_attempts dla $key (ask)" "$attempts_default" 1)" || return 1
            models_json="$(jq -c --arg key "$key" --argjson timeout "$answer" --argjson attempts "$attempts" '.[$key].ask={max_working_time:$timeout,max_attempts:$attempts}' <<<"$models_json")"
        done
        for key in "${autorepair_models[@]}"; do
            timeout_default="$(jq -r --arg key "$key" '.models[$key].autorepair.max_working_time // .models[$key].max_working_time // .model_max_working_time_s_default // 600' "$CONFIG_FILE")"
            attempts_default="$(jq -r --arg key "$key" '.models[$key].autorepair.max_attempts // .models[$key].max_attempts // .model_max_attempts_default // 2' "$CONFIG_FILE")"
            answer="$(prompt_positive_integer "max_working_time dla $key (autorepair)" "$timeout_default" 1)" || return 1
            attempts="$(prompt_positive_integer "max_attempts dla $key (autorepair)" "$attempts_default" 1)" || return 1
            models_json="$(jq -c --arg key "$key" --argjson timeout "$answer" --argjson attempts "$attempts" '.[$key].autorepair={max_working_time:$timeout,max_attempts:$attempts}' <<<"$models_json")"
        done
    fi

    printf '\n%sUstawienia projektu%s\n' "$BOLD" "$RESET"
    default_workdir="$(jq -r 'if (.workdir | type) == "string" then .workdir else empty end' "$CONFIG_FILE")"
    [[ -n "$default_workdir" ]] || default_workdir="$PWD"
    workdir="$(prompt_workdir "$default_workdir")" || return 1
    fetch_interval="$(prompt_positive_integer "fetch_interval_seconds — odstęp między fetchami" "$(config_integer_default '.fetch_interval_seconds' 30 1)" 1)" || return 1
    ui_refresh="$(prompt_positive_integer "ui_refresh_ms — odświeżanie UI w ms" "$(config_integer_default '.ui_refresh_ms // .ui_refresh_ms' 750 1)" 1)" || return 1
    cooldown="$(prompt_positive_integer "merge_cooldown_time_m_default — domyślny cooldown w minutach" "$(config_integer_default '.merge_cooldown_time_m_default // .merge_cooldown_time_m_default' 60 0)" 0)" || return 1
    min_time_between_merges="$(prompt_positive_integer "min_time_between_merges_m — minimalna przerwa między udanymi merge różnych branchy w minutach" "$(config_integer_default '.min_time_between_merges_m' 5 0)" 0)" || return 1
    default_model_timeout="$(prompt_positive_integer "model_max_working_time_s_default — domyślny timeout modelu w sekundach" "$(config_integer_default '.model_max_working_time_s_default // .model_max_working_time_s_default' 600 1)" 1)" || return 1
    default_model_attempts="$(prompt_positive_integer "model_max_attempts_default — domyślna liczba prób modelu" "$(config_integer_default '.model_max_attempts_default' 2 1)" 1)" || return 1
    branch_prefix="$(prompt_branch_prefix "$(jq -r '.default_branch_prefix // ""' "$CONFIG_FILE")")" || return 1
    push_after="$(prompt_boolean "push_after_merge — wysyłać udane merge do remote?" "$(config_boolean_default)")" || return 1
    merge_without_conflicts_default="$(prompt_boolean "merge_without_conflicts_default — automatycznie merge'ować branche bez konfliktów?" "$(jq -r '.merge_without_conflicts_default // false' "$CONFIG_FILE")")" || return 1
    git_user_name="$(prompt_nonempty "git_user_name — autor commitów automergera" "$(jq -r '.git_user_name // "Automerger"' "$CONFIG_FILE")")" || return 1
    git_user_email="$(prompt_nonempty "git_user_email — e-mail autora commitów" "$(jq -r '.git_user_email // "automerger@localhost"' "$CONFIG_FILE")" true)" || return 1
    show_titles="$(prompt_boolean "show_titles_in_main_view — pokazywać tytuły w widoku głównym?" "$(jq -r '.show_titles_in_main_view // false' "$CONFIG_FILE")")" || return 1
    model_logs_retention="$(prompt_positive_integer "model_logs_retention_days — ile dni przechowywać logi błędów modeli" "$(config_integer_default '.model_logs_retention_days' 30 1)" 1)" || return 1

    simple_json="$(array_to_json "${simple_models[@]}")"
    all_json="$(array_to_json "${all_models[@]}")"
    title_json="$(array_to_json "${title_models[@]}")"
    ask_json="$(array_to_json "${ask_models[@]}")"
    autorepair_json="$(array_to_json "${autorepair_models[@]}")"
    commands_json="$(build_commands_json start)"
    close_commands_json="$(build_commands_json close)"
    available_models_json="$(build_available_models_json)"
    config_dir="$(cd -- "$(dirname -- "$main_config_file")" && pwd -P)"
    is_safe_relative_path "$commands_relative" \
        || { printf '%sNiepoprawna ścieżka models_config_file: %s%s\n' "$RED" "$commands_relative" "$RESET"; return 1; }
    commands_file="$config_dir/$commands_relative"
    [[ -d "$(dirname -- "$commands_file")" ]] \
        || { printf '%sKatalog dla models_config_file nie istnieje: %s%s\n' "$RED" "$(dirname -- "$commands_file")" "$RESET"; return 1; }
    commands_parent="$(realpath -e -- "$(dirname -- "$commands_file")")" \
        || { printf '%sNie można rozwiązać katalogu models_config_file.%s\n' "$RED" "$RESET"; return 1; }
    [[ "$commands_parent" == "$config_dir" || "$commands_parent" == "$config_dir"/* ]] \
        || { printf '%smodels_config_file nie może wychodzić poza katalog config.json przez symlink.%s\n' "$RED" "$RESET"; return 1; }
    [[ "$(realpath -m -- "$commands_file")" != "$(realpath -m -- "$main_config_file")" ]] \
        || { printf '%smodels_config_file nie może wskazywać na główny config.json.%s\n' "$RED" "$RESET"; return 1; }
    if [[ -f "$commands_file" ]] && jq -e '
        (.model_commands | type == "object") and (.model_close_commands | type == "object")
    ' "$commands_file" >/dev/null 2>&1; then
        commands_json="$(jq -cn \
            --argjson existing "$(jq -c '.model_commands' "$commands_file")" \
            --argjson detected "$commands_json" '$existing + $detected')"
        close_commands_json="$(jq -cn \
            --argjson existing "$(jq -c '.model_close_commands' "$commands_file")" \
            --argjson detected "$close_commands_json" '$existing + $detected')"
    fi
    temp_file="$(mktemp "$config_dir/.configurator.XXXXXX")" || { rm -f -- "$effective_config"; return 1; }
    commands_temp="$(mktemp "$(dirname -- "$commands_file")/.model-commands.XXXXXX")" || {
        rm -f -- "$temp_file"
        return 1
    }
    if ! jq -n --argjson commands "$commands_json" --argjson close_commands "$close_commands_json" --argjson models "$models_json" --argjson available_models "$available_models_json" '
        {available_models:$available_models,model_commands:$commands,model_close_commands:$close_commands,models:$models}
    ' >"$commands_temp"; then
        rm -f -- "$temp_file" "$commands_temp"
        return 1
    fi
    if ! jq \
        --arg workdir "$workdir" \
        --argjson fetch "$fetch_interval" \
        --argjson ui "$ui_refresh" \
        --argjson cooldown "$cooldown" \
        --argjson min_time_between_merges "$min_time_between_merges" \
        --argjson default_model_timeout "$default_model_timeout" \
        --argjson default_model_attempts "$default_model_attempts" \
        --argjson push "$push_after" \
        --argjson merge_without_conflicts_default "$merge_without_conflicts_default" \
        --arg git_user_name "$git_user_name" \
        --arg git_user_email "$git_user_email" \
        --argjson show_titles "$show_titles" \
        --argjson model_logs_retention "$model_logs_retention" \
        --argjson simple "$simple_json" \
        --argjson all "$all_json" \
        --argjson title "$title_json" \
        --argjson ask "$ask_json" \
        --argjson autorepair "$autorepair_json" \
        --arg branch_prefix "$branch_prefix" \
        --arg models_config_file "$commands_relative" \
        --argjson commands "$commands_json" \
        --argjson close_commands "$close_commands_json" '
            .workdir=$workdir
            | .fetch_interval_seconds=$fetch
            | .ui_refresh_ms=$ui
            | .merge_cooldown_time_m_default=$cooldown
            | .min_time_between_merges_m=$min_time_between_merges
            | .model_max_working_time_s_default=$default_model_timeout
            | .model_max_attempts_default=$default_model_attempts
            | .default_branch_prefix=$branch_prefix
            | .push_after_merge=$push
            | .merge_without_conflicts_default=$merge_without_conflicts_default
            | .git_user_name=$git_user_name
            | .git_user_email=$git_user_email
            | .show_titles_in_main_view=$show_titles
            | .model_logs_retention_days=$model_logs_retention
            | .automerge_simple_models=$simple
            | .automerge_all_models=$all
            | .title_maker_models=$title
            | .ask_models=$ask
            | .autorepair_models=$autorepair
            | .models_config_file=$models_config_file
            | del(.models,.tracked_branches,.continuous_nudges,.model_commands,.model_close_commands)
        ' "$main_config_file" >"$temp_file"; then
        rm -f -- "$temp_file" "$commands_temp" "$effective_config"
        return 1
    fi
    chmod 600 -- "$temp_file" "$commands_temp"
    mv -f -- "$commands_temp" "$commands_file"
    mv -f -- "$temp_file" "$main_config_file"
    rm -f -- "$effective_config"
}

prepare_github_token() {
    local token_preparer="$SCRIPT_DIR/prepare_token.sh"
    printf '\n%sKonfiguracja tokenu GitHub%s\n\n' "$BOLD" "$RESET"
    printf 'Część eksperymentalnych funkcji PR (labele oraz filtrowanie poke) wymaga tokenu GitHub.\n'
    printf 'Token nie zostanie zapisany jawnie: za chwilę uruchomi się szyfrator AES-256.\n'
    printf 'Podasz token oraz własny klucz szyfrujący; klucz pozostaje wyłącznie po Twojej stronie.\n'
    printf 'Automerger odszyfruje token dopiero po komendzie decrypt/activate_token i będzie trzymał go tylko w RAM-ie bieżącej sesji.\n'
    printf 'Narzędzia szyfratora (jq, openssl, mktemp, realpath) zostały sprawdzone w raporcie środowiska.\n'
    [[ -f "$token_preparer" ]] || {
        printf '%sBŁĄD: nie znaleziono szyfratora tokenu: %s%s\n' "$RED" "$token_preparer" "$RESET" >&2
        return 1
    }
    wait_to_continue || return 1
    if ! bash "$token_preparer" --config "$CONFIG_FILE"; then
        printf '%sNie udało się przygotować zaszyfrowanego tokenu. Konfiguracja modeli została zapisana, ale token nie jest gotowy.%s\n' \
            "$RED" "$RESET" >&2
        return 1
    fi
    printf '%sToken został zaszyfrowany i zapisany w konfiguracji.%s\n' "$GREEN" "$RESET"
}

main() {
    if ! check_environment; then
        wait_for_enter
        return 1
    fi
    if ! discover_ai_tools_and_models; then
        wait_for_enter
        return 1
    fi
    if ! configure_models_and_settings; then
        printf '\n%sKonfiguracja nie została zapisana.%s\n' "$RED" "$RESET"
        wait_for_enter
        return 1
    fi
    printf '\n%sKonfiguracja została zakończona i zapisana w:%s %s\n' "$GREEN" "$RESET" "$CONFIG_FILE"
    if ! prepare_github_token; then
        wait_for_enter
        return 1
    fi
    printf '%sPrzejrzyj i uzupełnij ręcznie autoresolve_files_list oraz pozostałe ustawienia zgodnie ze swoim projektem.%s\n' "$YELLOW" "$RESET"
    printf '\nPowodzenia! Niech merge’e będą spokojne, a konflikty jednoznaczne.\n'
    wait_for_enter
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
