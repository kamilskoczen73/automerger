#!/usr/bin/env bash
# Copyright (c) 2026 Andrzej Janczak
# SPDX-License-Identifier: MIT

set -uo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
CONFIG_FILE="${AUTOMERGER_CONFIG:-$SCRIPT_DIR/config.json}"
SOURCE_CONFIG_FILE=""
MODE="tui"
MODE_ARGUMENT=""

readonly POLICY_AI_ALL="ai_automerge_all"
readonly POLICY_AI_SIMPLE="ai_automerge_simple"
readonly POLICY_BASIC="basic_automerge"
readonly POLICY_MANUAL="manual"
readonly MAX_CONCURRENT_TITLE_MAKERS=3
readonly TITLE_RETRY_DELAY_SECONDS=60
readonly MODEL_CLOSE_TIMEOUT=30
readonly PR_DISCOVERY_TIMEOUT=15
readonly AI_SECURITY_FAILURE_EXIT=126
readonly COMMAND_OUTPUT_AUTO_CLOSE_SECONDS=60
readonly MERGE_SCHEDULER_INTERVAL_SECONDS=1
readonly INPUT_RENDER_QUIET_PERIOD_MS=100
readonly GITHUB_TOKEN_MARKER="AUTOMERGER_GITHUB_TOKEN_V1:"

WORKDIR=""
REMOTE=""
TARGET_BRANCH=""
FETCH_INTERVAL=30
UI_REFRESH_MS=750
UI_REFRESH_SECONDS="0.750"
PUSH_AFTER_MERGE=false
MIN_TIME_BETWEEN_MERGES_M=5
GIT_USER_NAME="Automerger"
GIT_USER_EMAIL="automerger@localhost"
PROMPT_FILE=""
MODEL_COMMANDS_FILE=""
BRANCHES_CONFIG_FILE=""
DEFAULT_BRANCH_PREFIX=""
BRANCHES_INFO_FILE=""
MODEL_LOG_DIR=""
MODEL_ERROR_LOG=""
MODEL_LOG_RETENTION_DAYS=30
STATE_DIR=""
STATE_FILE=""
STATE_LOCK=""
CONFIG_LOCK=""
BRANCHES_INFO_LOCK=""
MODEL_LOG_LOCK=""
STOP_FILE=""
QUEUE_FILE=""
CURRENT_FILE=""
WORKTREE_ROOT=""
WORKER_PID=""
ACTIVE_WORKTREE=""
ACTIVE_AI_SANDBOX=""
ACTIVE_MODEL_SESSION=""
LAST_LOG_ID=""
AI_SECURITY_VIOLATION=""
AI_ISOLATION_ERROR=""
AI_SANDBOX_CHECKED=false
MODEL_LOG_PREFIX="model AI"
MODEL_RUN_FAILURE_KIND=""
MODEL_RUN_EXIT_CODE=0
MODEL_CONFIG_CONTEXT=""
AI_VALIDATION_ERROR=""
TITLE_RESOLVER_PID=""
LAST_ERROR=""
INTERACTIVE_VALUE=""
TUI_ROWS=24
TUI_COLUMNS=80
TUI_INPUT_ROW=24
TUI_ACTIVE=false
TUI_STTY_STATE=""
ESCAPE_KEY=""
NOW_MS=0
RESET_REMOVED_REFS=0
NUDGE_BASE_SHA=""
NUDGE_REMOTE_SHA=""
NUDGE_WARNING=""
GITHUB_ACCESS_TOKEN=""
ASK_PID=""
ASK_OUTPUT_FILE=""
ASK_QUESTION=""
declare -a RENDERED_LINES=()

usage() {
    cat <<'EOF'
Użycie:
  automerger.sh [--config PLIK]
  automerger.sh [--config PLIK] --once
  automerger.sh [--config PLIK] --classify BRANCH
  automerger.sh [--config PLIK] --resolve-title BRANCH
  automerger.sh [--config PLIK] --ask "PYTANIE"
  automerger.sh [--config PLIK] --autorepair "OPIS PROBLEMU"
  automerger.sh [--config PLIK] --track "BRANCH[,BRANCH...] [POLITYKA] [COOLDOWN]"
  automerger.sh [--config PLIK] --untrack "BRANCH[,BRANCH...]"
  automerger.sh [--config PLIK] --validate-config

Tryby bez TUI służą również do automatycznych testów i diagnostyki.
EOF
}

die() {
    printf 'BŁĄD: %s\n' "$*" >&2
    exit 1
}

warn() {
    local log_id
    if [[ "$TUI_ACTIVE" == "true" && -n "$STATE_FILE" && -f "$STATE_FILE" ]]; then
        log_start "Błąd: $*"
        log_id="$LAST_LOG_ID"
        log_finish "$log_id" "FAIL"
    else
        printf 'OSTRZEŻENIE: %s\n' "$*" >&2
    fi
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

shell_quote() {
    printf '%q' "$1"
}

is_safe_relative_path() {
    local path="$1"
    local segment
    local -a path_segments=()
    [[ -n "$path" && "$path" != /* && "$path" != '~'* && "$path" != *//* && "$path" != */ ]] || return 1
    IFS='/' read -r -a path_segments <<<"$path"
    for segment in "${path_segments[@]}"; do
        [[ -n "$segment" && "$segment" != "." && "$segment" != ".." ]] || return 1
    done
}

milliseconds_to_seconds() {
    local milliseconds="$1"
    printf '%d.%03d' "$((milliseconds / 1000))" "$((milliseconds % 1000))"
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --config)
                (($# >= 2)) || die "Opcja --config wymaga ścieżki."
                CONFIG_FILE="$2"
                shift 2
                ;;
            --once | --validate-config)
                MODE="${1#--}"
                shift
                ;;
            --classify | --resolve-title | --track | --untrack | --ask | --autorepair)
                (($# >= 2)) || die "Opcja $1 wymaga argumentu."
                MODE="${1#--}"
                MODE_ARGUMENT="$2"
                shift 2
                ;;
            --help | -h)
                usage
                exit 0
                ;;
            *)
                die "Nieznana opcja: $1"
                ;;
        esac
    done
}

require_commands() {
    local command_name
    for command_name in git jq flock timeout mktemp sha256sum setsid base64 stat realpath find stty awk openssl; do
        command -v "$command_name" >/dev/null 2>&1 || die "Brak wymaganego polecenia: $command_name"
    done
}

ai_path_is_safe() {
    local path="$1"
    is_safe_relative_path "$path" && [[ ! "$path" =~ [[:cntrl:]] ]]
}

check_ai_sandbox_support() {
    local check_output
    if [[ "$AI_SANDBOX_CHECKED" == "true" ]]; then
        return 0
    fi
    if ! command -v bwrap >/dev/null 2>&1; then
        AI_ISOLATION_ERROR="Nie znaleziono programu bubblewrap (bwrap) w PATH."
        warn "$AI_ISOLATION_ERROR Operacje AI są zablokowane (fail-closed)."
        return 1
    fi
    if ! check_output="$(bwrap --unshare-user --unshare-pid --unshare-ipc --unshare-uts --disable-userns \
        --new-session --die-with-parent \
        --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind-try /lib64 /lib64 \
        --proc /proc --dev /dev --clearenv --setenv PATH /usr/bin:/bin -- /bin/true 2>&1)"; then
        AI_ISOLATION_ERROR="Test uruchomienia bubblewrap nie powiódł się: ${check_output:-brak komunikatu procesu}."
        warn "$AI_ISOLATION_ERROR Operacje AI są zablokowane (fail-closed)."
        return 1
    fi
    AI_SANDBOX_CHECKED=true
}

validate_config() {
    local required_field prompt_relative resolved_prompt autoresolve_pattern configured_workdir
    local commands_relative resolved_commands config_dir
    SOURCE_CONFIG_FILE="$CONFIG_FILE"
    [[ -r "$SOURCE_CONFIG_FILE" ]] || die "Nie można odczytać konfiguracji: $SOURCE_CONFIG_FILE"
    jq -e . "$SOURCE_CONFIG_FILE" >/dev/null 2>&1 || die "Plik konfiguracji nie jest poprawnym dokumentem JSON: $SOURCE_CONFIG_FILE"
    config_dir="$(cd -- "$(dirname -- "$SOURCE_CONFIG_FILE")" && pwd -P)"
    commands_relative="$(jq -r '.models_config_file // empty' "$SOURCE_CONFIG_FILE")"
    is_safe_relative_path "$commands_relative" \
        || die "models_config_file musi być bezpieczną ścieżką względną wobec katalogu config.json."
    resolved_commands="$(realpath -e -- "$config_dir/$commands_relative" 2>/dev/null)" \
        || die "Nie można odczytać models_config_file: $config_dir/$commands_relative"
    [[ "$resolved_commands" == "$config_dir"/* && -f "$resolved_commands" && -r "$resolved_commands" ]] \
        || die "models_config_file wskazuje poza katalog config.json albo nie jest czytelny."
    MODEL_COMMANDS_FILE="$resolved_commands"

    local branches_relative resolved_branches effective_config
    branches_relative="$(jq -r '.branches_config_file // empty' "$SOURCE_CONFIG_FILE")"
    is_safe_relative_path "$branches_relative" \
        || die "branches_config_file musi być bezpieczną ścieżką względną wobec katalogu config.json."
    resolved_branches="$(realpath -e -- "$config_dir/$branches_relative" 2>/dev/null)" \
        || die "Nie można odczytać branches_config_file: $config_dir/$branches_relative"
    [[ "$resolved_branches" == "$config_dir"/* && -f "$resolved_branches" && -r "$resolved_branches" ]] \
        || die "branches_config_file wskazuje poza katalog config.json albo nie jest czytelny."
    BRANCHES_CONFIG_FILE="$resolved_branches"
    BRANCHES_INFO_FILE="$BRANCHES_CONFIG_FILE"

    effective_config="$(mktemp "${TMPDIR:-/tmp}/automerger-effective-config.XXXXXX")" || die "Nie można przygotować konfiguracji roboczej."
    jq -n --slurpfile main "$SOURCE_CONFIG_FILE" --slurpfile models "$MODEL_COMMANDS_FILE" --slurpfile branches "$BRANCHES_CONFIG_FILE" '
        $main[0] + {
            models:($models[0].models // {}),
            tracked_branches:($branches[0].tracked_branches // {}),
            continuous_nudges:($branches[0].continuous_nudges // {}),
            models_config_file:$main[0].models_config_file,
            ui_refresh_ms:$main[0].ui_refresh_ms,
            merge_cooldown_time_m_default:$main[0].merge_cooldown_time_m_default,
            model_max_working_time_s_default:$main[0].model_max_working_time_s_default
        }
    ' >"$effective_config" || { rm -f -- "$effective_config"; die "Nie można połączyć plików konfiguracji."; }
    chmod 600 -- "$effective_config"
    CONFIG_FILE="$effective_config"
    for required_field in \
        version workdir remote target_branch fetch_interval_seconds ui_refresh_ms \
        merge_cooldown_time_m_default push_after_merge default_branch_prefix autoresolve_files_list \
        automerge_all_models automerge_simple_models title_maker_models models models_config_file \
        model_max_working_time_s_default model_max_attempts_default \
        prompt_file tracked_branches; do
        jq -e --arg field "$required_field" 'has($field)' "$CONFIG_FILE" >/dev/null \
            || die "Brak wymaganego pola '$required_field' w konfiguracji."
    done
    jq -e '
        (.available_models | type == "object")
        and (.available_models as $available | all(["codex-like", "claude-like", "openhands-vllm-like", "other"][];
            . as $group
            | ($available[$group] | type == "object")
            and ($available[$group] | all(to_entries[];
                (.key | type == "string" and length > 0)
                and (.value | type == "array" and all(.[]; type == "string" and length > 0))))))
        and (.model_commands | type == "object")
        and (.model_close_commands | type == "object")
        and (.model_commands | to_entries | all(.[];
            (.key | type == "string" and length > 0)
            and (.value | type == "string" and (gsub("[[:space:]]"; "") | length > 0))))
        and (.model_close_commands | to_entries | all(.[];
            (.key | type == "string" and length > 0)
            and (.value | type == "string" and (gsub("[[:space:]]"; "") | length > 0))))
    ' "$resolved_commands" >/dev/null \
        || die "Plik komend modeli ma niepoprawny format: $resolved_commands"
    jq -e --slurpfile command_profile "$MODEL_COMMANDS_FILE" '
        . as $root
        | $command_profile[0] as $commands
        | .version == 1
        and (.workdir | type == "string" and (gsub("[[:space:]]"; "") | length > 0))
        and (.remote | type == "string" and (gsub("[[:space:]]"; "") | length > 0))
        and (.target_branch | type == "string" and (gsub("[[:space:]]"; "") | length > 0))
        and (.fetch_interval_seconds | type == "number" and floor == . and . >= 1)
        and (.ui_refresh_ms | type == "number" and floor == . and . >= 1)
        and (.merge_cooldown_time_m_default | type == "number" and floor == . and . >= 0)
        and ((.min_time_between_merges_m == null) or (.min_time_between_merges_m | type == "number" and floor == . and . >= 0))
        and ((.merge_without_conflicts_default == null) or (.merge_without_conflicts_default | type == "boolean"))
        and (.model_max_working_time_s_default | type == "number" and floor == . and . >= 1)
        and (.model_max_attempts_default | type == "number" and floor == . and . >= 1)
        and (.push_after_merge | type == "boolean")
        and ((.show_titles_in_main_view == null) or (.show_titles_in_main_view | type == "boolean"))
        and (.github_access_token_encrypted as $github_token
            | (($github_token == null) or
            (($github_token | type) == "object"
                and $github_token.version == 1
                and $github_token.cipher == "aes-256-cbc"
                and $github_token.kdf == "pbkdf2"
                and $github_token.digest == "sha256"
                and ($github_token.iterations
                    | type == "number" and floor == . and . >= 100000)
                and ($github_token.ciphertext
                    | type == "string" and length > 0
                        and (test("[[:space:][:cntrl:]]") | not)))))
        and ((.model_logs_retention_days == null) or
            (.model_logs_retention_days | type == "number" and floor == . and . >= 1))
        and ((.continuous_nudges == null) or
            (.continuous_nudges | type == "object" and all(to_entries[];
                (.key | type == "string" and length > 0)
                and (.value | type == "object")
                and (.value.interval_minutes | type == "number" and floor == . and . >= 1)
                and (.value.next_run_at | type == "number" and floor == . and . >= 0)
                and ((.value.created_at == null) or
                    (.value.created_at | type == "number" and floor == . and . >= 0))
                and ((.value.last_run_at == null) or
                    (.value.last_run_at | type == "number" and floor == . and . >= 0))
            )))
        and ((.git_user_name == null) or (.git_user_name | type == "string"
            and (gsub("[[:space:]]"; "") | length > 0) and (test("[[:cntrl:]]") | not)))
        and ((.git_user_email == null) or (.git_user_email | type == "string"
            and (gsub("[[:space:]]"; "") | length > 0) and (test("[[:space:][:cntrl:]]") | not)))
        and (.default_branch_prefix | type == "string" and (test("[[:space:][:cntrl:]]") | not))
        and (.autoresolve_files_list | type == "array" and all(.[];
            type == "string"
            and (gsub("[[:space:]]"; "") | length > 0)
            and (test("[[:cntrl:]]") | not)
        ))
        and (.automerge_all_models | type == "array" and all(.[]; type == "string" and (gsub("[[:space:]]"; "") | length > 0)))
        and (.automerge_simple_models | type == "array" and all(.[]; type == "string" and (gsub("[[:space:]]"; "") | length > 0)))
        and (.title_maker_models | type == "array" and all(.[]; type == "string" and (gsub("[[:space:]]"; "") | length > 0)))
        and ((.ask_models == null) or (.ask_models | type == "array" and all(.[]; type == "string" and (gsub("[[:space:]]"; "") | length > 0))))
        and ((.autorepair_models == null) or (.autorepair_models | type == "array" and all(.[]; type == "string" and (gsub("[[:space:]]"; "") | length > 0))))
        and ((.automerge_all_models | length) == (.automerge_all_models | unique | length))
        and ((.automerge_simple_models | length) == (.automerge_simple_models | unique | length))
        and ((.title_maker_models | length) == (.title_maker_models | unique | length))
        and ((.ask_models // [] | length) == (.ask_models // [] | unique | length))
        and ((.autorepair_models // [] | length) == (.autorepair_models // [] | unique | length))
        and (.models | type == "object")
        and (.models_config_file | type == "string"
            and (gsub("[[:space:]]"; "") | length > 0)
            and (test("[[:cntrl:]]") | not))
        and (.prompt_file | type == "string"
            and (gsub("[[:space:]]"; "") | length > 0)
            and (test("[[:cntrl:]]") | not)
        )
        and (.tracked_branches | type == "object")
        and (.models | to_entries | all(.[];
            (.key | type == "string" and (gsub("[[:space:]]"; "") | length > 0))
            and (.value | type == "object")
            and ((.value.max_working_time == null) or (.value.max_working_time | type == "number" and floor == . and . >= 1))
            and ((.value.max_attempts == null) or (.value.max_attempts | type == "number" and floor == . and . >= 1))
            and (.value as $settings | all(["ai_automerge_simple", "ai_automerge_all", "title_maker", "ask", "autorepair"][];
                . as $context
                | ($settings[$context] == null)
                    or (($settings[$context] | type == "object")
                        and (($settings[$context].max_working_time == null)
                            or ($settings[$context].max_working_time | type == "number" and floor == . and . >= 1))
                        and (($settings[$context].max_attempts == null)
                            or ($settings[$context].max_attempts | type == "number" and floor == . and . >= 1)))
            ))
        ))
        and ([.automerge_all_models[], .automerge_simple_models[], .title_maker_models[], .ask_models[]?, .autorepair_models[]?] | all(.[];
            . as $model
            | ($model | type == "string")
            and (($root.models[$model] == null) or ($root.models[$model] | type == "object"))
            and ($commands.model_commands[$model] | type == "string" and (gsub("[[:space:]]"; "") | length > 0))
            and (($commands.model_close_commands[$model] == null)
                or ($commands.model_close_commands[$model] | type == "string" and (gsub("[[:space:]]"; "") | length > 0)))
        ))
        and (.tracked_branches | all(to_entries[];
            .value as $branch
            | ($branch.policy == "ai_automerge_all" or $branch.policy == "ai_automerge_simple" or $branch.policy == "basic_automerge" or $branch.policy == "manual")
            and (($branch.merge_cooldown_time == "auto") or ($branch.merge_cooldown_time | type == "number" and floor == . and . >= 0))
            and ($branch.tracked_at | type == "number" and floor == . and . >= 0)
            and (($branch.last_merged_at == null) or ($branch.last_merged_at | type == "number" and floor == . and . >= 0))
            and (($branch.last_merged_target_branch_sha == null) or ($branch.last_merged_target_branch_sha | type == "string"))
            and (($branch.last_merged_target_sha == null) or ($branch.last_merged_target_sha | type == "string"))
            and (($branch.merge_without_conflicts == null) or ($branch.merge_without_conflicts | type == "boolean"))
        ))
    ' "$CONFIG_FILE" >/dev/null || die "Konfiguracja ma niepoprawne albo puste wartości, typy lub zduplikowane modele."

    if jq -e '[.tracked_branches[].policy] | any(. == "ai_automerge_all")' "$CONFIG_FILE" >/dev/null \
        && [[ "$(jq '.automerge_all_models | length' "$CONFIG_FILE")" == "0" ]]; then
        die "Co najmniej jeden branch używa ai_automerge_all, ale automerge_all_models jest puste."
    fi
    if jq -e '[.tracked_branches[].policy] | any(. == "ai_automerge_simple")' "$CONFIG_FILE" >/dev/null \
        && [[ "$(jq '.automerge_simple_models | length' "$CONFIG_FILE")" == "0" ]]; then
        die "Co najmniej jeden branch używa ai_automerge_simple, ale automerge_simple_models jest puste."
    fi

    configured_workdir="$(jq -r '.workdir' "$CONFIG_FILE")"
    WORKDIR="$(realpath -e -- "$configured_workdir" 2>/dev/null)" || die "Katalog workdir nie istnieje: $configured_workdir"
    REMOTE="$(jq -r '.remote' "$CONFIG_FILE")"
    TARGET_BRANCH="$(jq -r '.target_branch' "$CONFIG_FILE")"
    FETCH_INTERVAL="$(jq -r '.fetch_interval_seconds' "$CONFIG_FILE")"
    UI_REFRESH_MS="$(jq -r '.ui_refresh_ms' "$CONFIG_FILE")"
    UI_REFRESH_SECONDS="$(milliseconds_to_seconds "$UI_REFRESH_MS")"
    PUSH_AFTER_MERGE="$(jq -r '.push_after_merge' "$CONFIG_FILE")"
    MIN_TIME_BETWEEN_MERGES_M="$(jq -r '.min_time_between_merges_m // 5' "$CONFIG_FILE")"
    GIT_USER_NAME="$(jq -r '.git_user_name // "Automerger"' "$CONFIG_FILE")"
    GIT_USER_EMAIL="$(jq -r '.git_user_email // "automerger@localhost"' "$CONFIG_FILE")"
    DEFAULT_BRANCH_PREFIX="$(jq -r '.default_branch_prefix' "$CONFIG_FILE")"
    prompt_relative="$(jq -r '.prompt_file' "$CONFIG_FILE")"
    MODEL_LOG_DIR="${AUTOMERGER_MODEL_LOG_DIR:-$SCRIPT_DIR/logs}"
    MODEL_ERROR_LOG="$MODEL_LOG_DIR"
    MODEL_LOG_RETENTION_DAYS="$(jq -r '.model_logs_retention_days // 30' "$CONFIG_FILE")"

    is_safe_relative_path "$prompt_relative" || die "prompt_file musi być bezpieczną ścieżką względną wobec katalogu skryptu (path traversal jest zabroniony)."
    resolved_prompt="$(realpath -e -- "$SCRIPT_DIR/$prompt_relative" 2>/dev/null)" || die "Nie można odczytać prompt_file: $SCRIPT_DIR/$prompt_relative"
    [[ "$resolved_prompt" == "$SCRIPT_DIR"/* ]] || die "prompt_file wskazuje poza katalog skryptu (path traversal przez symlink jest zabroniony)."
    [[ -f "$resolved_prompt" && -r "$resolved_prompt" ]] || die "Nie można odczytać prompt_file: $resolved_prompt"
    PROMPT_FILE="$resolved_prompt"

    while IFS= read -r autoresolve_pattern; do
        is_safe_relative_path "$autoresolve_pattern" \
            || die "autoresolve_files_list zawiera niedozwoloną ścieżkę '$autoresolve_pattern'; wymagane są ścieżki względne wobec workdir bez path traversal."
    done < <(jq -r '.autoresolve_files_list[]' "$CONFIG_FILE")

    git -C "$WORKDIR" rev-parse --git-dir >/dev/null 2>&1 || die "workdir nie jest repozytorium Git: $WORKDIR"
    git -C "$WORKDIR" remote get-url "$REMOTE" >/dev/null 2>&1 || die "Nie istnieje remote '$REMOTE'."
    git -C "$WORKDIR" check-ref-format --branch "$TARGET_BRANCH" >/dev/null 2>&1 || die "Niepoprawna nazwa brancha docelowego."
}

sanitize_model_log_component() {
    local value="$1"
    value="${value//[^A-Za-z0-9_.-]/x}"
    [[ -n "$value" ]] || value="unknown"
    printf '%s' "$value"
}

prune_model_logs() {
    local path
    while IFS= read -r -d '' path; do
        [[ "$path" == "$MODEL_LOG_DIR"/* && ! -L "$path" ]] || continue
        rm -rf -- "$path"
    done < <(find "$MODEL_LOG_DIR" -mindepth 2 -maxdepth 2 -type d \
        -mtime "+$MODEL_LOG_RETENTION_DAYS" -print0 2>/dev/null)
    find "$MODEL_LOG_DIR" -maxdepth 1 -type f \
        \( -name '*.output.log' -o -name '*.request.md' \) \
        -mtime "+$MODEL_LOG_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$MODEL_LOG_DIR" -mindepth 2 -type f -name '*.reserve' -mmin +60 -delete 2>/dev/null || true
    find "$MODEL_LOG_DIR" -mindepth 1 -maxdepth 2 -type d -empty -delete 2>/dev/null || true
}

next_model_diagnostic_base() {
    local directory="$1" context="$2" attempt="$3" stamp="${4:-}"
    local base suffix=1
    [[ -n "$stamp" ]] || stamp="$(date +%H_%M_%S)"
    base="$directory/${stamp}-${context}-att-${attempt}"
    while [[ -e "$base.out.log" || -e "$base.req.md" ]] \
        || ! (set -o noclobber; : >"$base.reserve") 2>/dev/null; do
        ((suffix++))
        base="$directory/${stamp}-${context}-att-${attempt}-${suffix}"
    done
    printf '%s' "$base"
}

migrate_legacy_model_logs() {
    local legacy_index="$MODEL_LOG_DIR/model-errors.jsonl"
    local remaining entry timestamp context branch model attempt max_attempts category exit_code message
    local safe_model safe_context date_directory stamp base old_output old_request new_output new_request migrated
    [[ -f "$legacy_index" && ! -L "$legacy_index" ]] || return 0
    remaining="$(mktemp "$MODEL_LOG_DIR/.legacy-remaining.XXXXXX")" || return 1
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        if ! jq -e . >/dev/null 2>&1 <<<"$entry"; then
            printf '%s\n' "$entry" >>"$remaining"
            continue
        fi
        timestamp="$(jq -r '.timestamp // ""' <<<"$entry")"
        context="$(jq -r '.context // "unknown"' <<<"$entry")"
        branch="$(jq -r '.branch // ""' <<<"$entry")"
        model="$(jq -r '.model // "unknown"' <<<"$entry")"
        attempt="$(jq -r '.attempt // 1' <<<"$entry")"
        max_attempts="$(jq -r '.max_attempts // 1' <<<"$entry")"
        category="$(jq -r '.category // "unknown"' <<<"$entry")"
        exit_code="$(jq -r '.exit_code // 1' <<<"$entry")"
        message="$(jq -r '.message // "Brak opisu błędu."' <<<"$entry")"
        old_output="$(jq -r '.output_file // ""' <<<"$entry")"
        old_request="$(jq -r '.request_file // ""' <<<"$entry")"
        safe_model="$(sanitize_model_log_component "$model")"
        safe_context="$(sanitize_model_log_component "$context")"
        date_directory="$MODEL_LOG_DIR/$safe_model/$(date -d "$timestamp" +%d-%m-%Y 2>/dev/null || date +%d-%m-%Y)"
        stamp="$(date -d "$timestamp" +%H_%M_%S 2>/dev/null || date +%H_%M_%S)"
        if [[ -L "$MODEL_LOG_DIR/$safe_model" || -L "$date_directory" ]] \
            || ! mkdir -p -- "$date_directory"; then
            printf '%s\n' "$entry" >>"$remaining"
            continue
        fi
        chmod 700 -- "$MODEL_LOG_DIR/$safe_model" "$date_directory"
        base="$(next_model_diagnostic_base "$date_directory" "$safe_context" "$attempt" "$stamp")"
        new_output=""
        new_request=""
        migrated=true
        if [[ -n "$old_output" && -f "$old_output" && ! -L "$old_output" && "$old_output" == "$MODEL_LOG_DIR"/* ]]; then
            new_output="$base.out.log"
            write_readable_model_output "$new_output" "$old_output" "$timestamp" "$context" "$branch" \
                "$model" "$attempt" "$max_attempts" "$category" "$exit_code" "$message" || migrated=false
        fi
        if [[ "$migrated" == "true" && -n "$old_request" && -f "$old_request" \
            && ! -L "$old_request" && "$old_request" == "$MODEL_LOG_DIR"/* ]]; then
            new_request="$base.req.md"
            cp -p -- "$old_request" "$new_request" || migrated=false
        fi
        if [[ "$migrated" == "true" ]]; then
            entry="$(jq -c --arg output "$new_output" --arg request "$new_request" \
                '.output_file=$output | .request_file=$request' <<<"$entry")"
            printf '%s\n' "$entry" >>"$date_directory/errors.jsonl" || migrated=false
        fi
        if [[ "$migrated" == "true" ]]; then
            [[ -z "$old_output" || "$old_output" == "$new_output" ]] || rm -f -- "$old_output"
            [[ -z "$old_request" || "$old_request" == "$new_request" ]] || rm -f -- "$old_request"
            chmod 600 -- "$date_directory/errors.jsonl"
            [[ -z "$new_output" ]] || chmod 600 -- "$new_output"
            [[ -z "$new_request" ]] || chmod 600 -- "$new_request"
        else
            rm -f -- "$new_output" "$new_request"
            printf '%s\n' "$entry" >>"$remaining"
        fi
        rm -f -- "$base.reserve"
    done <"$legacy_index"
    if [[ -s "$remaining" ]]; then
        mv -f -- "$remaining" "$legacy_index"
    else
        rm -f -- "$remaining" "$legacy_index"
    fi
}

write_readable_model_output() {
    local destination="$1" source="$2" timestamp="$3" context="$4" branch="$5"
    local model="$6" attempt="$7" max_attempts="$8" category="$9" exit_code="${10}" message="${11}"
    local line_count
    {
        printf 'timestamp: %s\ncontext: %s\nbranch: %s\nmodel: %s\n' \
            "$timestamp" "$context" "$branch" "$model"
        printf 'attempt: %s/%s\ncategory: %s\nexit_code: %s\nmessage: %s\n' \
            "$attempt" "$max_attempts" "$category" "$exit_code" "$message"
        printf '%s\n' '--- model stdout/stderr ---'
        if [[ -s "$source" ]]; then
            line_count="$(wc -l <"$source")"
            if ((line_count > 1200)); then
                head -n 300 -- "$source" \
                    | sed -E $'s/\\x1B\\[[0-9;?]*[ -/]*[@-~]//g' \
                    | compress_repeated_model_lines
                printf '\n--- pominięto %d środkowych linii ---\n\n' "$((line_count - 1200))"
                tail -n 900 -- "$source" \
                    | sed -E $'s/\\x1B\\[[0-9;?]*[ -/]*[@-~]//g' \
                    | compress_repeated_model_lines
            else
                sed -E $'s/\\x1B\\[[0-9;?]*[ -/]*[@-~]//g' "$source" \
                    | compress_repeated_model_lines
            fi
        else
            printf '(brak outputu procesu)\n'
        fi
    } >"$destination"
}

compress_repeated_model_lines() {
    awk '
        NR == 1 { previous=$0; count=1; next }
        $0 == previous { count++; next }
        {
            if (count > 1) print previous " (x" count ")"
            else print previous
            previous=$0
            count=1
        }
        END {
            if (NR > 0) {
                if (count > 1) print previous " (x" count ")"
                else print previous
            }
        }
    '
}

init_runtime() {
    local config_hash latest_config_merge
    config_hash="$(printf '%s' "$(cd -- "$(dirname -- "$SOURCE_CONFIG_FILE")" && pwd -P)/$(basename -- "$SOURCE_CONFIG_FILE")" | sha256sum | cut -c1-12)"
    STATE_DIR="${AUTOMERGER_STATE_DIR:-${TMPDIR:-/tmp}/automerger-${UID}-${config_hash}}"
    STATE_FILE="$STATE_DIR/state.json"
    STATE_LOCK="$STATE_DIR/state.lock"
    CONFIG_LOCK="$STATE_DIR/config.lock"
    BRANCHES_INFO_LOCK="$STATE_DIR/branch-info.lock"
    MODEL_LOG_LOCK="$STATE_DIR/model-log.lock"
    STOP_FILE="$STATE_DIR/stopped"
    QUEUE_FILE="$STATE_DIR/commands.queue"
    CURRENT_FILE="$STATE_DIR/current.json"
    WORKTREE_ROOT="$STATE_DIR/worktrees"
    [[ ! -L "$STATE_DIR" ]] || die "Katalog runtime nie może być dowiązaniem symbolicznym: $STATE_DIR"
    [[ ! -L "$MODEL_LOG_DIR" ]] || die "Katalog szczegółowych logów modeli nie może być dowiązaniem symbolicznym: $MODEL_LOG_DIR"
    mkdir -p -- "$WORKTREE_ROOT" "$MODEL_LOG_DIR"
    MODEL_LOG_LOCK="$MODEL_LOG_DIR/.model-log.lock"
    [[ "$(stat -c '%u' "$STATE_DIR")" == "$UID" ]] || die "Katalog runtime nie należy do bieżącego użytkownika: $STATE_DIR"
    chmod 700 -- "$STATE_DIR" "$WORKTREE_ROOT"
    : >"$STATE_LOCK"
    : >"$CONFIG_LOCK"
    : >"$BRANCHES_INFO_LOCK"
    touch "$MODEL_LOG_LOCK"
    touch "$QUEUE_FILE"
    if [[ ! -s "$STATE_FILE" ]] || ! jq -e . "$STATE_FILE" >/dev/null 2>&1; then
        printf '%s\n' '{"target_branch_sha":"","last_fetch_at":0,"branches":{},"logs":[],"pr_discovery":{"known":[],"pending":[],"last_checked_at":0}}' >"$STATE_FILE"
    fi
    [[ -s "$CURRENT_FILE" ]] || printf '%s\n' '{"kind":"","pid":0,"label":""}' >"$CURRENT_FILE"
    if [[ ! -e "$BRANCHES_INFO_FILE" ]]; then
        printf '%s\n' '{"version":1,"branch_info":{},"tracked_branches":{},"continuous_nudges":{}}' >"$BRANCHES_INFO_FILE"
    fi
    jq -e '.version == 1 and (.branch_info | type == "object")' "$BRANCHES_INFO_FILE" >/dev/null 2>&1 \
        || die "Plik branches_config.json ma niepoprawny format."
    chmod 700 -- "$MODEL_LOG_DIR"
    chmod 600 -- "$STATE_FILE" "$STATE_LOCK" "$CONFIG_LOCK" "$BRANCHES_INFO_LOCK" "$MODEL_LOG_LOCK" \
        "$QUEUE_FILE" "$CURRENT_FILE" "$BRANCHES_INFO_FILE" "$MODEL_LOG_LOCK"
    (
        flock -x 9
        prune_model_logs
        migrate_legacy_model_logs
    ) 9>"$MODEL_LOG_LOCK"
    state_update '
        .command_outputs = (.command_outputs // [])
        | .title_queue = ((.title_queue // []) | map(select(type == "string")) | unique)
        | .pr_discovery = ((.pr_discovery // {}) + {
            known:((.pr_discovery.known // []) | map(select(type == "string")) | unique),
            pending:((.pr_discovery.pending // []) | map(select(type == "string")) | unique),
            last_checked_at:(.pr_discovery.last_checked_at // 0)
        })
        |
        .logs |= (
            map(select(
                (.label | type == "string")
                and ((.label | test("[[:cntrl:]]")) | not)
            ))
            | reduce .[] as $entry ([];
                if ($entry.status != "RUNNING")
                    and (length > 0)
                    and (.[-1].status == $entry.status)
                    and (.[-1].label == $entry.label)
                then
                    .[-1].count = ((.[-1].count // 1) + ($entry.count // 1))
                    | .[-1].finished_at = $entry.finished_at
                else . + [($entry + {count:($entry.count // 1)})]
                end
            )
            | if length > 12 then .[-12:] else . end
        )
    ' || die "Nie udało się znormalizować stanu logów."
    latest_config_merge="$(jq -r '[.tracked_branches[]?.last_merged_at // 0] | max // 0' "$CONFIG_FILE")"
    state_update --argjson latest "$latest_config_merge" '
        .last_successful_merge_at = ([.last_successful_merge_at // 0, $latest] | max)
    ' || die "Nie udało się zainicjalizować globalnego czasu ostatniego merge."
}

state_update() {
    local tmp
    tmp="$(mktemp "$STATE_DIR/state.XXXXXX")" || return 1
    (
        flock -x 9
        if jq "$@" "$STATE_FILE" >"$tmp"; then
            mv -f -- "$tmp" "$STATE_FILE"
        else
            rm -f -- "$tmp"
            return 1
        fi
    ) 9>"$STATE_LOCK"
}

config_update() {
    local tmp main_tmp branches_tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/automerger-effective.XXXXXX")" || return 1
    main_tmp="$(mktemp "$(dirname -- "$SOURCE_CONFIG_FILE")/.config.XXXXXX")" || { rm -f -- "$tmp"; return 1; }
    branches_tmp="$(mktemp "$(dirname -- "$BRANCHES_CONFIG_FILE")/.branches-config.XXXXXX")" || { rm -f -- "$tmp" "$main_tmp"; return 1; }
    (
        flock -x 9
        if jq "$@" "$CONFIG_FILE" >"$tmp"; then
            jq 'del(.models,.tracked_branches,.continuous_nudges)' "$tmp" >"$main_tmp" \
                && jq --slurpfile effective "$tmp" '
                    .tracked_branches=$effective[0].tracked_branches
                    | .continuous_nudges=$effective[0].continuous_nudges
                ' "$BRANCHES_CONFIG_FILE" >"$branches_tmp" || {
                    rm -f -- "$tmp" "$main_tmp" "$branches_tmp"
                    return 1
                }
            chmod --reference="$SOURCE_CONFIG_FILE" "$main_tmp" 2>/dev/null || true
            chmod --reference="$BRANCHES_CONFIG_FILE" "$branches_tmp" 2>/dev/null || true
            chmod 600 -- "$tmp"
            mv -f -- "$main_tmp" "$SOURCE_CONFIG_FILE"
            mv -f -- "$branches_tmp" "$BRANCHES_CONFIG_FILE"
            mv -f -- "$tmp" "$CONFIG_FILE"
        else
            rm -f -- "$tmp" "$main_tmp" "$branches_tmp"
            return 1
        fi
    ) 9>"$CONFIG_LOCK"
}

branch_info_update() {
    local tmp
    tmp="$(mktemp "$SCRIPT_DIR/.branch_info-info.XXXXXX")" || return 1
    (
        flock -x 9
        if jq "$@" "$BRANCHES_INFO_FILE" >"$tmp"; then
            chmod --reference="$BRANCHES_INFO_FILE" "$tmp" 2>/dev/null || true
            mv -f -- "$tmp" "$BRANCHES_INFO_FILE"
        else
            rm -f -- "$tmp"
            return 1
        fi
    ) 9>"$BRANCHES_INFO_LOCK"
}

write_model_diagnostic() (
    local context="$1" branch="$2" model="$3" attempt="$4" max_attempts="$5"
    local category="$6" exit_code="$7" message="$8" output_file="${9:-}" request_file="${10:-}"
    local timestamp safe_model safe_context date_directory base artifact_output="" artifact_request=""
    local command_template entry index_file
    exec 9>"$MODEL_LOG_LOCK"
    flock -x 9
    timestamp="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    safe_model="$(sanitize_model_log_component "$model")"
    safe_context="$(sanitize_model_log_component "$context")"
    date_directory="$MODEL_LOG_DIR/$safe_model/$(date +%d-%m-%Y)"
    [[ ! -L "$MODEL_LOG_DIR/$safe_model" && ! -L "$date_directory" ]] || return 1
    mkdir -p -- "$date_directory"
    chmod 700 -- "$MODEL_LOG_DIR/$safe_model" "$date_directory"
    base="$(next_model_diagnostic_base "$date_directory" "$safe_context" "$attempt")"
    if [[ -n "$output_file" && -f "$output_file" ]]; then
        artifact_output="$base.out.log"
        write_readable_model_output "$artifact_output" "$output_file" "$timestamp" "$context" \
            "$branch" "$model" "$attempt" "$max_attempts" "$category" "$exit_code" "$message" \
            || artifact_output=""
    fi
    if [[ -n "$request_file" && -f "$request_file" ]]; then
        artifact_request="$base.req.md"
        cp -p -- "$request_file" "$artifact_request" 2>/dev/null || artifact_request=""
    fi
    command_template="$(jq -r --arg model "$model" '.model_commands[$model] // ""' "$MODEL_COMMANDS_FILE" 2>/dev/null || true)"
    entry="$(jq -cn \
        --arg timestamp "$timestamp" \
        --arg context "$context" \
        --arg branch "$branch" \
        --arg model "$model" \
        --argjson attempt "$attempt" \
        --argjson max_attempts "$max_attempts" \
        --arg category "$category" \
        --argjson exit_code "$exit_code" \
        --arg message "$message" \
        --arg output_file "$artifact_output" \
        --arg request_file "$artifact_request" \
        --arg command_template "$command_template" \
        '{timestamp:$timestamp,context:$context,branch:$branch,model:$model,
          attempt:$attempt,max_attempts:$max_attempts,category:$category,
          exit_code:$exit_code,message:$message,output_file:$output_file,
          request_file:$request_file,command_template:$command_template}')"
    index_file="$date_directory/errors.jsonl"
    printf '%s\n' "$entry" >>"$index_file"
    chmod 600 -- "$index_file"
    [[ -z "$artifact_output" ]] || chmod 600 -- "$artifact_output"
    [[ -z "$artifact_request" ]] || chmod 600 -- "$artifact_request"
    rm -f -- "$base.reserve"
)

log_start() {
    local label="$1"
    LAST_LOG_ID="$(date +%s%N)-$$-$RANDOM"
    state_update --arg id "$LAST_LOG_ID" --arg label "$label" --argjson at "$(date +%s)" '
        .logs += [{id:$id,label:$label,status:"RUNNING",started_at:$at,finished_at:0,count:1}]
        | .logs = (.logs | if length > 24 then .[-24:] else . end)
    '
}

log_finish() {
    local id="$1"
    local result="$2"
    state_update --arg id "$id" --arg result "$result" --argjson at "$(date +%s)" '
        .logs |= (
            map(if .id == $id then .status=$result | .finished_at=$at else . end)
            | reduce .[] as $entry ([];
                if ($entry.status != "RUNNING")
                    and (length > 0)
                    and (.[-1].status == $entry.status)
                    and (.[-1].label == $entry.label)
                then
                    .[-1].count = ((.[-1].count // 1) + ($entry.count // 1))
                    | .[-1].finished_at = $entry.finished_at
                else . + [$entry]
                end
            )
            | if length > 12 then .[-12:] else . end
        )
    '
}

operation_error() {
    LAST_ERROR="$*"
    return 1
}

github_token_is_active() {
    [[ -n "$GITHUB_ACCESS_TOKEN" ]]
}

activate_github_access_token() {
    local decryption_key="$1"
    local ciphertext iterations decrypted token
    GITHUB_ACCESS_TOKEN=""
    [[ -n "$decryption_key" ]] \
        || { operation_error "Klucz deszyfrujący nie może być pusty."; return 1; }
    if ! jq -e '.github_access_token_encrypted | type == "object"' "$CONFIG_FILE" >/dev/null 2>&1; then
        operation_error "Brak zaszyfrowanego tokenu. Najpierw uruchom prepare_token.sh."
        return 1
    fi
    ciphertext="$(jq -r '.github_access_token_encrypted.ciphertext' "$CONFIG_FILE")"
    iterations="$(jq -r '.github_access_token_encrypted.iterations' "$CONFIG_FILE")"
    decrypted="$(
        printf '%s' "$ciphertext" \
            | openssl enc -d -aes-256-cbc -pbkdf2 -iter "$iterations" -md sha256 \
                -a -A -pass fd:3 3< <(printf '%s' "$decryption_key") 2>/dev/null
    )" || {
        operation_error "Nie udało się odszyfrować tokenu: niepoprawny klucz albo uszkodzony ciphertext."
        return 1
    }
    if [[ "$decrypted" != "$GITHUB_TOKEN_MARKER"* ]]; then
        decrypted=""
        operation_error "Nie udało się zweryfikować odszyfrowanego tokenu."
        return 1
    fi
    token="${decrypted#"$GITHUB_TOKEN_MARKER"}"
    decrypted=""
    [[ -n "$token" && "$token" != *[[:space:][:cntrl:]]* ]] || {
        token=""
        operation_error "Odszyfrowana wartość nie ma poprawnego formatu tokenu."
        return 1
    }
    GITHUB_ACCESS_TOKEN="$token"
    token=""
    decryption_key=""
    return 0
}

run_authenticated_gh() {
    github_token_is_active \
        || { operation_error "Token GitHub jest nieaktywny. Użyj decrypt albo activate_token."; return 1; }
    GH_TOKEN="$GITHUB_ACCESS_TOKEN" command gh "$@"
}

get_pull_request_labels() {
    local branch="$1" output
    github_token_is_active || return 1
    if ! output="$(cd -- "$WORKDIR" && run_authenticated_gh pr view "$branch" --json labels --jq '.labels[].name' 2>&1)"; then
        operation_error "Nie udało się pobrać labeli PR dla $branch (funkcja eksperymentalna)."
        return 1
    fi
    printf '%s' "$output"
}

add_pull_request_label() {
    local branch="$1" label="$2"
    github_token_is_active || return 1
    [[ -n "$label" && "$label" != *$'\n'* && "$label" != *$'\r'* ]] \
        || { operation_error "Labelka nie może być pusta ani wieloliniowa."; return 1; }
    if ! (cd -- "$WORKDIR" && run_authenticated_gh pr edit "$branch" --add-label "$label") >/dev/null 2>&1; then
        operation_error "Nie udało się dodać labelki do PR $branch (funkcja eksperymentalna)."
        return 1
    fi
}

remove_pull_request_label() {
    local branch="$1" label="$2"
    github_token_is_active || return 1
    [[ -n "$label" && "$label" != *$'\n'* && "$label" != *$'\r'* ]] \
        || { operation_error "Labelka nie może być pusta ani wieloliniowa."; return 1; }
    if ! (cd -- "$WORKDIR" && run_authenticated_gh pr edit "$branch" --remove-label "$label") >/dev/null 2>&1; then
        operation_error "Nie udało się usunąć labelki z PR $branch (funkcja eksperymentalna)."
        return 1
    fi
}

format_pull_request_labels() {
    local labels="$1"
    labels="${labels//$'\n'/, }"
    labels="${labels%, }"
    [[ -n "$labels" ]] || labels="(brak)"
    printf '%s' "$labels"
}

set_current() {
    local kind="$1"
    local pid="$2"
    local label="$3"
    local tmp="$CURRENT_FILE.tmp.$$"
    jq -n --arg kind "$kind" --argjson pid "$pid" --arg label "$label" '{kind:$kind,pid:$pid,label:$label}' >"$tmp" && mv -f -- "$tmp" "$CURRENT_FILE"
}

clear_current() {
    set_current "" 0 ""
}

run_logged() {
    local label="$1"
    shift
    local log_id pid exit_code output_file
    log_start "$label"
    log_id="$LAST_LOG_ID"
    output_file="$STATE_DIR/operation-$log_id.log"
    setsid "$@" >"$output_file" 2>&1 &
    pid=$!
    set_current "git" "$pid" "$label"
    wait "$pid"
    exit_code=$?
    if ((exit_code == 0)); then
        log_finish "$log_id" "DONE"
        clear_current
        rm -f -- "$output_file"
        return 0
    fi
    log_finish "$log_id" "FAIL"
    clear_current
    return 1
}

remote_ref() {
    printf 'refs/remotes/%s/%s' "$REMOTE" "$1"
}

remote_branch_exists() {
    git -C "$WORKDIR" show-ref --verify --quiet "$(remote_ref "$1")"
}

fetch_remote() {
    run_logged "git fetch --prune $REMOTE" git -C "$WORKDIR" fetch --prune "$REMOTE"
}

refresh_target_snapshot() {
    local ref sha
    ref="$(remote_ref "$TARGET_BRANCH")"
    git -C "$WORKDIR" show-ref --verify --quiet "$ref" || return 1
    sha="$(git -C "$WORKDIR" rev-parse "$ref^{commit}")" || return 1
    git -C "$WORKDIR" update-ref refs/automerger/target "$sha" || return 1
    state_update --arg sha "$sha" --argjson at "$(date +%s)" '.target_branch_sha=$sha | .last_fetch_at=$at'
}

cleanup_worktree() {
    local worktree="${1:-}"
    [[ -n "$worktree" && -d "$worktree" ]] || return 0
    git -C "$worktree" merge --abort >/dev/null 2>&1 || true
    git -C "$WORKDIR" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    if [[ -d "$worktree" && "$worktree" == "$WORKTREE_ROOT"/* ]]; then
        rm -rf -- "$worktree"
    fi
}

create_worktree() {
    local start_sha="$1"
    local worktree
    worktree="$(mktemp -d "$WORKTREE_ROOT/worktree.XXXXXX")" || return 1
    if ! git -C "$WORKDIR" worktree add --quiet --detach "$worktree" "$start_sha"; then
        rmdir -- "$worktree" 2>/dev/null || true
        return 1
    fi
    printf '%s' "$worktree"
}

file_is_autoresolvable() {
    local file="$1"
    local pattern
    while IFS= read -r pattern; do
        [[ "$file" == $pattern ]] && return 0
    done < <(jq -r '.autoresolve_files_list[]' "$CONFIG_FILE")
    return 1
}

classify_branch() {
    local branch="$1"
    local target_branch_sha target_sha last_target_branch_sha last_target_sha worktree merge_exit classification file
    local -a conflict_files=()
    target_branch_sha="$(git -C "$WORKDIR" rev-parse refs/automerger/target^{commit} 2>/dev/null)" || return 2
    target_sha="$(git -C "$WORKDIR" rev-parse "$(remote_ref "$branch")^{commit}" 2>/dev/null)" || return 2
    last_target_branch_sha="$(jq -r --arg branch "$branch" \
        '.tracked_branches[$branch].last_merged_target_branch_sha // ""' "$CONFIG_FILE")"
    last_target_sha="$(jq -r --arg branch "$branch" \
        '.tracked_branches[$branch].last_merged_target_sha // ""' "$CONFIG_FILE")"

    if [[ -n "$target_branch_sha" && "$target_branch_sha" == "$last_target_branch_sha" \
        && "$target_sha" == "$last_target_sha" ]]; then
        state_update --arg branch "$branch" --arg dev "$target_branch_sha" --arg target "$target_sha" '
            .branches[$branch] = ((.branches[$branch] // {}) + {
                mergeability:"up to date",up_to_date:true,target_branch_sha:$dev,
                target_sha:$target,action_state:"merged",error:""
            })
            | del(.branches[$branch].failed_target_branch_sha, .branches[$branch].failed_target_sha)
        '
        printf 'up to date'
        return 0
    fi

    if git -C "$WORKDIR" merge-base --is-ancestor "$target_branch_sha" "$target_sha"; then
        state_update --arg branch "$branch" --arg dev "$target_branch_sha" --arg target "$target_sha" '
            .branches[$branch] = ((.branches[$branch] // {}) + {
                mergeability:"up to date",up_to_date:true,target_branch_sha:$dev,
                target_sha:$target,action_state:"merged",error:""
            })
            | del(.branches[$branch].failed_target_branch_sha, .branches[$branch].failed_target_sha)
        '
        printf 'up to date'
        return 0
    fi

    worktree="$(create_worktree "$target_sha")" || return 2
    ACTIVE_WORKTREE="$worktree"
    git -C "$worktree" -c user.name="$GIT_USER_NAME" -c user.email="$GIT_USER_EMAIL" \
        merge --no-commit --no-ff "$target_branch_sha" >/dev/null 2>&1
    merge_exit=$?
    if ((merge_exit == 0)); then
        classification="mergable"
    else
        while IFS= read -r -d '' file; do
            conflict_files+=("$file")
        done < <(git -C "$worktree" diff --name-only --diff-filter=U -z)
        classification="simple conflicts"
        if ((${#conflict_files[@]} == 0)); then
            classification="conflicts"
        else
            for file in "${conflict_files[@]}"; do
                if ! file_is_autoresolvable "$file"; then
                    classification="conflicts"
                    break
                fi
            done
        fi
    fi
    cleanup_worktree "$worktree"
    ACTIVE_WORKTREE=""
    state_update --arg branch "$branch" --arg result "$classification" --arg dev "$target_branch_sha" --arg target "$target_sha" '
        .branches[$branch] = ((.branches[$branch] // {}) + {
            mergeability:$result,up_to_date:false,target_branch_sha:$dev,target_sha:$target
        })
        | if (.branches[$branch].failed_target_branch_sha // "") == $dev
            and (.branches[$branch].failed_target_sha // "") == $target
          then .branches[$branch].action_state="fail"
          else .branches[$branch].error=""
            | .branches[$branch].action_state="checking"
            | del(.branches[$branch].failed_target_branch_sha, .branches[$branch].failed_target_sha)
          end
    '
    printf '%s' "$classification"
}

cleanup_missing_branches() {
    local existing_json
    existing_json="$(git -C "$WORKDIR" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    config_update --argjson existing "$existing_json" '
        .tracked_branches |= with_entries(select(.key as $branch | $existing | index($branch)))
        | .continuous_nudges = ((.continuous_nudges // {})
            | with_entries(select(.key as $branch | $existing | index($branch))))
    '
    state_update --argjson existing "$existing_json" '.branches |= with_entries(select(.key as $branch | $existing | index($branch)))'
}

valid_policy() {
    case "$1" in
        "$POLICY_AI_ALL" | "$POLICY_AI_SIMPLE" | "$POLICY_BASIC" | "$POLICY_MANUAL") return 0 ;;
        *) return 1 ;;
    esac
}

normalize_policy() {
    case "${1,,}" in
        "$POLICY_BASIC" | basic | automerge)
            printf '%s' "$POLICY_BASIC"
            ;;
        "$POLICY_AI_SIMPLE" | ai_merge_simple | ai_simple | automerge_simple | merge_simple | simple)
            printf '%s' "$POLICY_AI_SIMPLE"
            ;;
        "$POLICY_AI_ALL" | ai_automerge_full | ai_merge_full | ai_full | automerge_full | merge_full | full)
            printf '%s' "$POLICY_AI_ALL"
            ;;
        "$POLICY_MANUAL")
            printf '%s' "$POLICY_MANUAL"
            ;;
        *)
            return 1
            ;;
    esac
}

normalize_branch_name() {
    local branch="$1"
    if [[ "$branch" =~ ^[0-9]+$ && -n "$DEFAULT_BRANCH_PREFIX" ]]; then
        printf '%s%s' "$DEFAULT_BRANCH_PREFIX" "$branch"
    else
        printf '%s' "$branch"
    fi
}

looks_like_branch_command() {
    local token="$1"
    [[ "$token" =~ ^[0-9]+$ ]] && return 0
    [[ -n "$DEFAULT_BRANCH_PREFIX" && "$token" == "$DEFAULT_BRANCH_PREFIX"* ]]
}

policy_has_models() {
    local policy="$1"
    case "$policy" in
        "$POLICY_AI_ALL") [[ "$(jq '.automerge_all_models | length' "$CONFIG_FILE")" -gt 0 ]] ;;
        "$POLICY_AI_SIMPLE") [[ "$(jq '.automerge_simple_models | length' "$CONFIG_FILE")" -gt 0 ]] ;;
        *) return 0 ;;
    esac
}

model_max_working_time() {
    local model="$1" context="${2:-$MODEL_CONFIG_CONTEXT}"
    jq -r --arg model "$model" --arg context "$context" '
        .models[$model][$context].max_working_time
        // .models[$model].max_working_time
        // .model_max_working_time_s_default
    ' "$CONFIG_FILE"
}

model_max_attempts() {
    local model="$1" context="${2:-$MODEL_CONFIG_CONTEXT}"
    jq -r --arg model "$model" --arg context "$context" '
        .models[$model][$context].max_attempts
        // .models[$model].max_attempts
        // .model_max_attempts_default
    ' "$CONFIG_FILE"
}

merge_commit_message() {
    printf 'Automated merge of %s with %s by Automerger' "$1" "$TARGET_BRANCH"
}

track_branches() {
    local specification normalized branches_token policy policy_input cooldown merge_without_conflicts branch now
    local -a branches=()
    specification="$(trim "$1")"
    [[ -n "$specification" ]] || { operation_error "Nie podano nazwy brancha."; return 1; }
    normalized="$(printf '%s' "$specification" | sed -E 's/,[[:space:]]*/,/g')"
    read -r branches_token policy cooldown merge_without_conflicts _ <<<"$normalized"
    policy_input="${policy:-$POLICY_MANUAL}"
    cooldown="${cooldown:-auto}"
    policy="$(normalize_policy "$policy_input")" \
        || { operation_error "Niepoprawna polityka: $policy_input"; return 1; }
    policy_has_models "$policy" \
        || { operation_error "Nie można przypisać polityki '$policy': odpowiadająca jej lista modeli jest pusta."; return 1; }
    [[ "$cooldown" == "auto" || "$cooldown" =~ ^[0-9]+$ ]] \
        || { operation_error "Cooldown musi być liczbą minut lub wartością auto."; return 1; }
    [[ -z "$merge_without_conflicts" || "$merge_without_conflicts" == "true" || "$merge_without_conflicts" == "false" ]] \
        || { operation_error "merge_without_conflicts musi mieć wartość true albo false."; return 1; }
    now="$(date +%s)"
    IFS=',' read -r -a branches <<<"$branches_token"
    for branch in "${branches[@]}"; do
        branch="$(trim "$branch")"
        branch="$(normalize_branch_name "$branch")"
        git -C "$WORKDIR" check-ref-format --branch "$branch" >/dev/null 2>&1 \
            || { operation_error "Niepoprawna nazwa brancha: $branch"; return 1; }
        remote_branch_exists "$branch" \
            || { operation_error "Branch $REMOTE/$branch nie istnieje."; return 1; }
        config_update --arg branch "$branch" --arg policy "$policy" --arg cooldown "$cooldown" \
            --arg merge_without_conflicts "$merge_without_conflicts" --argjson now "$now" '
            .tracked_branches[$branch] = ((.tracked_branches[$branch] // {}) + {
                policy:$policy,
                merge_cooldown_time:(if $cooldown == "auto" then "auto" else ($cooldown | tonumber) end),
                tracked_at:(.tracked_branches[$branch].tracked_at // $now),
                last_merged_at:(.tracked_branches[$branch].last_merged_at // 0),
                last_merged_target_branch_sha:(.tracked_branches[$branch].last_merged_target_branch_sha // ""),
                last_merged_target_sha:(.tracked_branches[$branch].last_merged_target_sha // ""),
                merge_without_conflicts:(if $merge_without_conflicts != "" then ($merge_without_conflicts == "true")
                    else (.tracked_branches[$branch].merge_without_conflicts // .merge_without_conflicts_default // false) end)
            })
        ' || { operation_error "Nie udało się zapisać konfiguracji brancha $branch."; return 1; }
        state_update --arg branch "$branch" '
            .branches[$branch] = ((.branches[$branch] // {}) + {mergeability:"checking",action_state:"checking",error:""})
            | del(.branches[$branch].failed_target_branch_sha, .branches[$branch].failed_target_sha, .branches[$branch].retry_allowed)
        ' || { operation_error "Nie udało się zaktualizować stanu brancha $branch."; return 1; }
        record_command_success "Dodano/zmieniono tracking: $branch ($policy, cooldown $cooldown, merge bez konfliktów $(jq -r --arg branch "$branch" '.tracked_branches[$branch].merge_without_conflicts' "$CONFIG_FILE"))"
    done
}

untrack_branches() {
    local specification normalized branch
    local -a branches=()
    specification="$(trim "$1")"
    [[ -n "$specification" ]] || { operation_error "Nie podano nazwy brancha."; return 1; }
    normalized="$(printf '%s' "$specification" | sed -E 's/,[[:space:]]*/,/g')"
    IFS=',' read -r -a branches <<<"$normalized"
    for branch in "${branches[@]}"; do
        branch="$(trim "$branch")"
        branch="$(normalize_branch_name "$branch")"
        config_update --arg branch "$branch" '
            del(.tracked_branches[$branch], .continuous_nudges[$branch])
        ' \
            || { operation_error "Nie udało się usunąć konfiguracji brancha $branch."; return 1; }
        state_update --arg branch "$branch" 'del(.branches[$branch])' \
            || { operation_error "Nie udało się usunąć stanu brancha $branch."; return 1; }
        record_command_success "Usunięto tracking: $branch"
    done
}

remove_branch_titles() {
    local specification branch
    specification="$(trim "$1")"
    [[ -n "$specification" && "$specification" != *[[:space:]]* ]] \
        || { operation_error "Użycie: remove_title BRANCH albo remove_title all."; return 1; }
    if [[ "${specification,,}" == "all" ]]; then
        branch_info_update '.branch_info={}' || {
            operation_error "Nie udało się usunąć zapisanych tytułów."
            return 1
        }
        state_update '.branches |= with_entries(.value |= del(.title_status))' || {
            operation_error "Tytuły usunięto, ale nie udało się wyczyścić ich statusów runtime."
            return 1
        }
        return 0
    fi
    branch="$(normalize_branch_name "$specification")"
    git -C "$WORKDIR" check-ref-format --branch "$branch" >/dev/null 2>&1 \
        || { operation_error "Niepoprawna nazwa brancha: $branch"; return 1; }
    branch_info_update --arg branch "$branch" 'del(.branch_info[$branch])' || {
        operation_error "Nie udało się usunąć tytułu brancha $branch."
        return 1
    }
    state_update --arg branch "$branch" 'del(.branches[$branch].title_status)' || {
        operation_error "Tytuł usunięto, ale nie udało się wyczyścić jego statusu runtime."
        return 1
    }
}

regenerate_branch_titles() {
    local specification branch branches_json
    local -a requested=() candidates=()
    specification="$(trim "$1")"
    [[ -n "$specification" && "$specification" != *[[:space:]]* ]] \
        || { operation_error "Użycie: title BRANCH albo retitle all."; return 1; }
    stop_title_resolver
    if [[ "${specification,,}" == "all" ]]; then
        mapfile -t requested < <(
            jq -rn --slurpfile config "$CONFIG_FILE" --slurpfile branch_info "$BRANCHES_INFO_FILE" '
                (($config[0].tracked_branches | keys) + ($branch_info[0].branch_info | keys)) | unique[]
            '
        )
        branch_info_update '.branch_info={}' \
            || { operation_error "Nie udało się wyczyścić tytułów przed regeneracją."; return 1; }
    else
        branch="$(normalize_branch_name "$specification")"
        git -C "$WORKDIR" check-ref-format --branch "$branch" >/dev/null 2>&1 \
            || { operation_error "Niepoprawna nazwa brancha: $branch"; return 1; }
        remote_branch_exists "$branch" \
            || { operation_error "Branch $REMOTE/$branch nie istnieje."; return 1; }
        requested=("$branch")
        candidates=("$branch")
        branch_info_update --arg branch "$branch" 'del(.branch_info[$branch])' \
            || { operation_error "Nie udało się usunąć poprzedniego tytułu brancha $branch."; return 1; }
    fi
    if [[ "${specification,,}" == "all" ]]; then
        for branch in "${requested[@]}"; do
            remote_branch_exists "$branch" && candidates+=("$branch")
        done
    fi
    ((${#candidates[@]} > 0)) \
        || { operation_error "Brak dostępnych branchy, dla których można wygenerować tytuł."; return 1; }
    branches_json="$(printf '%s\n' "${candidates[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    state_update --argjson branches "$branches_json" '
        reduce $branches[] as $branch (.;
            .branches[$branch] = ((.branches[$branch] // {}) + {title_status:"resolving"}
                | del(.title_warning, .title_retry_at, .title_retry_count)))
    ' || { operation_error "Nie udało się ustawić statusów title makera."; return 1; }
    start_candidate_title_resolution "${candidates[@]}"
    INTERACTIVE_VALUE="$(IFS=,; printf '%s' "${candidates[*]}")"
}

classify_all_tracked() {
    local branch
    while IFS= read -r branch; do
        [[ -n "$branch" ]] || continue
        if ! remote_branch_exists "$branch"; then
            continue
        fi
        if ! classify_branch "$branch" >/dev/null; then
            state_update --arg branch "$branch" '.branches[$branch].mergeability="conflicts" | .branches[$branch].error="Nie udało się sprawdzić merge."'
            record_command_error "Nie udało się sklasyfikować brancha $branch"
        fi
    done < <(jq -r '.tracked_branches | keys[]' "$CONFIG_FILE")
}

conflicts_are_simple() {
    local worktree="$1"
    local file found=0
    while IFS= read -r -d '' file; do
        found=1
        file_is_autoresolvable "$file" || return 1
    done < <(git -C "$worktree" diff --name-only --diff-filter=U -z)
    ((found == 1))
}

prepare_ai_prompt() {
    local worktree="$1"
    local branch="$2"
    local target_branch_sha="$3"
    local output_file="$4"
    local file
    {
        cat -- "$PROMPT_FILE"
        printf '\n\n# Bieżące zadanie\n\n'
        printf 'Rozwiąż konflikty merge lokalnego snapshotu target_branch `%s` do brancha `%s`.\n\n' "$target_branch_sha" "$branch"
        printf 'Konfliktujące pliki:\n'
        while IFS= read -r -d '' file; do
            printf -- '- `%s`\n' "$file"
        done < <(git -C "$worktree" diff --name-only --diff-filter=U -z)
        printf '\nZastosuj instrukcje zawarte powyżej i zakończ jednym wymaganym statusem.\n'
    } >"$output_file"
}

expand_model_command() {
    local command_template="$1"
    local prompt_path="$2"
    local request_path="$3"
    local model_session_dir="${4:-}"
    local model_output_file="${5:-}"
    local request_content_path="${6:-$request_path}"
    local prompt_quoted request_quoted request_text_quoted model_session_quoted model_output_quoted
    local patsub_replacement_was_enabled=false
    prompt_quoted="$(shell_quote "$prompt_path")"
    request_quoted="$(shell_quote "$request_path")"
    request_text_quoted="$(shell_quote "$(<"$request_content_path")")"
    model_session_quoted="$(shell_quote "$model_session_dir")"
    model_output_quoted="$(shell_quote "$model_output_file")"
    if shopt -q patsub_replacement; then
        patsub_replacement_was_enabled=true
        shopt -u patsub_replacement
    fi
    command_template="${command_template//\{\{PROMPT_FILE\}\}/$prompt_quoted}"
    command_template="${command_template//\{\{REQUEST_FILE\}\}/$request_quoted}"
    command_template="${command_template//\{\{PROMPT\}\}/$request_text_quoted}"
    command_template="${command_template//\{\{MODEL_SESSION_DIR\}\}/$model_session_quoted}"
    command_template="${command_template//\{\{MODEL_OUTPUT_FILE\}\}/$model_output_quoted}"
    [[ "$patsub_replacement_was_enabled" == "false" ]] || shopt -s patsub_replacement
    printf '%s' "$command_template"
}

cleanup_model_session_dir() {
    local model_session_dir="$1"
    if [[ -n "$model_session_dir" && "$model_session_dir" == "$STATE_DIR"/model-session.* ]]; then
        rm -rf -- "$model_session_dir"
    fi
}

cleanup_ai_sandbox_dir() {
    local sandbox_dir="$1"
    if [[ -n "$sandbox_dir" && "$sandbox_dir" == "$STATE_DIR"/ai-sandbox.* && -d "$sandbox_dir" ]]; then
        chmod -R u+rwX -- "$sandbox_dir" 2>/dev/null || true
        rm -rf -- "$sandbox_dir"
    fi
}

copy_file_if_readable() {
    local source="$1"
    local destination="$2"
    if [[ -f "$source" && -r "$source" ]]; then
        mkdir -p -- "$(dirname -- "$destination")"
        cp -p -- "$source" "$destination"
    fi
}

prepare_ai_sandbox_home() {
    local sandbox_home="$1"
    local user_home_dir="${HOME:-}"
    mkdir -p -- "$sandbox_home/.codex" "$sandbox_home/.claude" "$sandbox_home/.openhands"
    [[ -n "$user_home_dir" ]] || return 0
    copy_file_if_readable "$user_home_dir/.codex/auth.json" "$sandbox_home/.codex/auth.json"
    copy_file_if_readable "$user_home_dir/.codex/models_cache.json" "$sandbox_home/.codex/models_cache.json"
    copy_file_if_readable "$user_home_dir/.claude/.credentials.json" "$sandbox_home/.claude/.credentials.json"
    copy_file_if_readable "$user_home_dir/.claude/settings.json" "$sandbox_home/.claude/settings.json"
    copy_file_if_readable "$user_home_dir/.openhands/agent_settings.json" "$sandbox_home/.openhands/agent_settings.json"
    copy_file_if_readable "$user_home_dir/.openhands/cli_config.json" "$sandbox_home/.openhands/cli_config.json"
    if [[ -d "$user_home_dir/.openhands/profiles" ]]; then
        cp -a -- "$user_home_dir/.openhands/profiles" "$sandbox_home/.openhands/profiles"
    fi
}

overlay_entry_is_allowed() {
    local entry="$1"
    shift
    local allowed_file
    [[ "$entry" == ".automerger" ]] && return 0
    for allowed_file in "$@"; do
        if [[ "$entry" == "$allowed_file" || "$allowed_file" == "$entry"/* ]]; then
            return 0
        fi
    done
    return 1
}

find_overlay_violation() {
    local upper_dir="$1"
    shift
    local entry
    while IFS= read -r -d '' entry; do
        entry="${entry#./}"
        overlay_entry_is_allowed "$entry" "$@" || {
            printf '%s' "$entry"
            return 0
        }
    done < <(cd -- "$upper_dir" && find . -mindepth 1 -print0)
    return 1
}

monitor_ai_overlay() {
    local upper_dir="$1"
    local model_pid="$2"
    local violation_file="$3"
    shift 3
    local violation
    while kill -0 "$model_pid" 2>/dev/null; do
        violation="$(find_overlay_violation "$upper_dir" "$@" || true)"
        if [[ -n "$violation" ]]; then
            printf '%s\n' "$violation" >"$violation_file"
            kill -TERM -- "-$model_pid" 2>/dev/null || kill -TERM "$model_pid" 2>/dev/null || true
            return 0
        fi
        sleep 0.1
    done
}

apply_ai_overlay_changes() {
    local upper_dir="$1"
    local worktree="$2"
    shift 2
    local file overlay_file destination violation
    violation="$(find_overlay_violation "$upper_dir" "$@" || true)"
    [[ -z "$violation" ]] || {
        AI_SECURITY_VIOLATION="$(shell_quote "$violation")"
        return "$AI_SECURITY_FAILURE_EXIT"
    }
    for file in "$@"; do
        ai_path_is_safe "$file" || {
            AI_SECURITY_VIOLATION="niebezpieczna ścieżka konfliktu: $file"
            return "$AI_SECURITY_FAILURE_EXIT"
        }
        overlay_file="$upper_dir/$file"
        destination="$worktree/$file"
        if [[ -L "$overlay_file" || -L "$destination" ]]; then
            AI_SECURITY_VIOLATION="próba użycia dowiązania symbolicznego: $file"
            return "$AI_SECURITY_FAILURE_EXIT"
        elif [[ -f "$overlay_file" ]]; then
            cp -p -- "$overlay_file" "$destination" || return 1
        elif [[ -c "$overlay_file" ]]; then
            rm -f -- "$destination" || return 1
        fi
    done
}

run_model_close_command() {
    local model="$1"
    local worktree="$2"
    local request_file="$3"
    local output_file="$4"
    local model_session_dir="$5"
    local command_template expanded close_output_file log_id pid exit_code
    command_template="$(jq -r --arg model "$model" '.model_close_commands[$model] // ""' "$MODEL_COMMANDS_FILE")"
    if [[ -z "$command_template" ]]; then
        cleanup_model_session_dir "$model_session_dir"
        return 0
    fi
    expanded="$(expand_model_command "$command_template" "$PROMPT_FILE" "$request_file" "$model_session_dir" "$output_file")"
    close_output_file="$output_file.close"
    log_start "zamykanie sesji modelu AI: $model"
    log_id="$LAST_LOG_ID"
    (
        cd -- "$worktree" || exit 125
        exec setsid timeout --foreground --signal=TERM --kill-after=5s "$MODEL_CLOSE_TIMEOUT" bash -lc "$expanded"
    ) >"$close_output_file" 2>&1 &
    pid=$!
    set_current "model_cleanup" "$pid" "zamykanie sesji modelu AI: $model"
    wait "$pid"
    exit_code=$?
    clear_current
    cleanup_model_session_dir "$model_session_dir"
    if ((exit_code == 0)); then
        log_finish "$log_id" "DONE"
        rm -f -- "$close_output_file"
    else
        log_finish "$log_id" "FAIL"
        {
            printf '\n\n--- MODEL CLOSE COMMAND FAILURE ---\n'
            cat -- "$close_output_file"
        } >>"$output_file" 2>/dev/null || true
        warn "Nie udało się zamknąć lub usunąć sesji modelu '$model'; szczegóły: $close_output_file"
    fi
    return "$exit_code"
}

run_ai_model() {
    local model="$1"
    local worktree="$2"
    local request_file="$3"
    local output_file="$4"
    shift 4
    local -a conflict_files=("$@")
    local command_template expanded max_time log_id pid exit_code close_exit model_session_dir
    local sandbox_dir sandbox_upper sandbox_work sandbox_session sandbox_home deny_file deny_dir violation_file startup_marker monitor_pid
    local tool_binary openhands_root openhands_python openhands_python_root openhands_python_name
    local openhands_site_packages sandbox_site_packages violation violation_display
    local -a sandbox_command=()
    AI_SECURITY_VIOLATION=""
    AI_ISOLATION_ERROR=""
    MODEL_RUN_FAILURE_KIND=""
    MODEL_RUN_EXIT_CODE=0
    command_template="$(jq -r --arg model "$model" '.model_commands[$model] // empty' "$MODEL_COMMANDS_FILE")"
    max_time="$(model_max_working_time "$model")"
    if [[ -z "$command_template" || ! "$max_time" =~ ^[0-9]+$ || "$max_time" -lt 1 ]]; then
        MODEL_RUN_FAILURE_KIND="configuration"
        MODEL_RUN_EXIT_CODE=2
        return 2
    fi
    if ! check_ai_sandbox_support; then
        [[ -n "$AI_ISOLATION_ERROR" ]] \
            || AI_ISOLATION_ERROR="Brak działającej izolacji bubblewrap; agent AI nie został uruchomiony."
        MODEL_RUN_FAILURE_KIND="sandbox_unavailable"
        MODEL_RUN_EXIT_CODE=125
        return 125
    fi
    ((${#conflict_files[@]} > 0)) || {
        MODEL_RUN_FAILURE_KIND="configuration"
        MODEL_RUN_EXIT_CODE=2
        return 2
    }
    local file
    for file in "${conflict_files[@]}"; do
        ai_path_is_safe "$file" || {
            AI_SECURITY_VIOLATION="niebezpieczna ścieżka konfliktu: $file"
            MODEL_RUN_FAILURE_KIND="security_violation"
            MODEL_RUN_EXIT_CODE="$AI_SECURITY_FAILURE_EXIT"
            return "$AI_SECURITY_FAILURE_EXIT"
        }
    done
    model_session_dir="$(mktemp -d "$STATE_DIR/model-session.XXXXXX")" || return 2
    ACTIVE_MODEL_SESSION="$model_session_dir"
    sandbox_dir="$(mktemp -d "$STATE_DIR/ai-sandbox.XXXXXX")" || {
        cleanup_model_session_dir "$model_session_dir"
        ACTIVE_MODEL_SESSION=""
        return 2
    }
    ACTIVE_AI_SANDBOX="$sandbox_dir"
    sandbox_upper="$sandbox_dir/upper"
    sandbox_work="$sandbox_dir/overlay-work"
    sandbox_session="$sandbox_dir/session"
    sandbox_home="$sandbox_dir/home"
    deny_file="$sandbox_dir/deny-file"
    deny_dir="$sandbox_dir/deny-dir"
    violation_file="$sandbox_dir/security-violation"
    startup_marker="$sandbox_session/sandbox-started"
    mkdir -p -- "$sandbox_upper" "$sandbox_work" "$sandbox_session/model-state" "$sandbox_home" "$deny_dir"
    : >"$deny_file"
    chmod 000 -- "$deny_file" "$deny_dir"
    cp -p -- "$PROMPT_FILE" "$sandbox_session/prompt.md"
    cp -p -- "$request_file" "$sandbox_session/request.md"
    prepare_ai_sandbox_home "$sandbox_home"
    expanded="$(expand_model_command "$command_template" /session/prompt.md /session/request.md /session/model-state /session/model-output.log "$request_file")"

    sandbox_command=(
        bwrap --unshare-user --unshare-pid --unshare-ipc --unshare-uts --disable-userns
        --new-session --die-with-parent --cap-drop ALL
        --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib --ro-bind-try /lib64 /lib64
        --ro-bind /etc /etc --proc /proc --dev /dev --tmpfs /tmp
        --dir /run --dir /run/systemd --ro-bind-try /run/systemd/resolve /run/systemd/resolve
        --dir /var --tmpfs /var/tmp --dir /home --dir /sandbox-bin
        --bind "$sandbox_home" /home/agent --bind "$sandbox_session" /session
        --overlay-src "$worktree" --overlay "$sandbox_upper" "$sandbox_work" /workspace
        --ro-bind "$deny_file" /workspace/.git --ro-bind "$deny_dir" /workspace/.automerger
        --clearenv --setenv HOME /home/agent --setenv USER agent --setenv LOGNAME agent
        --setenv PATH /session/bin:/sandbox-bin:/usr/local/bin:/usr/bin:/bin --setenv LANG "${LANG:-C.UTF-8}"
        --unsetenv DISPLAY --unsetenv WAYLAND_DISPLAY --unsetenv DBUS_SESSION_BUS_ADDRESS
        --chdir /workspace
    )
    mkdir -p -- "$sandbox_session/bin"
    for file in codex claude; do
        tool_binary="$(command -v "$file" 2>/dev/null || true)"
        tool_binary="$(realpath -e -- "$tool_binary" 2>/dev/null || true)"
        [[ -z "$tool_binary" ]] || sandbox_command+=(--ro-bind "$tool_binary" "/sandbox-bin/$file")
    done
    tool_binary="$(command -v openhands 2>/dev/null || true)"
    tool_binary="$(realpath -e -- "$tool_binary" 2>/dev/null || true)"
    if [[ -n "$tool_binary" ]]; then
        openhands_root="$(dirname -- "$(dirname -- "$tool_binary")")"
        openhands_python="$(realpath -e -- "$openhands_root/bin/python" 2>/dev/null || true)"
        openhands_site_packages="$(find "$openhands_root/lib" -type d -name site-packages -print -quit 2>/dev/null || true)"
        if [[ -n "$openhands_python" && -n "$openhands_site_packages" ]]; then
            openhands_python_root="$(dirname -- "$(dirname -- "$openhands_python")")"
            openhands_python_name="$(basename -- "$openhands_python")"
            sandbox_site_packages="/opt/openhands${openhands_site_packages#"$openhands_root"}"
            sandbox_command+=(
                --ro-bind "$openhands_root" /opt/openhands
                --ro-bind "$openhands_python_root" /opt/openhands-python
            )
            printf '%s\n' \
                '#!/bin/sh' \
                "export VIRTUAL_ENV=/opt/openhands" \
                "export PYTHONPATH=$(shell_quote "$sandbox_site_packages")" \
                "exec /opt/openhands-python/bin/$(shell_quote "$openhands_python_name") /opt/openhands/bin/openhands \"\$@\"" \
                >"$sandbox_session/bin/openhands"
            chmod 700 -- "$sandbox_session/bin/openhands"
        fi
    fi
    for file in HTTPS_PROXY HTTP_PROXY ALL_PROXY NO_PROXY https_proxy http_proxy all_proxy no_proxy; do
        if [[ -n "${!file:-}" ]]; then
            sandbox_command+=(--setenv "$file" "${!file}")
        fi
    done
    sandbox_command+=(-- /bin/bash -c 'printf started > /session/sandbox-started; exec /bin/bash -lc "$1"' _ "$expanded")

    log_start "$MODEL_LOG_PREFIX: $model"
    log_id="$LAST_LOG_ID"
    setsid timeout --foreground --signal=TERM --kill-after=5s "$max_time" "${sandbox_command[@]}" >"$output_file" 2>&1 &
    pid=$!
    set_current "ai" "$pid" "$MODEL_LOG_PREFIX: $model"
    monitor_ai_overlay "$sandbox_upper" "$pid" "$violation_file" "${conflict_files[@]}" &
    monitor_pid=$!
    wait "$pid"
    exit_code=$?
    MODEL_RUN_EXIT_CODE="$exit_code"
    wait "$monitor_pid" 2>/dev/null || true
    clear_current
    if [[ -f "$violation_file" ]]; then
        violation="$(<"$violation_file")"
    else
        violation=""
    fi
    if [[ -z "$violation" ]]; then
        violation="$(find_overlay_violation "$sandbox_upper" "${conflict_files[@]}" || true)"
    fi
    if [[ -n "$violation" ]]; then
        violation_display="$(shell_quote "$violation")"
        AI_SECURITY_VIOLATION="$violation_display"
        exit_code=$AI_SECURITY_FAILURE_EXIT
        MODEL_RUN_FAILURE_KIND="security_violation"
        MODEL_RUN_EXIT_CODE="$exit_code"
        warn "Wykryto złośliwe zachowanie agenta AI: niedozwolona zmiana $violation_display."
    elif ((exit_code == 124)); then
        MODEL_RUN_FAILURE_KIND="timeout"
    elif [[ ! -f "$startup_marker" ]]; then
        MODEL_RUN_FAILURE_KIND="sandbox_start_failure"
    elif ((exit_code != 0)); then
        MODEL_RUN_FAILURE_KIND="model_exit"
    elif ((exit_code == 0)); then
        apply_ai_overlay_changes "$sandbox_upper" "$worktree" "${conflict_files[@]}"
        exit_code=$?
        if ((exit_code != 0)); then
            MODEL_RUN_EXIT_CODE="$exit_code"
            if ((exit_code == AI_SECURITY_FAILURE_EXIT)); then
                MODEL_RUN_FAILURE_KIND="security_violation"
            else
                MODEL_RUN_FAILURE_KIND="overlay_apply_failure"
            fi
        fi
    fi
    if ((exit_code == 0)); then
        log_finish "$log_id" "DONE"
    else
        log_finish "$log_id" "FAIL"
    fi
    run_model_close_command "$model" "$worktree" "$request_file" "$output_file" "$model_session_dir"
    close_exit=$?
    if ((close_exit != 0)); then
        MODEL_RUN_FAILURE_KIND="cleanup_failure"
        MODEL_RUN_EXIT_CODE="$close_exit"
        cleanup_ai_sandbox_dir "$sandbox_dir"
        ACTIVE_AI_SANDBOX=""
        ACTIVE_MODEL_SESSION=""
        return 125
    fi
    cleanup_ai_sandbox_dir "$sandbox_dir"
    ACTIVE_AI_SANDBOX=""
    ACTIVE_MODEL_SESSION=""
    ((exit_code == 0)) || MODEL_RUN_EXIT_CODE="$exit_code"
    return "$exit_code"
}

prepare_title_prompt() {
    local branch="$1"
    local output_file="$2"
    local target_branch_ref branch_ref
    target_branch_ref="$(remote_ref "$TARGET_BRANCH")"
    branch_ref="$(remote_ref "$branch")"
    {
        printf '%s\n' \
            'Na podstawie zmian Git przygotuj bardzo krótki tytuł opisujący branch.' \
            'Użyj hasła złożonego najlepiej z 2-6 słów i maksymalnie 60 znaków.' \
            'Nie twórz pełnego zdania. Preferuj konkretne słowa kluczowe, np. „Cache invalidation” albo „API response types”.' \
            'Nie dodawaj identyfikatora brancha ani kropki na końcu.' \
            'Ostatnia linia odpowiedzi musi mieć dokładnie format: BRANCH_TITLE: <tytuł>' \
            'Tę samą linię zapisz również do /workspace/title.txt.'
        printf '\nBranch: %s\n\nStatystyka zmian:\n' "$branch"
        git -C "$WORKDIR" diff --stat "$target_branch_ref...$branch_ref" 2>/dev/null || true
        printf '\nZmiany (maksymalnie 1200 linii):\n'
        git -C "$WORKDIR" diff --no-ext-diff --unified=2 "$target_branch_ref...$branch_ref" 2>/dev/null \
            | sed -n '1,1200p'
    } >"$output_file"
}

extract_branch_title() {
    local output_file="$1"
    local fallback_file="$2"
    local title
    title="$(
        {
            [[ -f "$output_file" ]] && sed -E $'s/\\x1B\\[[0-9;?]*[ -/]*[@-~]//g' "$output_file"
            [[ -f "$fallback_file" ]] && cat -- "$fallback_file"
        } | sed -E 's/^[[:space:]│┃║]*//; s/[[:space:]│┃║]*$//' \
            | awk '
                /^[[:space:]]*BRANCH_TITLE:[[:space:]]*/ {
                    sub(/^[[:space:]]*BRANCH_TITLE:[[:space:]]*/, "")
                    title=$0
                    collecting=1
                    next
                }
                collecting {
                    if ($0 == "" || $0 ~ /^[╰└┗┌╭┏─━]/ || $0 ~ /^(Goodbye|Conversation ID:|Hint:)/) {
                        collecting=0
                        next
                    }
                    title=title " " $0
                }
                END { print title }
            '
    )"
    title="$(trim "$title")"
    [[ -n "$title" && ${#title} -le 60 && ! "$title" =~ [[:cntrl:]] ]] || return 1
    printf '%s' "$title"
}

resolve_branch_title() {
    local branch="$1"
    local target_sha model request_file output_file title_workspace title
    local max_attempts attempt category message timed_out=false retry_count
    local -a models=()
    MODEL_CONFIG_CONTEXT="title_maker"
    if jq -e --arg branch "$branch" '.branch_info[$branch].title | type == "string" and length > 0' "$BRANCHES_INFO_FILE" >/dev/null 2>&1; then
        state_update --arg branch "$branch" '.branches[$branch].title_status="resolved"'
        return 0
    fi
    mapfile -t models < <(jq -r '.title_maker_models[]' "$CONFIG_FILE")
    if ((${#models[@]} == 0)); then
        state_update --arg branch "$branch" '.branches[$branch].title_status="unavailable"'
        return 1
    fi
    target_sha="$(git -C "$WORKDIR" rev-parse "$(remote_ref "$branch")^{commit}" 2>/dev/null || true)"
    [[ -n "$target_sha" ]] || {
        state_update --arg branch "$branch" '.branches[$branch].title_status="failed"'
        return 1
    }
    request_file="$(mktemp "$STATE_DIR/title-request.XXXXXX")" || return 1
    title_workspace="$(mktemp -d "$STATE_DIR/title-workspace.XXXXXX")" || {
        rm -f -- "$request_file"
        return 1
    }
    : >"$title_workspace/title.txt"
    : >"$title_workspace/.git"
    chmod 000 -- "$title_workspace/.git"
    prepare_title_prompt "$branch" "$request_file"
    state_update --arg branch "$branch" '.branches[$branch].title_status="resolving"'
    for model in "${models[@]}"; do
        max_attempts="$(model_max_attempts "$model")"
        for ((attempt = 1; attempt <= max_attempts; attempt++)); do
            output_file="$(mktemp "$STATE_DIR/title-output.XXXXXX")" || continue
            PROMPT_FILE="$request_file"
            MODEL_LOG_PREFIX="title maker $branch ($attempt/$max_attempts)"
            category=""
            message=""
            if run_ai_model "$model" "$title_workspace" "$request_file" "$output_file" "title.txt"; then
                title="$(extract_branch_title "$output_file" "$title_workspace/title.txt" || true)"
                if [[ -n "$title" ]]; then
                    branch_info_update --arg branch "$branch" --arg title "$title" --arg sha "$target_sha" --argjson at "$(date +%s)" '
                        .branch_info[$branch] = ((.branch_info[$branch] // {}) + {title:$title,target_sha:$sha,resolved_at:$at})
                    '
                    state_update --arg branch "$branch" '.branches[$branch].title_status="resolved"'
                    rm -f -- "$request_file" "$output_file"
                    rm -rf -- "$title_workspace"
                    return 0
                fi
                category="invalid_title_protocol"
                message="Model '$model' nie zwrócił poprawnej linii BRANCH_TITLE albo tytuł przekracza 60 znaków."
            else
                category="${MODEL_RUN_FAILURE_KIND:-model_error}"
                case "$category" in
                    timeout)
                        timed_out=true
                        state_update --arg branch "$branch" '.branches[$branch].title_warning=true'
                        message="Title maker '$model' przekroczył limit $(model_max_working_time "$model") s."
                        ;;
                    sandbox_unavailable)
                        message="${AI_ISOLATION_ERROR:-Nie można uruchomić bezpiecznego sandboxa bubblewrap.}"
                        ;;
                    sandbox_start_failure)
                        message="Bezpieczny sandbox dla title makera '$model' nie uruchomił procesu modelu."
                        ;;
                    security_violation)
                        message="Title maker '$model' wykonał niedozwolony zapis: ${AI_SECURITY_VIOLATION:-nieznane naruszenie}."
                        ;;
                    cleanup_failure)
                        message="Polecenie kończące title makera '$model' zakończyło się błędem."
                        ;;
                    *)
                        message="Proces title makera '$model' zakończył się kodem ${MODEL_RUN_EXIT_CODE:-1}."
                        ;;
                esac
            fi
            write_model_diagnostic "title" "$branch" "$model" "$attempt" "$max_attempts" \
                "${category:-unknown_failure}" "${MODEL_RUN_EXIT_CODE:-1}" \
                "${message:-Title maker nie przygotował tytułu.}" "$output_file" "$request_file"
            warn "$message"
            rm -f -- "$output_file"
            : >"$title_workspace/title.txt"
            if [[ "$category" == "sandbox_unavailable" || "$category" == "security_violation" ]]; then
                break 2
            fi
        done
    done
    retry_count="$(jq -r --arg branch "$branch" '.branches[$branch].title_retry_count // 0' "$STATE_FILE")"
    if [[ "$timed_out" == "true" ]] && ((retry_count < 1)); then
        state_update --arg branch "$branch" --argjson retry_at "$((EPOCHSECONDS + TITLE_RETRY_DELAY_SECONDS))" '
            .branches[$branch].title_status="retry"
            | .branches[$branch].title_warning=true
            | .branches[$branch].title_retry_at=$retry_at
            | .branches[$branch].title_retry_count=((.branches[$branch].title_retry_count // 0) + 1)
        '
    else
        state_update --arg branch "$branch" '.branches[$branch].title_status="failed"'
    fi
    rm -f -- "$request_file"
    rm -rf -- "$title_workspace"
    return 1
}

model_context_failure_message() {
    local context="$1" model="$2" category="$3"
    case "$category" in
        timeout) printf '%s: model %s przekroczył limit czasu.' "$context" "$model" ;;
        sandbox_unavailable) printf '%s: bezpieczny sandbox modelu jest niedostępny.' "$context" ;;
        security_violation) printf '%s: model wykonał niedozwolony zapis.' "$context" ;;
        *) printf '%s: model %s zakończył się błędem (%s).' "$context" "$model" "${MODEL_RUN_EXIT_CODE:-1}" ;;
    esac
}

prepare_ask_request() {
    local question="$1" request_file="$2"
    {
        printf '%s\n\n' 'Jesteś asystentem diagnostycznym automergera Bash. Odpowiadasz po polsku, konkretnie i wyłącznie na podstawie dostarczonego stanu. Nie uruchamiaj poleceń, nie zmieniaj plików i nie zgaduj. Jeśli danych brakuje, powiedz czego brakuje.'
        printf 'Pytanie użytkownika: %s\n\n' "$question"
        printf '%s\n' 'Uwaga na jednostki: merge_cooldown_time, merge_cooldown_time_m_default oraz min_time_between_merges_m są wyrażone w MINUTACH, nie w sekundach; wartość "auto" oznacza użycie merge_cooldown_time_m_default. Pierwsze dwa pola ograniczają ponowny merge tego samego brancha, a min_time_between_merges_m określa globalną przerwę po udanym merge przed rozpoczęciem kolejnego. W odpowiedzi zawsze podawaj jednostkę minut.'
        printf '%s\n' 'Konfiguracja (bez ciphertextu tokenu):'
        jq 'del(.github_access_token_encrypted)' "$CONFIG_FILE"
        printf '\nStan runtime:\n'
        jq '.branches, .logs[-12:]' "$STATE_FILE" 2>/dev/null || printf '(brak stanu runtime)\n'
        printf '\nTytuły ticketów:\n'
        jq '.branch_info' "$BRANCHES_INFO_FILE" 2>/dev/null || printf '(brak)\n'
        printf '\nOdpowiedź zapisz w pliku answer.txt; maksymalnie 25 krótkich wierszy.\n'
    } >"$request_file"
}

ask_automerger() {
    local question="$1" request_file workspace output_file model answer max_attempts attempt original_prompt category message
    local -a models=()
    [[ -n "$question" ]] || { operation_error "Użycie: ask PYTANIE"; return 1; }
    mapfile -t models < <(jq -r '.ask_models[]?' "$CONFIG_FILE")
    ((${#models[@]} > 0)) || { operation_error "Brak modeli w ask_models."; return 1; }
    request_file="$(mktemp "$STATE_DIR/ask-request.XXXXXX")" || return 1
    workspace="$(mktemp -d "$STATE_DIR/ask-workspace.XXXXXX")" || { rm -f -- "$request_file"; return 1; }
    : >"$workspace/answer.txt"
    : >"$workspace/.git"
    chmod 000 -- "$workspace/.git"
    prepare_ask_request "$question" "$request_file"
    original_prompt="$PROMPT_FILE"
    MODEL_CONFIG_CONTEXT="ask"
    for model in "${models[@]}"; do
        max_attempts="$(model_max_attempts "$model" "ask")"
        for ((attempt = 1; attempt <= max_attempts; attempt++)); do
            output_file="$(mktemp "$STATE_DIR/ask-output.XXXXXX")" || continue
            PROMPT_FILE="$request_file"
            MODEL_LOG_PREFIX="ask ($attempt/$max_attempts)"
            if run_ai_model "$model" "$workspace" "$request_file" "$output_file" "answer.txt"; then
                answer="$(trim "$(cat -- "$workspace/answer.txt" 2>/dev/null)")"
                [[ -n "$answer" ]] || answer="$(trim "$(sed -E $'s/\\x1B\\[[0-9;?]*[ -/]*[@-~]//g' "$output_file")")"
                if [[ -n "$answer" ]]; then
                    PROMPT_FILE="$original_prompt"
                    rm -f -- "$request_file" "$output_file"
                    rm -rf -- "$workspace"
                    if [[ "$TUI_ACTIVE" == "true" ]]; then
                        show_notice "Odpowiedź automergera" "$(truncate_text "$answer" 5000)"
                    else
                        printf '%s\n' "$answer"
                    fi
                    record_command_success "ask: $question"
                    return 0
                fi
                category="invalid_answer_protocol"
                message="Model '$model' nie przygotował odpowiedzi."
            else
                category="${MODEL_RUN_FAILURE_KIND:-model_error}"
                message="$(model_context_failure_message ask "$model" "$category")"
            fi
            write_model_diagnostic "ask" "interactive" "$model" "$attempt" "$max_attempts" "$category" "${MODEL_RUN_EXIT_CODE:-1}" "$message" "$output_file" "$request_file"
            rm -f -- "$output_file"
            [[ "$category" == "sandbox_unavailable" || "$category" == "security_violation" ]] && break 2
        done
    done
    PROMPT_FILE="$original_prompt"
    rm -f -- "$request_file"
    rm -rf -- "$workspace"
    operation_error "Żaden model ask_models nie przygotował odpowiedzi; szczegóły są w logach modeli."
    return 1
}

start_ask_background() {
    local question="$1"
    [[ -z "$ASK_PID" ]] || {
        if kill -0 "$ASK_PID" 2>/dev/null; then
            operation_error "Trwa już analiza ask. Poczekaj na jej wynik."
            return 1
        fi
        wait "$ASK_PID" 2>/dev/null || true
        ASK_PID=""
    }
    ASK_OUTPUT_FILE="$(mktemp "$STATE_DIR/ask-result.XXXXXX")" || return 1
    ASK_QUESTION="$question"
    (
        TUI_ACTIVE=false
        ask_automerger "$question"
    ) >"$ASK_OUTPUT_FILE" 2>&1 &
    ASK_PID=$!
    record_command_success "ask: rozpoczęto analizę w tle"
}

show_completed_ask() {
    local exit_code answer
    [[ -n "$ASK_PID" ]] || return 1
    kill -0 "$ASK_PID" 2>/dev/null && return 1
    wait "$ASK_PID"
    exit_code=$?
    ASK_PID=""
    answer="$(cat -- "$ASK_OUTPUT_FILE" 2>/dev/null || true)"
    rm -f -- "$ASK_OUTPUT_FILE"
    ASK_OUTPUT_FILE=""
    if ((exit_code == 0)) && [[ -n "$(trim "$answer")" ]]; then
        show_notice "Odpowiedź automergera" "$(truncate_text "$answer" 5000)"
    elif ((exit_code != 0)); then
        show_notice "Ask — błąd" "${answer:-Nie udało się uzyskać odpowiedzi. Szczegóły są w logach modeli.}"
    fi
    ASK_QUESTION=""
    return 0
}

prepare_autorepair_request() {
    local note="$1" request_file="$2"
    {
        printf '%s\n\n' 'Jesteś konserwatorem automerger.sh. Zdiagnozuj zgłoszenie i logi, a następnie popraw WYŁĄCZNIE plik /workspace/automerger.sh. Zachowaj istniejący styl Bash 5, nie usuwaj mechanizmów bezpieczeństwa, nie zmieniaj tokenów ani konfiguracji. Na końcu uruchom bash -n /workspace/automerger.sh. Jeśli poprawka nie jest uzasadniona, nie zmieniaj pliku i opisz powód w repair-notes.md.'
        printf 'Zgłoszenie użytkownika: %s\n\n' "${note:-Brak dodatkowego opisu — zdiagnozuj ostatnie błędy.}"
        printf 'Istotne ustawienia (bez tokenu):\n'
        jq '{workdir,remote,target_branch,tracked_branches,automerge_simple_models,automerge_all_models,title_maker_models,ask_models,autorepair_models}' "$CONFIG_FILE"
        printf '\nOstatnie wpisy operation log:\n'
        jq '.logs[-24:]' "$STATE_FILE" 2>/dev/null || true
        printf '\nOstatnie indeksy błędów modeli:\n'
        find "$MODEL_LOG_DIR" -type f -name errors.jsonl -print0 2>/dev/null | while IFS= read -r -d '' file; do tail -n 8 -- "$file"; done
        printf '\nZapisz krótkie uzasadnienie w /workspace/repair-notes.md.\n'
    } >"$request_file"
}

autorepair_automerger() {
    local note="$1" request_file workspace output_file model max_attempts attempt original_prompt category message
    local backup_dir backup_file notes changed=false
    local -a models=()
    mapfile -t models < <(jq -r '.autorepair_models[]?' "$CONFIG_FILE")
    ((${#models[@]} > 0)) || { operation_error "Brak modeli w autorepair_models."; return 1; }
    backup_dir="$SCRIPT_DIR/backups"
    mkdir -p -- "$backup_dir" && chmod 700 -- "$backup_dir" || { operation_error "Nie można utworzyć katalogu kopii autorepair."; return 1; }
    backup_file="$backup_dir/automerger-$(date +%Y%m%d-%H%M%S).sh"
    cp -p -- "$SCRIPT_PATH" "$backup_file" || { operation_error "Nie można utworzyć kopii automerger.sh."; return 1; }
    chmod 600 -- "$backup_file"
    request_file="$(mktemp "$STATE_DIR/autorepair-request.XXXXXX")" || return 1
    workspace="$(mktemp -d "$STATE_DIR/autorepair-workspace.XXXXXX")" || { rm -f -- "$request_file"; return 1; }
    cp -p -- "$SCRIPT_PATH" "$workspace/automerger.sh"
    : >"$workspace/repair-notes.md"
    : >"$workspace/.git"
    chmod 000 -- "$workspace/.git"
    prepare_autorepair_request "$note" "$request_file"
    original_prompt="$PROMPT_FILE"
    MODEL_CONFIG_CONTEXT="autorepair"
    for model in "${models[@]}"; do
        max_attempts="$(model_max_attempts "$model" "autorepair")"
        for ((attempt = 1; attempt <= max_attempts; attempt++)); do
            output_file="$(mktemp "$STATE_DIR/autorepair-output.XXXXXX")" || continue
            PROMPT_FILE="$request_file"
            MODEL_LOG_PREFIX="autorepair ($attempt/$max_attempts)"
            if run_ai_model "$model" "$workspace" "$request_file" "$output_file" "automerger.sh" "repair-notes.md"; then
                if cmp -s -- "$SCRIPT_PATH" "$workspace/automerger.sh"; then
                    category="no_repair"
                    message="Model '$model' nie przygotował zmiany automerger.sh."
                elif bash -n "$workspace/automerger.sh"; then
                    cp -p -- "$workspace/automerger.sh" "$SCRIPT_PATH"
                    chmod 700 -- "$SCRIPT_PATH"
                    notes="$(trim "$(cat -- "$workspace/repair-notes.md" 2>/dev/null)")"
                    changed=true
                    PROMPT_FILE="$original_prompt"
                    rm -f -- "$request_file" "$output_file"
                    rm -rf -- "$workspace"
                    show_notice "Autorepair zakończony" "Zastosowano poprawkę. Kopia: $backup_file\n\n${notes:-Brak opisu modelu.}"
                    record_command_success "autorepair: zastosowano poprawkę (kopia: $(basename -- "$backup_file"))"
                    return 0
                else
                    category="invalid_repair_syntax"
                    message="Model '$model' przygotował skrypt z błędem składni; poprawka nie została zastosowana."
                fi
            else
                category="${MODEL_RUN_FAILURE_KIND:-model_error}"
                message="$(model_context_failure_message autorepair "$model" "$category")"
            fi
            write_model_diagnostic "autorepair" "automerger.sh" "$model" "$attempt" "$max_attempts" "$category" "${MODEL_RUN_EXIT_CODE:-1}" "$message" "$output_file" "$request_file"
            rm -f -- "$output_file"
            [[ "$category" == "sandbox_unavailable" || "$category" == "security_violation" ]] && break 2
        done
    done
    PROMPT_FILE="$original_prompt"
    rm -f -- "$request_file"
    rm -rf -- "$workspace"
    operation_error "Autorepair nie zastosował poprawki; kopia bezpieczeństwa pozostaje w $backup_file."
    return 1
}

branch_tracking_group() {
    local branch="$1" policy
    policy="$(jq -r --arg branch "$branch" '.tracked_branches[$branch].policy // "untracked"' "$CONFIG_FILE" 2>/dev/null || true)"
    case "$policy" in
        "$POLICY_MANUAL" | "$POLICY_BASIC" | "$POLICY_AI_SIMPLE")
            printf '%s' "$policy"
            ;;
        "$POLICY_AI_ALL")
            printf 'ai_automerge_full'
            ;;
        *)
            printf 'untracked'
            ;;
    esac
}

branch_title_label() {
    local branch="$1"
    local show_tracking="${2:-false}"
    local title status prefix="$branch"
    if [[ "$show_tracking" == "true" ]]; then
        prefix+=" [$(branch_tracking_group "$branch")]"
    fi
    title="$(jq -r --arg branch "$branch" '.branch_info[$branch].title // ""' "$BRANCHES_INFO_FILE" 2>/dev/null || true)"
    if [[ -n "$title" ]]; then
        printf '%s - %s' "$prefix" "$title"
        return
    fi
    status="$(jq -r --arg branch "$branch" '.branches[$branch].title_status // ""' "$STATE_FILE" 2>/dev/null || true)"
    case "$status" in
        resolving) printf '%s [resolving title]' "$prefix" ;;
        retry) printf '%s [title retry pending] \033[38;5;208m[!]\033[0m' "$prefix" ;;
        failed) printf '%s [title unresolved]' "$prefix" ;;
        unavailable) printf '%s [title maker not configured]' "$prefix" ;;
        *) printf '%s' "$prefix" ;;
    esac
}

render_title_candidates() {
    local index line status resolving=false frame=$'\033[H\033[1mWybierz branche do śledzenia\033[0m\n\n'
    local -a candidates=("$@")
    for index in "${!candidates[@]}"; do
        line="$(branch_title_label "${candidates[$index]}" true)"
        frame+="  $((index + 1))) $line"$'\033[K\n'
        status="$(jq -r --arg branch "${candidates[$index]}" '.branches[$branch].title_status // ""' "$STATE_FILE" 2>/dev/null || true)"
        [[ "$status" == "resolving" || "$status" == "retry" ]] && resolving=true
    done
    if [[ "$resolving" == "true" ]]; then
        frame+=$'\nTrwa przygotowanie brakujących tytułów (maks. 3 modele jednocześnie)...\033[K\033[J\n'
    else
        frame+=$'\nRozpoznawanie tytułów zakończone. Wybierz numery branchy.\033[K\033[J\n'
    fi
    printf '%s' "$frame" >&2
}

resolve_candidate_titles() {
    local branch pid
    local -a candidates=("$@")
    local -a pids=()
    trap 'for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done; exit 143' TERM INT
    for branch in "${candidates[@]}"; do
        if jq -e --arg branch "$branch" '.branch_info[$branch].title | type == "string" and length > 0' "$BRANCHES_INFO_FILE" >/dev/null 2>&1; then
            continue
        fi
        (
            trap 'terminate_child_processes "$BASHPID"; exit 143' TERM INT
            resolve_branch_title "$branch"
        ) &
        pids+=("$!")
        if ((${#pids[@]} >= MAX_CONCURRENT_TITLE_MAKERS)); then
            wait "${pids[0]}" 2>/dev/null || true
            pids=("${pids[@]:1}")
        fi
    done
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    trap - TERM INT
}

resolve_title_queue() {
    local branch empty_checks=0
    local -a batch=()
    while true; do
        mapfile -t batch < <(jq -r '(.title_queue // [])[0:3][]' "$STATE_FILE")
        if ((${#batch[@]} == 0)); then
            ((++empty_checks))
            ((empty_checks >= 5)) && break
            sleep 0.2
            continue
        fi
        empty_checks=0
        state_update --argjson batch "$(printf '%s\n' "${batch[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
            .title_queue = ((.title_queue // []) - $batch)
        '
        resolve_candidate_titles "${batch[@]}"
        batch=()
    done
}

terminate_child_processes() {
    local parent_pid="$1" child
    local -a children=()
    if [[ -r "/proc/$parent_pid/task/$parent_pid/children" ]]; then
        read -r -a children <"/proc/$parent_pid/task/$parent_pid/children" || true
    fi
    for child in "${children[@]}"; do
        [[ "$child" =~ ^[0-9]+$ && "$child" -gt 1 ]] || continue
        kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
    done
}

start_candidate_title_resolution() {
    local branch branches_json
    local -a candidates=("$@")
    ((${#candidates[@]} > 0)) || return 0
    for branch in "${candidates[@]}"; do
        if ! jq -e --arg branch "$branch" \
            '.branch_info[$branch].title | type == "string" and length > 0' \
            "$BRANCHES_INFO_FILE" >/dev/null 2>&1; then
            state_update --arg branch "$branch" '.branches[$branch].title_status="resolving"'
        fi
    done
    branches_json="$(printf '%s\n' "${candidates[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
    state_update --argjson branches "$branches_json" '
        .title_queue = (((.title_queue // []) + $branches) | unique)
    '
    if [[ -n "$TITLE_RESOLVER_PID" ]] && kill -0 "$TITLE_RESOLVER_PID" 2>/dev/null; then
        return 0
    fi
    resolve_title_queue >/dev/null 2>&1 &
    TITLE_RESOLVER_PID=$!
}

schedule_due_title_retries() {
    local now branch
    local -a due=()
    now="$(date +%s)"
    mapfile -t due < <(jq -r --argjson now "$now" '
        .branches | to_entries[]
        | select(.value.title_status == "retry" and (.value.title_retry_at // 0) <= $now)
        | .key
    ' "$STATE_FILE")
    ((${#due[@]} > 0)) || return 0
    for branch in "${due[@]}"; do
        state_update --arg branch "$branch" '.branches[$branch].title_status="resolving"'
    done
    start_candidate_title_resolution "${due[@]}"
}

extract_model_status() {
    local output_file="$1"
    sed -E $'s/\\x1B\\[[0-9;?]*[ -/]*[@-~]//g' "$output_file" \
        | grep -Eo 'CONFLICTS_RESOLVE_SUCCESS|CONFLICT_RESOLVE_FAILURE|CONFLICT_RESOLVE_NEED_ATTENTION' \
        | tail -n1
}

validate_ai_changes() {
    local worktree="$1"
    shift
    local -a conflict_files=("$@")
    local file details
    AI_VALIDATION_ERROR=""
    ((${#conflict_files[@]} > 0)) || {
        AI_VALIDATION_ERROR="Model AI nie otrzymał listy konfliktów."
        warn "$AI_VALIDATION_ERROR"
        return 1
    }
    details="$(git -C "$worktree" ls-files --others --exclude-standard)"
    [[ -z "$details" ]] || {
        AI_VALIDATION_ERROR="Model AI utworzył pliki spoza merge: $details"
        warn "$AI_VALIDATION_ERROR"
        return 1
    }

    local -a exclusions=()
    for file in "${conflict_files[@]}"; do
        exclusions+=(":(exclude)$file")
    done
    details="$(git -C "$worktree" diff --name-only -- . "${exclusions[@]}")"
    [[ -z "$details" ]] || {
        AI_VALIDATION_ERROR="Model AI zmienił pliki, które nie były konfliktujące: $details"
        warn "$AI_VALIDATION_ERROR"
        return 1
    }
    for file in "${conflict_files[@]}"; do
        if [[ -e "$worktree/$file" ]] && grep -Eq '^(<<<<<<< |=======|>>>>>>> )' "$worktree/$file"; then
            AI_VALIDATION_ERROR="Model AI pozostawił markery konfliktu w pliku $file."
            warn "$AI_VALIDATION_ERROR"
            return 1
        fi
    done
    git -C "$worktree" add -A -- "${conflict_files[@]}" || {
        AI_VALIDATION_ERROR="Nie udało się dodać rozwiązanych plików do indeksu."
        warn "$AI_VALIDATION_ERROR"
        return 1
    }
    details="$(git -C "$worktree" diff --name-only --diff-filter=U)"
    [[ -z "$details" ]] || {
        AI_VALIDATION_ERROR="Model AI pozostawił nierozwiązane konflikty: $details"
        warn "$AI_VALIDATION_ERROR"
        return 1
    }
    if ! details="$(git -C "$worktree" diff --cached --check -- "${conflict_files[@]}" 2>&1)"; then
        AI_VALIDATION_ERROR="Rozwiązanie AI nie przechodzi git diff --check: ${details:-git diff --check zakończył się bez komunikatu}"
        warn "Rozwiązanie AI nie przechodzi git diff --check."
        return 1
    fi
    return 0
}

attempt_ai_merge() {
    local branch="$1"
    local policy="$2"
    local target_sha="$3"
    local target_branch_sha="$4"
    local model worktree request_file output_file merge_exit model_status
    local max_attempts attempt category message commit_error
    local -a models=() conflict_files=()
    MODEL_CONFIG_CONTEXT="$policy"

    if [[ "$policy" == "$POLICY_AI_ALL" ]]; then
        mapfile -t models < <(jq -r '.automerge_all_models[]' "$CONFIG_FILE")
    else
        mapfile -t models < <(jq -r '.automerge_simple_models[]' "$CONFIG_FILE")
    fi
    if ((${#models[@]} == 0)); then
        state_update --arg branch "$branch" --arg policy "$policy" '
            .branches[$branch].error=("Brak skonfigurowanych modeli dla polityki " + $policy + ".")
        '
        return 1
    fi

    for model in "${models[@]}"; do
        max_attempts="$(model_max_attempts "$model" "$policy")"
        for ((attempt = 1; attempt <= max_attempts; attempt++)); do
            if [[ -e "$STOP_FILE" ]]; then
                state_update --arg branch "$branch" '
                    .branches[$branch].error="Operacja AI została zatrzymana przez użytkownika."
                    | .branches[$branch].retry_allowed=true
                '
                return 1
            fi
            worktree="$(create_worktree "$target_sha")" || {
                write_model_diagnostic "merge" "$branch" "$model" "$attempt" "$max_attempts" \
                    "worktree_creation_failure" 1 "Nie udało się utworzyć tymczasowego worktree." "" ""
                continue
            }
            ACTIVE_WORKTREE="$worktree"
            git -C "$worktree" -c user.name="$GIT_USER_NAME" -c user.email="$GIT_USER_EMAIL" \
                merge --no-commit --no-ff "$target_branch_sha" >/dev/null 2>&1
            merge_exit=$?
            if ((merge_exit == 0)); then
                if git -C "$worktree" -c user.name="$GIT_USER_NAME" -c user.email="$GIT_USER_EMAIL" \
                    commit -m "$(merge_commit_message "$branch")" >/dev/null 2>&1; then
                    printf '%s' "$worktree"
                    ACTIVE_WORKTREE=""
                    return 0
                fi
                write_model_diagnostic "merge" "$branch" "$model" "$attempt" "$max_attempts" \
                    "git_commit_failure" 1 "Merge bez konfliktu nie mógł zostać zacommitowany." "" ""
                cleanup_worktree "$worktree"
                ACTIVE_WORKTREE=""
                continue
            fi
            if [[ "$policy" == "$POLICY_AI_SIMPLE" ]] && ! conflicts_are_simple "$worktree"; then
                state_update --arg branch "$branch" '.branches[$branch].error="Rzeczywisty merge zawiera konflikt spoza autoresolve_files_list."'
                cleanup_worktree "$worktree"
                ACTIVE_WORKTREE=""
                return 1
            fi
            conflict_files=()
            while IFS= read -r -d '' file; do
                conflict_files+=("$file")
            done < <(git -C "$worktree" diff --name-only --diff-filter=U -z)
            if ((${#conflict_files[@]} == 0)); then
                write_model_diagnostic "merge" "$branch" "$model" "$attempt" "$max_attempts" \
                    "missing_conflict_files" "$merge_exit" "Git zgłosił konflikt, ale nie zwrócił konfliktujących plików." "" ""
                cleanup_worktree "$worktree"
                ACTIVE_WORKTREE=""
                continue
            fi
            request_file="$STATE_DIR/request-${model//[^A-Za-z0-9_.-]/_}-${attempt}-$$-$RANDOM.md"
            output_file="$STATE_DIR/output-${model//[^A-Za-z0-9_.-]/_}-${attempt}-$$-$RANDOM.log"
            prepare_ai_prompt "$worktree" "$branch" "$target_branch_sha" "$request_file"
            MODEL_LOG_PREFIX="model AI ($attempt/$max_attempts)"
            category=""
            message=""
            if run_ai_model "$model" "$worktree" "$request_file" "$output_file" "${conflict_files[@]}"; then
                model_status="$(extract_model_status "$output_file")"
                if [[ "$model_status" == "CONFLICT_RESOLVE_NEED_ATTENTION" ]]; then
                    message="Model '$model' wymaga decyzji człowieka; automatyzacja zostaje zatrzymana."
                    write_model_diagnostic "merge" "$branch" "$model" "$attempt" "$max_attempts" \
                        "needs_attention" 0 "$message" "$output_file" "$request_file"
                    warn "$message"
                    state_update --arg branch "$branch" --arg model "$model" '
                        .branches[$branch].action_state="attention"
                        | .branches[$branch].error=("Model " + $model + " wymaga decyzji człowieka.")
                    '
                    touch "$STOP_FILE"
                    rm -f -- "$request_file" "$output_file"
                    cleanup_worktree "$worktree"
                    ACTIVE_WORKTREE=""
                    return 1
                elif [[ "$model_status" != "CONFLICTS_RESOLVE_SUCCESS" ]]; then
                    category="invalid_model_protocol"
                    message="Model '$model' nie zwrócił końcowego statusu CONFLICTS_RESOLVE_SUCCESS; otrzymano '${model_status:-brak statusu}'."
                    warn "Model '$model' nie zwrócił końcowego statusu CONFLICTS_RESOLVE_SUCCESS."
                elif ! validate_ai_changes "$worktree" "${conflict_files[@]}"; then
                    category="validation_failure"
                    message="${AI_VALIDATION_ERROR:-Zmiany modelu nie przeszły walidacji.}"
                    warn "Zmiany modelu '$model' nie przeszły walidacji."
                else
                    commit_error="$(git -C "$worktree" -c user.name="$GIT_USER_NAME" -c user.email="$GIT_USER_EMAIL" \
                        commit -m "$(merge_commit_message "$branch")" 2>&1)"
                    if [[ $? -ne 0 ]]; then
                        category="git_commit_failure"
                        message="Nie udało się utworzyć commita po pracy modelu '$model': $commit_error"
                        warn "Nie udało się utworzyć commita po pracy modelu '$model'."
                    else
                        rm -f -- "$request_file" "$output_file"
                        printf '%s' "$worktree"
                        ACTIVE_WORKTREE=""
                        return 0
                    fi
                fi
            else
                category="${MODEL_RUN_FAILURE_KIND:-model_error}"
                case "$category" in
                    timeout)
                        message="Model '$model' przekroczył limit $(model_max_working_time "$model") s."
                        warn "$message"
                        ;;
                    sandbox_unavailable)
                        message="${AI_ISOLATION_ERROR:-Nie można uruchomić bezpiecznego sandboxa bubblewrap.}"
                        warn "$message"
                        ;;
                    sandbox_start_failure)
                        message="Bezpieczny sandbox dla modelu '$model' nie uruchomił procesu modelu."
                        warn "$message"
                        ;;
                    security_violation)
                        message="Wykryto niedozwolone zachowanie modelu '$model': ${AI_SECURITY_VIOLATION:-nieznane naruszenie}."
                        warn "$message"
                        ;;
                    cleanup_failure)
                        message="Polecenie kończące model '$model' zakończyło się błędem."
                        warn "$message"
                        ;;
                    *)
                        message="Proces modelu '$model' zakończył się kodem ${MODEL_RUN_EXIT_CODE:-1}."
                        warn "$message"
                        ;;
                esac
            fi
            write_model_diagnostic "merge" "$branch" "$model" "$attempt" "$max_attempts" \
                "${category:-unknown_failure}" "${MODEL_RUN_EXIT_CODE:-1}" \
                "${message:-Model nie dostarczył poprawnego rozwiązania.}" "$output_file" "$request_file"

            if [[ "$category" == "sandbox_unavailable" || "$category" == "security_violation" ]]; then
                state_update --arg branch "$branch" --arg error "$message" '
                    .branches[$branch].error=$error | .branches[$branch].action_state="fail"
                '
                rm -f -- "$request_file" "$output_file"
                cleanup_worktree "$worktree"
                ACTIVE_WORKTREE=""
                return 1
            fi

            warn "Model '$model' nie dostarczył poprawnego rozwiązania; próba $attempt/$max_attempts zostanie wycofana."
            rm -f -- "$request_file" "$output_file"
            cleanup_worktree "$worktree"
            ACTIVE_WORKTREE=""
            if [[ -e "$STOP_FILE" ]]; then
                state_update --arg branch "$branch" '
                    .branches[$branch].error="Operacja AI została zatrzymana przez użytkownika."
                    | .branches[$branch].retry_allowed=true
                '
                return 1
            fi
        done
    done
    state_update --arg branch "$branch" --arg policy "$policy" '
        .branches[$branch].error=("Wyczerpano listę modeli fallback dla polityki " + $policy + ". Wymagana jest zmiana konfiguracji lub ręczny restart.")
    '
    return 1
}

record_merge_success() {
    local branch="$1"
    local target_branch_sha="$2"
    local target_sha="$3"
    local merge_sha="$4"
    local now
    now="$(date +%s)"
    config_update --arg branch "$branch" --arg dev "$target_branch_sha" --arg target "$target_sha" --argjson now "$now" '
        if .tracked_branches[$branch] then
            .tracked_branches[$branch].last_merged_at=$now
            | .tracked_branches[$branch].last_merged_target_branch_sha=$dev
            | .tracked_branches[$branch].last_merged_target_sha=$target
        else . end
    '
    state_update --arg branch "$branch" --arg merge "$merge_sha" --argjson now "$now" '
        .branches[$branch].action_state="merged"
        | .branches[$branch].mergeability="up to date"
        | .branches[$branch].up_to_date=true
        | .branches[$branch].merge_sha=$merge
        | .branches[$branch].error=""
        | .last_successful_merge_at=$now
        | del(.branches[$branch].failed_target_branch_sha, .branches[$branch].failed_target_sha, .branches[$branch].retry_allowed)
    '
}

perform_merge() {
    local branch="$1"
    local policy_override="${2:-}"
    local policy classification target_branch_sha target_sha current_target_branch current_target
    local worktree merge_sha log_id push_output push_error tracked_remote
    if [[ -n "$policy_override" ]]; then
        policy="$policy_override"
    else
        policy="$(jq -r --arg branch "$branch" '.tracked_branches[$branch].policy' "$CONFIG_FILE")"
    fi
    classification="$(jq -r --arg branch "$branch" '.branches[$branch].mergeability // "conflicts"' "$STATE_FILE")"
    target_branch_sha="$(jq -r --arg branch "$branch" '.branches[$branch].target_branch_sha // ""' "$STATE_FILE")"
    target_sha="$(jq -r --arg branch "$branch" '.branches[$branch].target_sha // ""' "$STATE_FILE")"
    current_target_branch="$(git -C "$WORKDIR" rev-parse refs/automerger/target^{commit} 2>/dev/null || true)"
    current_target="$(git -C "$WORKDIR" rev-parse "$(remote_ref "$branch")^{commit}" 2>/dev/null || true)"
    if [[ -z "$target_branch_sha" || "$target_branch_sha" != "$current_target_branch" || "$target_sha" != "$current_target" ]]; then
        classify_branch "$branch" >/dev/null || return 1
        return 2
    fi
    if [[ "$policy" == "$POLICY_BASIC" && "$classification" != "mergable" ]] \
        || [[ "$policy" == "$POLICY_AI_SIMPLE" && "$classification" == "conflicts" ]] \
        || [[ "$policy" == "$POLICY_MANUAL" ]]; then
        state_update --arg branch "$branch" '.branches[$branch].action_state="skipped"'
        return 1
    fi

    state_update --arg branch "$branch" '.branches[$branch].action_state="merging" | .branches[$branch].error=""'
    log_start "merge $TARGET_BRANCH -> $branch"
    log_id="$LAST_LOG_ID"
    if [[ "$classification" == "mergable" ]]; then
        worktree="$(create_worktree "$target_sha")" || worktree=""
        if [[ -n "$worktree" ]]; then
            ACTIVE_WORKTREE="$worktree"
            if ! git -C "$worktree" -c user.name="$GIT_USER_NAME" -c user.email="$GIT_USER_EMAIL" \
                merge --no-commit --no-ff "$target_branch_sha" >/dev/null 2>&1 \
                || ! git -C "$worktree" -c user.name="$GIT_USER_NAME" -c user.email="$GIT_USER_EMAIL" \
                    commit -m "$(merge_commit_message "$branch")" >/dev/null 2>&1; then
                cleanup_worktree "$worktree"
                ACTIVE_WORKTREE=""
                worktree=""
            fi
        fi
    else
        worktree="$(attempt_ai_merge "$branch" "$policy" "$target_sha" "$target_branch_sha" || true)"
    fi

    if [[ -z "$worktree" || ! -d "$worktree" ]]; then
        log_finish "$log_id" "FAIL"
        state_update --arg branch "$branch" --arg dev "$target_branch_sha" --arg target "$target_sha" '
            if .branches[$branch].retry_allowed == true then
                .branches[$branch].action_state="fail"
                | del(.branches[$branch].retry_allowed, .branches[$branch].failed_target_branch_sha, .branches[$branch].failed_target_sha)
            else
                .branches[$branch].failed_target_branch_sha=$dev
                | .branches[$branch].failed_target_sha=$target
                | if .branches[$branch].action_state == "attention" then .
                  else .branches[$branch].action_state="fail"
                    | if (.branches[$branch].error // "") == "" then
                        .branches[$branch].error="Merge lub rozwiązanie konfliktów nie powiodło się."
                      else . end
                  end
            end
        '
        return 1
    fi
    merge_sha="$(git -C "$worktree" rev-parse HEAD)"
    if [[ "$PUSH_AFTER_MERGE" == "true" ]]; then
        push_output="$STATE_DIR/push-${branch//[^A-Za-z0-9_.-]/_}-$$-$RANDOM.log"
        if ! git -C "$worktree" push "$REMOTE" "HEAD:refs/heads/$branch" >"$push_output" 2>&1; then
            push_error="$(tail -n 5 -- "$push_output" 2>/dev/null | tr '\r\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
            cleanup_worktree "$worktree"
            ACTIVE_WORKTREE=""
            log_finish "$log_id" "FAIL"
            state_update --arg branch "$branch" --arg dev "$target_branch_sha" --arg target "$target_sha" \
                --arg error "${push_error:-brak komunikatu Git; szczegóły: $push_output}" '
                .branches[$branch].action_state="fail"
                | .branches[$branch].error=("Push został odrzucony: " + $error)
                | .branches[$branch].failed_target_branch_sha=$dev
                | .branches[$branch].failed_target_sha=$target
            '
            return 1
        fi
        rm -f -- "$push_output"
        tracked_remote="$(git -C "$WORKDIR" rev-parse "$(remote_ref "$branch")^{commit}" 2>/dev/null || true)"
        if [[ "$tracked_remote" == "$target_sha" ]]; then
            git -C "$WORKDIR" update-ref "$(remote_ref "$branch")" "$merge_sha" "$target_sha" 2>/dev/null || true
        fi
    else
        git -C "$WORKDIR" update-ref "refs/automerger/results/$branch" "$merge_sha"
    fi
    cleanup_worktree "$worktree"
    ACTIVE_WORKTREE=""
    record_merge_success "$branch" "$target_branch_sha" "$target_sha" "$merge_sha"
    log_finish "$log_id" "DONE"
    return 0
}

perform_one_shot_merge() {
    local branch="$1"
    fetch_remote || return 1
    refresh_target_snapshot || return 1
    remote_branch_exists "$branch" || { printf 'Branch %s/%s nie istnieje.\n' "$REMOTE" "$branch" >&2; return 1; }
    classify_branch "$branch" >/dev/null || return 1
    perform_merge "$branch" "$POLICY_AI_ALL"
}

schedule_one_merge() {
    local branch policy classification dev target last_dev last_target failed_dev failed_target
    local cooldown last_merged_at eligible branch_eligible global_last_merge global_eligible now selected_branch=""
    now="$(date +%s)"
    global_last_merge="$(jq -r '.last_successful_merge_at // 0' "$STATE_FILE")"
    if ((global_last_merge > 0)); then
        global_eligible=$((global_last_merge + MIN_TIME_BETWEEN_MERGES_M * 60))
    else
        global_eligible="$now"
    fi
    while IFS= read -r branch; do
        policy="$(jq -r --arg branch "$branch" '.tracked_branches[$branch].policy' "$CONFIG_FILE")"
        classification="$(jq -r --arg branch "$branch" '.branches[$branch].mergeability // "checking"' "$STATE_FILE")"
        dev="$(jq -r --arg branch "$branch" '.branches[$branch].target_branch_sha // ""' "$STATE_FILE")"
        target="$(jq -r --arg branch "$branch" '.branches[$branch].target_sha // ""' "$STATE_FILE")"
        last_dev="$(jq -r --arg branch "$branch" '.tracked_branches[$branch].last_merged_target_branch_sha // ""' "$CONFIG_FILE")"
        last_target="$(jq -r --arg branch "$branch" '.tracked_branches[$branch].last_merged_target_sha // ""' "$CONFIG_FILE")"
        failed_dev="$(jq -r --arg branch "$branch" '.branches[$branch].failed_target_branch_sha // ""' "$STATE_FILE")"
        failed_target="$(jq -r --arg branch "$branch" '.branches[$branch].failed_target_sha // ""' "$STATE_FILE")"
        if [[ "$dev" == "$last_dev" && "$target" == "$last_target" && -n "$dev" ]]; then
            state_update --arg branch "$branch" '
                .branches[$branch].mergeability="up to date"
                | .branches[$branch].up_to_date=true
                | .branches[$branch].action_state="merged"
            '
            continue
        fi
        if jq -e --arg branch "$branch" '.branches[$branch].up_to_date == true' "$STATE_FILE" >/dev/null; then
            state_update --arg branch "$branch" '.branches[$branch].action_state="merged"'
            continue
        fi
        if [[ -n "$dev" && "$dev" == "$failed_dev" && "$target" == "$failed_target" ]]; then
            state_update --arg branch "$branch" '.branches[$branch].action_state="fail"'
            continue
        fi
        if [[ "$policy" == "$POLICY_MANUAL" ]]; then
            state_update --arg branch "$branch" '.branches[$branch].action_state="manual"'
            continue
        fi
        if [[ "$classification" == "mergable" ]] \
            && ! jq -e --arg branch "$branch" '
                .tracked_branches[$branch].merge_without_conflicts
                // .merge_without_conflicts_default
                // false
            ' "$CONFIG_FILE" >/dev/null; then
            state_update --arg branch "$branch" '.branches[$branch].action_state="ignored"'
            continue
        fi
        cooldown="$(jq -r --arg branch "$branch" '
            .tracked_branches[$branch].merge_cooldown_time as $cooldown
            | if $cooldown == "auto" then .merge_cooldown_time_m_default else $cooldown end
        ' "$CONFIG_FILE")"
        last_merged_at="$(jq -r --arg branch "$branch" '.tracked_branches[$branch].last_merged_at // 0' "$CONFIG_FILE")"
        if ((last_merged_at > 0)); then
            branch_eligible=$((last_merged_at + cooldown * 60))
        else
            branch_eligible="$now"
        fi
        if ((branch_eligible > global_eligible)); then eligible="$branch_eligible"; else eligible="$global_eligible"; fi
        state_update --arg branch "$branch" --argjson eligible "$eligible" '.branches[$branch].eligible_at=$eligible'
        if ((now < eligible)); then
            state_update --arg branch "$branch" '.branches[$branch].action_state="waiting"'
            continue
        fi
        if [[ "$policy" == "$POLICY_BASIC" && "$classification" != "mergable" ]] \
            || [[ "$policy" == "$POLICY_AI_SIMPLE" && "$classification" == "conflicts" ]]; then
            state_update --arg branch "$branch" '.branches[$branch].action_state="skipped"'
            continue
        fi
        state_update --arg branch "$branch" '.branches[$branch].action_state="queued"'
        [[ -n "$selected_branch" ]] || selected_branch="$branch"
    done < <(jq -r '.tracked_branches | keys[]' "$CONFIG_FILE")
    if [[ -n "$selected_branch" ]]; then
        state_update --arg branch "$selected_branch" '.branches[$branch].action_state="queued"'
        perform_merge "$selected_branch" || true
    fi
}

merge_schedule_has_ready_state() {
    local now="${1:-$(date +%s)}"
    jq -e --argjson now "$now" '
        [.branches[]?
            | select(
                .action_state == "queued"
                or (.action_state == "waiting" and (.eligible_at // 0) <= $now)
            )]
        | length > 0
    ' "$STATE_FILE" >/dev/null 2>&1
}

merge_schedule_has_queued_state() {
    jq -e '[.branches[]? | select(.action_state == "queued")] | length > 0' \
        "$STATE_FILE" >/dev/null 2>&1
}

discover_new_pull_requests() {
    local branch output open_json tracked_json now
    local -a open_branches=()
    command -v gh >/dev/null 2>&1 || return 0
    if ! output="$(cd -- "$WORKDIR" \
        && timeout --foreground "${PR_DISCOVERY_TIMEOUT}s" \
            gh pr list --author @me --state open --json headRefName --jq '.[].headRefName' 2>/dev/null)"; then
        return 0
    fi
    while IFS= read -r branch; do
        [[ -n "$branch" ]] && open_branches+=("$branch")
    done <<<"$output"
    open_json="$(printf '%s\n' "${open_branches[@]}" | jq -Rsc '
        split("\n") | map(select(length > 0)) | unique
    ')"
    tracked_json="$(jq -c '.tracked_branches | keys' "$CONFIG_FILE")"
    now="$(date +%s)"
    state_update --argjson open "$open_json" --argjson tracked "$tracked_json" --argjson now "$now" '
        (.pr_discovery.known // []) as $known
        | (.pr_discovery.pending // []) as $pending
        | (($open - $known - $tracked) | unique) as $new
        | .pr_discovery.known=$open
        | .pr_discovery.pending=(($pending + $new)
            | unique
            | map(select(. as $branch
                | ($open | index($branch)) != null
                and ($tracked | index($branch)) == null)))
        | .pr_discovery.last_checked_at=$now
    '
}

run_cycle() {
    fetch_remote || return 1
    if ! refresh_target_snapshot; then
        record_command_error "Nie udało się odświeżyć snapshotu $REMOTE/$TARGET_BRANCH"
        return 1
    fi
    if ! cleanup_missing_branches; then
        record_command_error "Nie udało się wyczyścić nieistniejących branchy"
        return 1
    fi
    discover_new_pull_requests
    classify_all_tracked
    [[ -e "$STOP_FILE" ]] || schedule_one_merge
}

queue_command() {
    local kind="$1"
    local payload="$2"
    local encoded
    [[ "$payload" != *$'\n'* && "$payload" != *$'\r'* ]] || return 1
    encoded="$(printf '%s' "$payload" | base64 -w0)"
    (
        flock -x 9
        printf '%s\t%s\n' "$kind" "$encoded" >>"$QUEUE_FILE"
    ) 9>"$STATE_DIR/queue.lock"
}

pop_queued_command() {
    local tmp line
    tmp="$(mktemp "$STATE_DIR/queue.XXXXXX")" || return 1
    (
        flock -x 9
        IFS= read -r line <"$QUEUE_FILE" || line=""
        if [[ -n "$line" ]]; then
            sed '1d' "$QUEUE_FILE" >"$tmp"
            mv -f -- "$tmp" "$QUEUE_FILE"
            printf '%s' "$line"
        else
            rm -f -- "$tmp"
            return 1
        fi
    ) 9>"$STATE_DIR/queue.lock"
}

process_one_user_command() {
    local queued kind encoded payload command_text log_id pid exit_code output_file result
    local nudge_branch="" nudge_base="" nudge_remote="" auto_close=true
    queued="$(pop_queued_command)" || return 1
    IFS=$'\t' read -r kind encoded <<<"$queued"
    payload="$(printf '%s' "$encoded" | base64 -d)" || return 1
    case "$kind" in
        git) command_text="git $payload" ;;
        nudge | continuous_nudge)
            read -r nudge_branch nudge_base nudge_remote _ <<<"$payload"
            command_text="${kind//_/-} $nudge_branch"
            ;;
        purge)
            command_text="purge_local_branches"
            auto_close=false
            ;;
        update_local_branches)
            command_text="update_local_branches"
            auto_close=false
            ;;
        force_merge)
            command_text="merge $payload"
            auto_close=false
            ;;
        *) command_text="$payload" ;;
    esac
    log_start "$command_text"
    log_id="$LAST_LOG_ID"
    output_file="$STATE_DIR/command-output-$log_id.log"
    if [[ "$kind" == "continuous_nudge" ]] \
        && ! jq -e --arg branch "$nudge_branch" '(.continuous_nudges // {}) | has($branch)' "$CONFIG_FILE" >/dev/null; then
        printf 'Continuous nudge dla %s został wcześniej zatrzymany.\n' "$nudge_branch" >"$output_file"
        result="DONE"
        log_finish "$log_id" "DONE"
    elif [[ "$kind" == "nudge" || "$kind" == "continuous_nudge" ]]; then
        (
            trap 'cleanup_worktree "$ACTIVE_WORKTREE"' EXIT
            trap 'exit 143' TERM INT
            perform_nudge "$nudge_branch" "$nudge_base" "$nudge_remote"
        ) >"$output_file" 2>&1 &
    elif [[ "$kind" == "purge" ]]; then
        (
            trap 'exit 143' TERM INT
            purge_local_branches
        ) >"$output_file" 2>&1 &
    elif [[ "$kind" == "update_local_branches" ]]; then
        (
            trap 'exit 143' TERM INT
            update_local_branches
        ) >"$output_file" 2>&1 &
    elif [[ "$kind" == "force_merge" ]]; then
        (
            trap 'cleanup_worktree "$ACTIVE_WORKTREE"' EXIT
            trap 'exit 143' TERM INT
            perform_one_shot_merge "$payload"
        ) >"$output_file" 2>&1 &
    else
        (
            cd -- "$WORKDIR" || exit 125
            exec setsid bash -lc "$command_text"
        ) >"$output_file" 2>&1 &
    fi
    if [[ -z "${result:-}" ]]; then
        pid=$!
        set_current "shell" "$pid" "$command_text"
        wait "$pid"
        exit_code=$?
        if ((exit_code == 0)); then
            result="DONE"
            log_finish "$log_id" "DONE"
            if [[ "$kind" == "continuous_nudge" ]]; then
                config_update --arg branch "$nudge_branch" --argjson now "$(date +%s)" '
                    if (.continuous_nudges // {} | has($branch)) then
                        .continuous_nudges[$branch].last_run_at=$now
                    else .
                    end
                ' || true
            fi
        else
            result="FAIL"
            log_finish "$log_id" "FAIL"
        fi
    fi
    state_update --arg id "$log_id" --arg label "$command_text" --arg path "$output_file" \
        --arg status "$result" --argjson auto_close "$auto_close" '
        .command_outputs = ((.command_outputs // []) + [{
            id:$id,label:$label,path:$path,status:$status,shown:false,auto_close:$auto_close
        }])
        | .command_outputs = (
            [.command_outputs[] | select(.shown != true)][-8:]
            + [.command_outputs[] | select(.shown == true)][-2:]
        )
    '
    clear_current
    return 0
}

worker_cleanup() {
    cleanup_worktree "$ACTIVE_WORKTREE"
    cleanup_ai_sandbox_dir "$ACTIVE_AI_SANDBOX"
    cleanup_model_session_dir "$ACTIVE_MODEL_SESSION"
    clear_current
}

worker_loop() {
    trap 'worker_cleanup; exit 0' TERM INT
    local last_cycle_at=0 last_schedule_at=0 now cycle_ready=false
    while true; do
        if process_one_user_command; then
            continue
        fi
        if [[ -e "$STOP_FILE" ]]; then
            sleep 0.2
            continue
        fi
        if schedule_due_continuous_nudge; then
            continue
        fi
        now="$(date +%s)"
        if ((now - last_cycle_at >= FETCH_INTERVAL)); then
            if run_cycle; then
                cycle_ready=true
            fi
            last_cycle_at="$(date +%s)"
            last_schedule_at=0
            continue
        fi
        if [[ "$cycle_ready" == "true" ]] \
            && ((last_schedule_at == 0 || now - last_schedule_at >= MERGE_SCHEDULER_INTERVAL_SECONDS)); then
            if merge_schedule_has_ready_state "$now"; then
                schedule_one_merge
                if merge_schedule_has_queued_state; then
                    last_schedule_at=0
                else
                    last_schedule_at="$(date +%s)"
                fi
                continue
            fi
            last_schedule_at="$now"
        fi
        sleep 0.2
    done
}

start_worker() {
    worker_loop &
    WORKER_PID=$!
}

stop_ai_immediately() {
    local kind pid
    kind="$(jq -r '.kind // ""' "$CURRENT_FILE" 2>/dev/null || true)"
    pid="$(jq -r '.pid // 0' "$CURRENT_FILE" 2>/dev/null || printf '0')"
    if [[ "$kind" == "ai" && "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; then
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    fi
}

stop_current_immediately() {
    local pid
    pid="$(jq -r '.pid // 0' "$CURRENT_FILE" 2>/dev/null || printf '0')"
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 ]]; then
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    fi
}

restart_worker() {
    touch "$STOP_FILE"
    stop_current_immediately
    if [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
        kill -TERM "$WORKER_PID" 2>/dev/null || true
        wait "$WORKER_PID" 2>/dev/null || true
    fi
    state_update '
        .branches |= with_entries(
            .value.action_state="checking"
            | .value.error=""
            | del(.value.failed_target_branch_sha, .value.failed_target_sha, .value.retry_allowed)
        )
    '
    rm -f -- "$STOP_FILE"
    start_worker
}

stop_worker_process() {
    touch "$STOP_FILE"
    stop_current_immediately
    if [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
        kill -TERM "$WORKER_PID" 2>/dev/null || true
        wait "$WORKER_PID" 2>/dev/null || true
    fi
    WORKER_PID=""
    clear_current
}

stop_title_resolver() {
    if [[ -n "$TITLE_RESOLVER_PID" ]] && kill -0 "$TITLE_RESOLVER_PID" 2>/dev/null; then
        kill -TERM "$TITLE_RESOLVER_PID" 2>/dev/null || true
        wait "$TITLE_RESOLVER_PID" 2>/dev/null || true
    fi
    TITLE_RESOLVER_PID=""
}

reset_local_state() {
    local ref
    local removed=0 failed=0
    stop_title_resolver
    stop_worker_process
    while IFS= read -r ref; do
        [[ "$ref" == refs/automerger/* ]] || continue
        if git -C "$WORKDIR" update-ref -d "$ref"; then
            ((removed++))
        else
            failed=1
        fi
    done < <(git -C "$WORKDIR" for-each-ref --format='%(refname)' refs/automerger/)
    (
        flock -x 9
        : >"$QUEUE_FILE"
    ) 9>"$STATE_DIR/queue.lock"
    find "$STATE_DIR" -maxdepth 1 -type f \
        \( -name 'command-output-*.log' -o -name 'operation-*.log' \) -delete 2>/dev/null || true
    config_update '.tracked_branches={} | .continuous_nudges={}' || failed=1
    state_update '
        .target_branch_sha=""
        | .last_fetch_at=0
        | .last_successful_merge_at=0
        | .branches={}
        | .logs=[]
        | .command_outputs=[]
        | .title_queue=[]
        | .pr_discovery={known:[],pending:[],last_checked_at:0}
    ' || failed=1
    RESET_REMOVED_REFS="$removed"
    start_worker
    if ((failed != 0)); then
        operation_error "Reset nie został wykonany w całości; automat pozostaje zatrzymany."
        return 1
    fi
    return 0
}

local_branch_is_checked_out() {
    local branch="$1"
    git -C "$WORKDIR" worktree list --porcelain \
        | awk -v expected="refs/heads/$branch" '
            $1 == "branch" && $2 == expected { found=1 }
            END { exit(found ? 0 : 1) }
        '
}

purge_local_branches() {
    local target_branch_sha branch upstream_ref branch_sha
    local scanned=0 removed=0 upstream_kept=0 unmerged_kept=0 checked_out_kept=0 errors=0
    local -a removed_branches=() upstream_branches=() unmerged_branches=() checked_out_branches=() error_branches=()
    [[ -n "$DEFAULT_BRANCH_PREFIX" ]] || {
        printf 'Purge jest zablokowany: default_branch_prefix jest pusty.\n' >&2
        return 1
    }
    printf 'Odświeżanie %s przed purge...\n' "$REMOTE"
    if ! git -C "$WORKDIR" fetch --prune "$REMOTE"; then
        printf 'Nie udało się odświeżyć remote %s; purge przerwany bez usuwania branchy.\n' "$REMOTE" >&2
        return 1
    fi
    target_branch_sha="$(git -C "$WORKDIR" rev-parse "$(remote_ref "$TARGET_BRANCH")^{commit}" 2>/dev/null)" || {
        printf 'Nie można odczytać %s/%s; purge przerwany.\n' "$REMOTE" "$TARGET_BRANCH" >&2
        return 1
    }
    while IFS= read -r branch; do
        [[ "$branch" == "$DEFAULT_BRANCH_PREFIX"* ]] || continue
        ((++scanned))
        branch_sha="$(git -C "$WORKDIR" rev-parse "refs/heads/$branch^{commit}" 2>/dev/null || true)"
        if [[ -z "$branch_sha" ]]; then
            ((++errors))
            error_branches+=("$branch")
            record_command_error "purge: nie można odczytać lokalnego brancha $branch"
            continue
        fi
        upstream_ref="$(git -C "$WORKDIR" for-each-ref --format='%(upstream)' "refs/heads/$branch")"
        if [[ -n "$upstream_ref" ]] \
            && git -C "$WORKDIR" show-ref --verify --quiet "$upstream_ref"; then
            ((++upstream_kept))
            upstream_branches+=("$branch")
            continue
        fi
        if ! git -C "$WORKDIR" merge-base --is-ancestor "$branch_sha" "$target_branch_sha"; then
            ((++unmerged_kept))
            unmerged_branches+=("$branch")
            continue
        fi
        if local_branch_is_checked_out "$branch"; then
            ((++checked_out_kept))
            checked_out_branches+=("$branch")
            continue
        fi
        if git -C "$WORKDIR" update-ref -d "refs/heads/$branch" "$branch_sha"; then
            ((++removed))
            removed_branches+=("$branch")
            record_command_success "purge: usunięto lokalny branch $branch"
        else
            ((++errors))
            error_branches+=("$branch")
            record_command_error "purge: nie udało się usunąć lokalnego brancha $branch"
        fi
    done < <(git -C "$WORKDIR" for-each-ref --format='%(refname:strip=2)' refs/heads/)

    printf '\nPODSUMOWANIE PURGE\n'
    printf 'Sprawdzone branche z prefiksem %s: %d\n' "$DEFAULT_BRANCH_PREFIX" "$scanned"
    printf 'Usunięte: %d\n' "$removed"
    printf 'Pozostawione — istniejący upstream: %d\n' "$upstream_kept"
    printf 'Pozostawione — commit nie należy do %s/%s: %d\n' \
        "$REMOTE" "$TARGET_BRANCH" "$unmerged_kept"
    printf 'Pozostawione — branch aktywny w worktree: %d\n' "$checked_out_kept"
    printf 'Błędy: %d\n' "$errors"
    if ((${#removed_branches[@]} > 0)); then
        printf '\nUsunięte branche:\n'
        printf '  %s\n' "${removed_branches[@]}"
    fi
    if ((${#checked_out_branches[@]} > 0)); then
        printf '\nPominięte aktywne branche:\n'
        printf '  %s\n' "${checked_out_branches[@]}"
    fi
    if ((${#error_branches[@]} > 0)); then
        printf '\nBranche zakończone błędem:\n'
        printf '  %s\n' "${error_branches[@]}"
    fi
    ((errors == 0))
}

local_branch_worktree_path() {
    local branch="$1"
    git -C "$WORKDIR" worktree list --porcelain | awk -v expected="refs/heads/$branch" '
        /^worktree / { path=substr($0, 10); next }
        /^branch / { if (substr($0, 8) == expected) { print path; exit } }
    '
}

update_local_branches() {
    local branch active_path temporary_worktree pull_output pull_status pull_summary
    local scanned=0 updated=0 errors=0
    local -a updated_branches=() error_branches=()
    [[ -n "$DEFAULT_BRANCH_PREFIX" ]] || {
        printf 'Update jest zablokowany: default_branch_prefix jest pusty.\n' >&2
        return 1
    }
    while IFS= read -r branch; do
        [[ "$branch" == "$DEFAULT_BRANCH_PREFIX"* ]] || continue
        ((++scanned))
        active_path="$(local_branch_worktree_path "$branch")"
        temporary_worktree=""
        if [[ -n "$active_path" ]]; then
            pull_output="$(git -C "$active_path" pull --ff-only 2>&1)"
            pull_status=$?
        else
            temporary_worktree="$(mktemp -d "$STATE_DIR/update-worktree.XXXXXX")" || {
                ((++errors)); error_branches+=("$branch"); record_command_error "update: nie można utworzyć worktree dla $branch"; continue;
            }
            if ! git -C "$WORKDIR" worktree add --quiet "$temporary_worktree" "$branch" > /dev/null 2>&1; then
                rm -rf -- "$temporary_worktree"
                ((++errors)); error_branches+=("$branch"); record_command_error "update: nie można przygotować worktree dla $branch"; continue
            fi
            pull_output="$(git -C "$temporary_worktree" pull --ff-only 2>&1)"
            pull_status=$?
        fi
        if [[ -n "$temporary_worktree" ]]; then
            git -C "$WORKDIR" worktree remove --force "$temporary_worktree" >/dev/null 2>&1 || true
        fi
        if ((pull_status == 0)); then
            ((++updated))
            updated_branches+=("$branch")
            record_command_success "update: zaktualizowano lokalny branch $branch"
        else
            ((++errors))
            error_branches+=("$branch")
            pull_summary="$(printf '%s' "${pull_output:-git pull zakończył się błędem}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
            record_command_error "update: pominięto $branch — $(truncate_text "$pull_summary" 120)"
        fi
    done < <(git -C "$WORKDIR" for-each-ref --format='%(refname:strip=2)' refs/heads/)
    printf '\nPODSUMOWANIE UPDATE\n'
    printf 'Sprawdzone branche z prefiksem %s: %d\n' "$DEFAULT_BRANCH_PREFIX" "$scanned"
    printf 'Zaktualizowane: %d\n' "$updated"
    printf 'Pominięte z błędem: %d\n' "$errors"
    if ((${#updated_branches[@]} > 0)); then printf '\nZaktualizowane branche:\n  %s\n' "${updated_branches[@]}"; fi
    if ((${#error_branches[@]} > 0)); then printf '\nBranche pominięte z błędem:\n  %s\n' "${error_branches[@]}"; fi
    ((errors == 0))
}

clear_runtime_operation_logs() {
    local runtime state lock tmp owner
    while IFS= read -r -d '' runtime; do
        [[ ! -L "$runtime" ]] || continue
        owner="$(stat -c '%u' "$runtime" 2>/dev/null || true)"
        [[ "$owner" == "$UID" ]] || continue
        state="$runtime/state.json"
        lock="$runtime/state.lock"
        if [[ -f "$state" && ! -L "$state" ]] && jq -e . "$state" >/dev/null 2>&1; then
            tmp="$(mktemp "$runtime/state.clear-logs.XXXXXX")" || continue
            (
                flock -x 9
                if jq '.logs=[] | .command_outputs=[]' "$state" >"$tmp"; then
                    mv -f -- "$tmp" "$state"
                else
                    rm -f -- "$tmp"
                fi
            ) 9>"$lock"
        fi
        find "$runtime" -maxdepth 1 -type f \
            \( -name 'command-output-*.log' -o -name 'operation-*.log' \) -delete 2>/dev/null || true
    done < <(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "automerger-${UID}-*" -print0 2>/dev/null)
    state_update '.logs=[] | .command_outputs=[]'
    find "$STATE_DIR" -maxdepth 1 -type f \
        \( -name 'command-output-*.log' -o -name 'operation-*.log' \) -delete 2>/dev/null || true
}

remove_model_log_context() {
    local root="$1" context="$2" file index tmp
    [[ -d "$root" && ! -L "$root" && "$root" == "$MODEL_LOG_DIR"/* ]] || return 0
    while IFS= read -r -d '' file; do
        [[ "$file" == "$root"/* && ! -L "$file" ]] || continue
        rm -f -- "$file"
    done < <(find "$root" -mindepth 2 -maxdepth 2 -type f \
        \( -name "*-${context}-att-*.out.log" -o -name "*-${context}-att-*.req.md" \) -print0)
    while IFS= read -r -d '' index; do
        tmp="$(mktemp "$(dirname -- "$index")/.errors.XXXXXX")" || continue
        if jq -c --arg context "$context" 'select(.context != $context)' "$index" >"$tmp"; then
            mv -f -- "$tmp" "$index"
        else
            rm -f -- "$tmp"
        fi
    done < <(find "$root" -mindepth 2 -maxdepth 2 -type f -name errors.jsonl -print0)
    find "$root" -mindepth 1 -maxdepth 2 -type d -empty -delete 2>/dev/null || true
}

remove_legacy_model_logs() {
    local model="$1" context="$2" index="$MODEL_LOG_DIR/model-errors.jsonl"
    local row output request tmp
    [[ -f "$index" && ! -L "$index" ]] || return 0
    while IFS=$'\t' read -r output request; do
        for row in "$output" "$request"; do
            [[ -n "$row" && "$row" == "$MODEL_LOG_DIR"/* && -f "$row" && ! -L "$row" ]] || continue
            rm -f -- "$row"
        done
    done < <(jq -r --arg model "$model" --arg context "$context" '
        select(($model == "" or .model == $model) and ($context == "" or .context == $context))
        | [(.output_file // ""),(.request_file // "")] | @tsv
    ' "$index" 2>/dev/null)
    tmp="$(mktemp "$MODEL_LOG_DIR/.legacy-errors.XXXXXX")" || return 1
    if jq -c --arg model "$model" --arg context "$context" '
        select(
            ((($model == "") or .model == $model)
                and (($context == "") or .context == $context))
            | not
        )
    ' "$index" >"$tmp"; then
        mv -f -- "$tmp" "$index"
    else
        rm -f -- "$tmp"
        return 1
    fi
}

remove_model_logs() {
    local first="$1" second="${2:-}" safe_model path child context=""
    first="$(trim "$first")"
    second="$(trim "$second")"
    [[ -n "$first" ]] || { operation_error "Użycie: remove_log MODEL|title|all [title]."; return 1; }
    if [[ "${first,,}" == "all" && -z "$second" ]]; then
        while IFS= read -r -d '' child; do
            [[ "$child" == "$MODEL_LOG_DIR"/* && ! -L "$child" ]] || continue
            [[ "$child" != "$MODEL_LOG_LOCK" ]] || continue
            if [[ -d "$child" ]]; then
                rm -rf -- "$child"
            else
                rm -f -- "$child"
            fi
        done < <(find "$MODEL_LOG_DIR" -mindepth 1 -maxdepth 1 -print0)
        return 0
    fi
    if [[ "${first,,}" == "title" && -z "$second" ]]; then
        context="title"
        while IFS= read -r -d '' child; do
            remove_model_log_context "$child" "$context"
        done < <(find "$MODEL_LOG_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
        remove_legacy_model_logs "" "$context"
        return 0
    fi
    [[ -z "$second" || "${second,,}" == "title" ]] \
        || { operation_error "Obsługiwany typ logu to obecnie: title."; return 1; }
    safe_model="$(sanitize_model_log_component "$first")"
    path="$MODEL_LOG_DIR/$safe_model"
    if [[ -n "$second" ]]; then
        remove_model_log_context "$path" "title"
        remove_legacy_model_logs "$first" "title"
    else
        if [[ -d "$path" && ! -L "$path" && "$path" == "$MODEL_LOG_DIR"/* ]]; then
            rm -rf -- "$path"
        fi
        remove_legacy_model_logs "$first" ""
    fi
}

assess_nudge_branch() {
    local branch="$1"
    local remote_sha local_sha result_sha current_branch dirty
    local base_sha source="remote" warning=""
    NUDGE_BASE_SHA=""
    NUDGE_REMOTE_SHA=""
    NUDGE_WARNING=""
    remote_branch_exists "$branch" \
        || { operation_error "Branch $REMOTE/$branch nie istnieje."; return 1; }
    remote_sha="$(git -C "$WORKDIR" rev-parse "$(remote_ref "$branch")^{commit}" 2>/dev/null)" \
        || { operation_error "Nie udało się odczytać $REMOTE/$branch."; return 1; }
    base_sha="$remote_sha"
    local_sha="$(git -C "$WORKDIR" rev-parse --verify --quiet "refs/heads/$branch^{commit}" 2>/dev/null || true)"
    if [[ -n "$local_sha" && "$local_sha" != "$remote_sha" ]]; then
        if git -C "$WORKDIR" merge-base --is-ancestor "$remote_sha" "$local_sha"; then
            base_sha="$local_sha"
            source="lokalny branch"
        elif git -C "$WORKDIR" merge-base --is-ancestor "$local_sha" "$remote_sha"; then
            :
        else
            operation_error "Lokalny branch $branch jest rozbieżny z $REMOTE/$branch; nudge nie używa force-pusha."
            return 1
        fi
    fi
    result_sha="$(git -C "$WORKDIR" rev-parse --verify --quiet "refs/automerger/results/$branch^{commit}" 2>/dev/null || true)"
    if [[ -n "$result_sha" && "$result_sha" != "$remote_sha" ]]; then
        if git -C "$WORKDIR" merge-base --is-ancestor "$remote_sha" "$result_sha"; then
            if [[ "$base_sha" == "$remote_sha" ]] \
                || git -C "$WORKDIR" merge-base --is-ancestor "$base_sha" "$result_sha"; then
                base_sha="$result_sha"
                source="lokalny wynik automergera"
            elif git -C "$WORKDIR" merge-base --is-ancestor "$result_sha" "$base_sha"; then
                source="lokalny branch zawierający wynik automergera"
            else
                operation_error "Lokalny branch i wynik automergera dla $branch są rozbieżne; połącz je ręcznie przed nudge."
                return 1
            fi
        elif git -C "$WORKDIR" merge-base --is-ancestor "$result_sha" "$remote_sha"; then
            :
        else
            operation_error "Lokalny wynik automergera dla $branch nie jest fast-forward względem remote; nudge został zablokowany."
            return 1
        fi
    fi
    if [[ "$base_sha" != "$remote_sha" ]]; then
        warning="Wybrany $source zawiera lokalne commity, które zostaną wypchnięte razem z pustym commitem."
    fi
    current_branch="$(git -C "$WORKDIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ "$current_branch" == "$branch" ]]; then
        dirty="$(git -C "$WORKDIR" status --porcelain --untracked-files=normal 2>/dev/null || true)"
        if [[ -n "$dirty" ]]; then
            [[ -z "$warning" ]] || warning+=$'\n'
            warning+="Główny katalog roboczy brancha $branch ma niezacommitowane zmiany. Nie zostaną one dodane do pustego commita."
        fi
    fi
    NUDGE_BASE_SHA="$base_sha"
    NUDGE_REMOTE_SHA="$remote_sha"
    NUDGE_WARNING="$warning"
}

perform_nudge() {
    local branch="$1" expected_base="$2" expected_remote="$3"
    local current_remote worktree parent_tree commit_tree new_sha result_sha
    current_remote="$(git -C "$WORKDIR" rev-parse "$(remote_ref "$branch")^{commit}" 2>/dev/null || true)"
    if [[ -z "$current_remote" || "$current_remote" != "$expected_remote" ]]; then
        printf 'Remote %s/%s zmienił się od czasu potwierdzenia. Uruchom nudge ponownie.\n' "$REMOTE" "$branch" >&2
        return 1
    fi
    if ! assess_nudge_branch "$branch" || [[ "$NUDGE_BASE_SHA" != "$expected_base" ]]; then
        printf '%s\n' "${LAST_ERROR:-Lokalny stan brancha zmienił się od czasu potwierdzenia.}" >&2
        return 1
    fi
    worktree="$(create_worktree "$expected_base")" || {
        printf 'Nie udało się utworzyć worktree dla nudge %s.\n' "$branch" >&2
        return 1
    }
    ACTIVE_WORKTREE="$worktree"
    if [[ -n "$(git -C "$worktree" status --porcelain --untracked-files=normal)" ]] \
        || ! git -C "$worktree" diff --quiet \
        || ! git -C "$worktree" diff --cached --quiet; then
        printf 'Worktree nudge nie jest czysty; pusty commit został zablokowany.\n' >&2
        cleanup_worktree "$worktree"
        ACTIVE_WORKTREE=""
        return 1
    fi
    parent_tree="$(git -C "$worktree" rev-parse HEAD^{tree})" || {
        cleanup_worktree "$worktree"
        ACTIVE_WORKTREE=""
        return 1
    }
    if ! git -C "$worktree" -c user.name="$GIT_USER_NAME" -c user.email="$GIT_USER_EMAIL" \
        commit --allow-empty -m "$branch"; then
        cleanup_worktree "$worktree"
        ACTIVE_WORKTREE=""
        return 1
    fi
    commit_tree="$(git -C "$worktree" rev-parse HEAD^{tree})" || {
        cleanup_worktree "$worktree"
        ACTIVE_WORKTREE=""
        return 1
    }
    if [[ "$commit_tree" != "$parent_tree" ]] || ! git -C "$worktree" diff-tree --quiet HEAD^ HEAD; then
        printf 'Commit nudge nie jest pusty; push został zablokowany.\n' >&2
        cleanup_worktree "$worktree"
        ACTIVE_WORKTREE=""
        return 1
    fi
    new_sha="$(git -C "$worktree" rev-parse HEAD)" || {
        cleanup_worktree "$worktree"
        ACTIVE_WORKTREE=""
        return 1
    }
    if ! git -C "$worktree" push "$REMOTE" "HEAD:refs/heads/$branch"; then
        cleanup_worktree "$worktree"
        ACTIVE_WORKTREE=""
        return 1
    fi
    current_remote="$(git -C "$WORKDIR" rev-parse "$(remote_ref "$branch")^{commit}" 2>/dev/null || true)"
    if [[ "$current_remote" == "$expected_remote" ]]; then
        git -C "$WORKDIR" update-ref "$(remote_ref "$branch")" "$new_sha" "$expected_remote" 2>/dev/null || true
    fi
    result_sha="$(git -C "$WORKDIR" rev-parse --verify --quiet "refs/automerger/results/$branch^{commit}" 2>/dev/null || true)"
    if [[ -n "$result_sha" ]] && git -C "$WORKDIR" merge-base --is-ancestor "$result_sha" "$new_sha"; then
        git -C "$WORKDIR" update-ref -d "refs/automerger/results/$branch" || true
    fi
    cleanup_worktree "$worktree"
    ACTIVE_WORKTREE=""
    printf 'Utworzono absolutnie pusty commit %s i wypchnięto go do %s/%s.\n' "$new_sha" "$REMOTE" "$branch"
}

collect_nudge_targets() {
    local specification="$1" branch labels want_labeled
    declare -ga NUDGE_TARGETS=()
    if [[ "${specification,,}" == "all" ]]; then
        mapfile -t NUDGE_TARGETS < <(jq -r --arg manual "$POLICY_MANUAL" '
            .tracked_branches | to_entries[]
            | select(.value.policy != $manual)
            | .key
        ' "$CONFIG_FILE")
        ((${#NUDGE_TARGETS[@]} > 0)) \
            || { operation_error "Brak śledzonych branchy z polityką inną niż manual."; return 1; }
        return 0
    fi
    if [[ "${specification,,}" == "labeled" || "${specification,,}" == "unlabeled" ]]; then
        github_token_is_active || return 1
        [[ "${specification,,}" == "labeled" ]] && want_labeled=true || want_labeled=false
        mapfile -t NUDGE_TARGETS < <(jq -r --arg manual "$POLICY_MANUAL" '
            .tracked_branches | to_entries[]
            | select(.value.policy != $manual)
            | .key
        ' "$CONFIG_FILE")
        ((${#NUDGE_TARGETS[@]} > 0)) \
            || { operation_error "Brak śledzonych branchy z polityką inną niż manual."; return 1; }
        local -a filtered_targets=()
        for branch in "${NUDGE_TARGETS[@]}"; do
            labels="$(get_pull_request_labels "$branch")" || return 1
            if { [[ "$want_labeled" == "true" ]] && [[ -n "$labels" ]]; } \
                || { [[ "$want_labeled" == "false" ]] && [[ -z "$labels" ]]; }; then
                filtered_targets+=("$branch")
            fi
        done
        NUDGE_TARGETS=("${filtered_targets[@]}")
        ((${#NUDGE_TARGETS[@]} > 0)) \
            || { operation_error "Brak branchy pasujących do filtra '$specification'."; return 1; }
        return 0
    fi
    branch="$(normalize_branch_name "$specification")"
    git -C "$WORKDIR" check-ref-format --branch "$branch" >/dev/null 2>&1 \
        || { operation_error "Niepoprawna nazwa brancha: $branch"; return 1; }
    NUDGE_TARGETS=("$branch")
}

queue_nudge_targets() {
    local branch queued=0
    for branch in "${NUDGE_TARGETS[@]}"; do
        if assess_nudge_branch "$branch"; then
            if [[ -n "$NUDGE_WARNING" ]] \
                && ! confirm_action "$NUDGE_WARNING Kontynuować nudge dla $branch?"; then
                continue
            fi
            if queue_command nudge "$branch $NUDGE_BASE_SHA $NUDGE_REMOTE_SHA"; then
                ((++queued))
            else
                record_command_error "Nie udało się zakolejkować nudge dla $branch"
            fi
        else
            record_command_error "${LAST_ERROR:-Nie udało się przygotować nudge dla $branch}"
        fi
    done
    ((queued > 0))
}

choose_continuous_interval() {
    local answer
    clear_tui_input_line
    printf 'Co ile minut wykonywać nudge? ' >&2
    read_tui_line answer || return 1
    answer="$(trim "$answer")"
    [[ "$answer" =~ ^[0-9]+$ ]] && ((10#$answer >= 1)) || return 1
    INTERACTIVE_VALUE="$((10#$answer))"
}

start_continuous_nudges() {
    local specification="$1" interval="$2" now branch scheduled=0
    collect_nudge_targets "$specification" || return 1
    [[ "$interval" =~ ^[0-9]+$ ]] && ((10#$interval >= 1)) \
        || { operation_error "Interwał continuous nudge musi być dodatnią liczbą minut."; return 1; }
    interval=$((10#$interval))
    now="$(date +%s)"
    for branch in "${NUDGE_TARGETS[@]}"; do
        if assess_nudge_branch "$branch"; then
            if [[ -n "$NUDGE_WARNING" ]] \
                && ! confirm_action "$NUDGE_WARNING Uruchomić continuous nudge dla $branch?"; then
                continue
            fi
            config_update --arg branch "$branch" --argjson interval "$interval" --argjson now "$now" '
                .continuous_nudges = (.continuous_nudges // {})
                | .continuous_nudges[$branch] = {
                    interval_minutes:$interval,
                    created_at:(.continuous_nudges[$branch].created_at // $now),
                    last_run_at:(.continuous_nudges[$branch].last_run_at // 0),
                    next_run_at:($now + $interval * 60)
                }
            ' || { record_command_error "Nie udało się zapisać continuous nudge dla $branch"; continue; }
            if ! queue_command nudge "$branch $NUDGE_BASE_SHA $NUDGE_REMOTE_SHA"; then
                config_update --arg branch "$branch" 'del(.continuous_nudges[$branch])' || true
                record_command_error "Nie udało się zakolejkować pierwszego nudge dla $branch"
                continue
            fi
            record_command_success "Continuous nudge: $branch co $interval min"
            ((++scheduled))
        else
            record_command_error "${LAST_ERROR:-Nie udało się przygotować continuous nudge dla $branch}"
        fi
    done
    ((scheduled > 0))
}

stop_continuous_nudges() {
    local specification="$1" branch removed
    if [[ "${specification,,}" == "all" ]]; then
        removed="$(jq '.continuous_nudges // {} | length' "$CONFIG_FILE")"
        config_update '.continuous_nudges={}' || return 1
        record_command_success "Zatrzymano wszystkie continuous nudge ($removed)"
        return 0
    fi
    branch="$(normalize_branch_name "$specification")"
    if ! jq -e --arg branch "$branch" '(.continuous_nudges // {}) | has($branch)' "$CONFIG_FILE" >/dev/null; then
        operation_error "Continuous nudge dla $branch nie jest aktywny."
        return 1
    fi
    config_update --arg branch "$branch" 'del(.continuous_nudges[$branch])' || return 1
    record_command_success "Zatrzymano continuous nudge: $branch"
}

schedule_due_continuous_nudge() {
    local row branch interval now base remote warning
    now="$(date +%s)"
    row="$(jq -r --argjson now "$now" '
        (.continuous_nudges // {})
        | to_entries
        | map(select(.value.next_run_at <= $now))
        | sort_by(.value.next_run_at)
        | first
        | if . == null then empty else [.key,.value.interval_minutes] | @tsv end
    ' "$CONFIG_FILE")"
    [[ -n "$row" ]] || return 1
    IFS=$'\t' read -r branch interval <<<"$row"
    config_update --arg branch "$branch" --argjson now "$now" --argjson interval "$interval" '
        if (.continuous_nudges // {} | has($branch)) then
            .continuous_nudges[$branch].next_run_at=($now + $interval * 60)
        else .
        end
    ' || return 1
    if ! assess_nudge_branch "$branch"; then
        record_command_error "Continuous nudge $branch: ${LAST_ERROR:-nie udało się przygotować operacji}"
        return 0
    fi
    base="$NUDGE_BASE_SHA"
    remote="$NUDGE_REMOTE_SHA"
    warning="$NUDGE_WARNING"
    if [[ -n "$warning" ]]; then
        record_command_error "Continuous nudge $branch pominięty: wykryto lokalne zmiany wymagające potwierdzenia"
        return 0
    fi
    queue_command continuous_nudge "$branch $base $remote" \
        || record_command_error "Nie udało się zakolejkować continuous nudge dla $branch"
    return 0
}

spinner_dots() {
    local count
    count=$((EPOCHSECONDS % 3 + 1))
    printf '%*s' "$count" '' | tr ' ' '.'
}

format_duration() {
    local seconds="$1"
    ((seconds < 0)) && seconds=0
    if ((seconds >= 3600)); then
        printf '%dh %dm %ds' "$((seconds / 3600))" "$(((seconds % 3600) / 60))" "$((seconds % 60))"
    elif ((seconds >= 60)); then
        printf '%dm %ds' "$((seconds / 60))" "$((seconds % 60))"
    else
        printf '%ds' "$seconds"
    fi
}

classification_label() {
    local classification="$1"
    case "$classification" in
        "up to date") printf '\033[36m[up to date]\033[0m' ;;
        mergable) printf '\033[32m[mergable]\033[0m' ;;
        "simple conflicts") printf '\033[33m[simple conflicts]\033[0m' ;;
        conflicts) printf '\033[31m[conflicts]\033[0m' ;;
        *) printf '[checking]' ;;
    esac
}

action_label() {
    local action="$1"
    local eligible_at="$2"
    local now remaining
    now="$EPOCHSECONDS"
    case "$action" in
        ready) printf '\033[32m[ready]\033[0m' ;;
        waiting)
            remaining=$((eligible_at - now))
            if ((remaining <= 0)); then
                printf '\033[38;5;208m[queued]\033[0m'
            else
                printf '[waiting: %s]' "$(format_duration "$remaining")"
            fi
            ;;
        queued) printf '\033[38;5;208m[queued]\033[0m' ;;
        merging) printf '\033[35m[merging%s]\033[0m' "$(spinner_dots)" ;;
        merged) printf '\033[32m[merged]\033[0m' ;;
        skipped) printf '\033[38;5;208m[SKIPPED]\033[0m' ;;
        ignored) printf '[ignored]' ;;
        fail | blocked) printf '\033[31m[FAIL]\033[0m' ;;
        attention) printf '\033[38;5;208m[NEED ATTENTION]\033[0m' ;;
        manual) printf '[manual]' ;;
        *) printf '[checking%s]' "$(spinner_dots)" ;;
    esac
}

compact_classification_label() {
    case "$1" in
        "up to date") printf '\033[36m[current]\033[0m' ;;
        mergable) printf '\033[32m[ok]\033[0m' ;;
        "simple conflicts") printf '\033[33m[simple]\033[0m' ;;
        conflicts) printf '\033[31m[conflict]\033[0m' ;;
        *) printf '[…]' ;;
    esac
}

compact_action_label() {
    local action="$1" eligible_at="$2" remaining
    case "$action" in
        ready) printf '\033[32m[ready]\033[0m' ;;
        waiting)
            remaining=$((eligible_at - EPOCHSECONDS))
            if ((remaining <= 0)); then
                printf '\033[38;5;208m[queue]\033[0m'
            elif ((remaining >= 60)); then
                printf '[wait %dm]' "$((remaining / 60))"
            else
                printf '[wait %ds]' "$remaining"
            fi
            ;;
        queued) printf '\033[38;5;208m[queue]\033[0m' ;;
        merging) printf '\033[35m[merging]\033[0m' ;;
        merged) printf '\033[32m[merged]\033[0m' ;;
        skipped) printf '\033[38;5;208m[skip]\033[0m' ;;
        ignored) printf '[ignored]' ;;
        fail | blocked) printf '\033[31m[FAIL]\033[0m' ;;
        attention) printf '\033[38;5;208m[attention]\033[0m' ;;
        manual) printf '[manual]' ;;
        *) printf '[…]' ;;
    esac
}

visible_length() {
    local value="$1"
    while [[ "$value" =~ $'\033'\[[0-9\;]*m ]]; do
        value="${value/"${BASH_REMATCH[0]}"/}"
    done
    printf '%d' "${#value}"
}

truncate_text() {
    local value="$1"
    local width="$2"
    if ((${#value} <= width)); then
        printf '%s' "$value"
    elif ((width <= 1)); then
        printf '…'
    else
        printf '%s…' "${value:0:width-1}"
    fi
}

pad_cell() {
    local value="$1"
    local width="$2"
    local length padding
    length="$(visible_length "$value")"
    padding=$((width - length))
    ((padding < 0)) && padding=0
    printf '%s%*s' "$value" "$padding" ''
}

format_branch_line() {
    local branch="$1" classification="$2" action="$3" eligible="$4" error="$5" width="$6"
    local title_status="${7:-}"
    local title_warning="${8:-false}"
    local classification_text action_text branch_width warning=""
    case "$title_status" in
        resolving) branch+=" [resolving title$(spinner_dots)]" ;;
        retry) branch+=" [title retry pending]" ;;
        failed) branch+=" [title resolving failed]" ;;
    esac
    if ((width < 52)); then
        classification_text="$(compact_classification_label "$classification")"
        action_text="$(compact_action_label "$action" "$eligible")"
    else
        classification_text="$(classification_label "$classification")"
        action_text="$(action_label "$action" "$eligible")"
    fi
    [[ -z "$error" && "$title_warning" != "true" ]] || warning=$' \033[38;5;208m[!]\033[0m'
    branch_width=$((width - $(visible_length "$classification_text") - $(visible_length "$action_text") - $(visible_length "$warning") - 4))
    ((branch_width < 5)) && branch_width=5
    branch="$(truncate_text "$branch" "$branch_width")"
    printf '  %s %s %s%b' "$branch" "$classification_text" "$action_text" "$warning"
}

build_policy_lines() {
    local policy="$1" title="$2" width="$3"
    local -n output_ref="$4"
    local branch classification action eligible error title_status title_warning
    output_ref=($'\033[1m'"$(truncate_text "$title" "$width")"$'\033[0m')
    while IFS=$'\t' read -r branch classification action eligible error title_status title_warning; do
        [[ -n "$branch" ]] || continue
        [[ "$error" != "__AUTOMERGER_EMPTY__" ]] || error=""
        [[ "$title_status" != "__AUTOMERGER_EMPTY__" ]] || title_status=""
        output_ref+=("$(format_branch_line "$branch" "$classification" "$action" "$eligible" "$error" "$width" "$title_status" "$title_warning")")
    done < <(jq -r --arg policy "$policy" --slurpfile state "$STATE_FILE" --slurpfile branch_info "$BRANCHES_INFO_FILE" '
        . as $root
        | .tracked_branches
        | to_entries[]
        | select(.value.policy == $policy)
        | .key as $branch
        | ($state[0].branches[$branch] // {}) as $status
        | ($branch_info[0].branch_info[$branch].title // "") as $title
        | (if ($root.show_titles_in_main_view // false) and ($title | length) == 0
            then ($status.title_status // "")
            else ""
          end) as $title_status
        | (if ($root.show_titles_in_main_view // false) and ($title | length) > 0
            then "\($branch) - \($title)"
            else $branch
          end) as $display
        | [$display, ($status.mergeability // "checking"), ($status.action_state // "checking"),
            ($status.eligible_at // 0),
            (if ($status.error // "") == "" then "__AUTOMERGER_EMPTY__" else $status.error end),
            (if $title_status == "" then "__AUTOMERGER_EMPTY__" else $title_status end),
            ($status.title_warning // false)]
        | @tsv
    ' "$CONFIG_FILE")
    ((${#output_ref[@]} > 1)) || output_ref+=("  —")
}

build_log_lines() {
    local -n output_ref="$1"
    local label status count suffix
    output_ref=($'\033[1mOperacje\033[0m')
    while IFS=$'\t' read -r label status count; do
        [[ -n "$label" ]] || continue
        suffix=""
        ((count > 1)) && suffix=" (x$count)"
        case "$status" in
            RUNNING) output_ref+=("  $label$(spinner_dots)$suffix") ;;
            DONE) output_ref+=("  $label... "$'\033[32mDONE\033[0m'"$suffix") ;;
            *) output_ref+=("  $label... "$'\033[31mFAIL\033[0m'"$suffix") ;;
        esac
    done < <(jq -r '.logs[-7:][] | [.label,.status,(.count // 1)] | @tsv' "$STATE_FILE")
    ((${#output_ref[@]} > 1)) || output_ref+=("  Brak operacji.")
}

terminal_dimensions() {
    local rows columns
    rows="${LINES:-$(tput lines 2>/dev/null || printf '24')}"
    columns="${COLUMNS:-$(tput cols 2>/dev/null || printf '80')}"
    [[ "$rows" =~ ^[0-9]+$ && "$rows" -ge 8 ]] || rows=24
    [[ "$columns" =~ ^[0-9]+$ && "$columns" -ge 40 ]] || columns=80
    TUI_ROWS="$rows"
    TUI_COLUMNS="$columns"
    TUI_INPUT_ROW="$rows"
}

update_now_ms() {
    local epoch="$EPOCHREALTIME"
    local seconds fraction
    seconds="${epoch%%[.,]*}"
    if [[ "$epoch" == *.* ]]; then
        fraction="${epoch#*.}"
    elif [[ "$epoch" == *,* ]]; then
        fraction="${epoch#*,}"
    else
        fraction="0"
    fi
    fraction="${fraction}000"
    fraction="${fraction:0:3}"
    [[ "$seconds" =~ ^[0-9]+$ && "$fraction" =~ ^[0-9]{3}$ ]] || {
        NOW_MS=$((EPOCHSECONDS * 1000))
        return
    }
    NOW_MS=$((10#$seconds * 1000 + 10#$fraction))
}

build_status_lines() {
    local available_rows=$((TUI_ROWS - 1))
    local column_width max_rows index
    local -a basic=() simple=() full=() manual=() logs=() content=() result=()
    local header=$'\033[1mAUTOMERGER\033[0m'"  repo: $(truncate_text "$WORKDIR" "$((TUI_COLUMNS / 2))")  target_branch: $REMOTE/$TARGET_BRANCH"
    [[ -e "$STOP_FILE" ]] && header+=$'  \033[31m[STOPPED]\033[0m'
    github_token_is_active && header+=$'  \033[32m[GH TOKEN ACTIVE]\033[0m'
    content+=("$header" "")
    if ((TUI_COLUMNS >= 105)); then
        column_width=$(((TUI_COLUMNS - 4) / 3))
        build_policy_lines "$POLICY_BASIC" "basic_automerge" "$column_width" basic
        build_policy_lines "$POLICY_AI_SIMPLE" "ai_automerge_simple" "$column_width" simple
        build_policy_lines "$POLICY_AI_ALL" "ai_automerge_all" "$column_width" full
        max_rows="${#basic[@]}"
        ((${#simple[@]} > max_rows)) && max_rows="${#simple[@]}"
        ((${#full[@]} > max_rows)) && max_rows="${#full[@]}"
        for ((index = 0; index < max_rows; index++)); do
            content+=("$(pad_cell "${basic[$index]:-}" "$column_width")  $(pad_cell "${simple[$index]:-}" "$column_width")  $(pad_cell "${full[$index]:-}" "$column_width")")
        done
    else
        build_policy_lines "$POLICY_BASIC" "basic_automerge" "$TUI_COLUMNS" basic
        build_policy_lines "$POLICY_AI_SIMPLE" "ai_automerge_simple" "$TUI_COLUMNS" simple
        build_policy_lines "$POLICY_AI_ALL" "ai_automerge_all" "$TUI_COLUMNS" full
        content+=("${basic[@]}" "" "${simple[@]}" "" "${full[@]}")
    fi
    build_policy_lines "$POLICY_MANUAL" "manual — tylko monitoring" "$TUI_COLUMNS" manual
    content+=("" "${manual[@]}")
    build_log_lines logs
    if ((${#content[@]} + ${#logs[@]} > available_rows)); then
        max_rows=$((available_rows - ${#logs[@]} - 1))
        ((max_rows < 2)) && max_rows=2
        result=("${content[@]:0:max_rows}" $'\033[2m… część statusów ukryta z powodu wysokości terminala …\033[0m')
    else
        result=("${content[@]}")
    fi
    result+=("${logs[@]}")
    SCREEN_LINES=("${result[@]:0:available_rows}")
}

render_screen() {
    local input_buffer="${1:-}"
    local old_rows="$TUI_ROWS" old_columns="$TUI_COLUMNS"
    local row max_rows body="" output
    terminal_dimensions
    if ((old_rows != TUI_ROWS || old_columns != TUI_COLUMNS)); then
        reset_renderer
        printf '\033[%d;1H\033[2K\033[%d;1H\033[2K> %s' "$old_rows" "$TUI_INPUT_ROW" "$input_buffer"
    fi
    declare -ga SCREEN_LINES=()
    build_status_lines
    max_rows="${#RENDERED_LINES[@]}"
    ((${#SCREEN_LINES[@]} > max_rows)) && max_rows="${#SCREEN_LINES[@]}"
    for ((row = 0; row < max_rows && row < TUI_INPUT_ROW - 1; row++)); do
        if [[ "${SCREEN_LINES[$row]:-}" != "${RENDERED_LINES[$row]:-}" ]]; then
            body+=$'\033['"$((row + 1))"$';1H\033[2K'
            body+="${SCREEN_LINES[$row]:-}"
        fi
    done
    if [[ -n "$body" ]]; then
        output=$'\0337\033[?25l\033[?2026h'
        output+="$body"
        output+=$'\033[?2026l\0338\033[?25h'
        printf '%s' "$output"
    fi
    RENDERED_LINES=("${SCREEN_LINES[@]}")
}

render_input_line() {
    local input_buffer="$1"
    printf '\033[%d;1H\033[2K> %s' "$TUI_INPUT_ROW" "$input_buffer"
}

clear_tui_input_line() {
    [[ "$TUI_ACTIVE" == "true" ]] || return 0
    terminal_dimensions
    printf '\033[%d;1H\033[2K' "$TUI_INPUT_ROW"
}

reset_renderer() {
    local row
    RENDERED_LINES=()
    for ((row = 0; row < TUI_INPUT_ROW - 1; row++)); do
        RENDERED_LINES+=("__force_redraw__")
    done
}

enter_tui_character_mode() {
    stty -echo -icanon min 0 time 0 2>/dev/null || true
}

read_tui_line() {
    local variable_name="$1" value="" exit_code
    if [[ "$TUI_ACTIVE" == "true" ]]; then
        stty "$TUI_STTY_STATE" 2>/dev/null || true
    fi
    IFS= read -r value
    exit_code=$?
    if [[ "$TUI_ACTIVE" == "true" ]]; then
        enter_tui_character_mode
    fi
    printf -v "$variable_name" '%s' "$value"
    return "$exit_code"
}

read_tui_secret() {
    local variable_name="$1" prompt="$2" value="" exit_code
    clear_tui_input_line
    printf '%s' "$prompt" >&2
    if [[ "$TUI_ACTIVE" == "true" ]]; then
        stty "$TUI_STTY_STATE" 2>/dev/null || true
    fi
    IFS= read -rs value
    exit_code=$?
    printf '\n' >&2
    if [[ "$TUI_ACTIVE" == "true" ]]; then
        enter_tui_character_mode
    fi
    printf -v "$variable_name" '%s' "$value"
    return "$exit_code"
}

command_contains_secret() {
    local command_line
    command_line="$(trim "$1")"
    case "${command_line%% *}" in
        decrypt | activate_token | activate-token) return 0 ;;
        *) return 1 ;;
    esac
}

choose_policy_interactive() {
    local answer
    clear_tui_input_line
    printf 'Wybierz politykę: 1) ai_automerge_all  2) ai_automerge_simple  3) basic_automerge  4) manual\n> ' >&2
    read_tui_line answer || return 1
    case "$answer" in
        1) answer="$POLICY_AI_ALL" ;;
        2) answer="$POLICY_AI_SIMPLE" ;;
        3) answer="$POLICY_BASIC" ;;
        4 | '') answer="$POLICY_MANUAL" ;;
    esac
    INTERACTIVE_VALUE="$(normalize_policy "$answer")" || return 1
}

choose_cooldown_interactive() {
    local answer
    clear_tui_input_line
    printf 'Cooldown w minutach (liczba lub auto) [auto]: ' >&2
    read_tui_line answer || return 1
    answer="${answer:-auto}"
    [[ "$answer" == "auto" || "$answer" =~ ^[0-9]+$ ]] || return 1
    INTERACTIVE_VALUE="$answer"
}

parse_candidate_selection() {
    local selection="$1"
    shift
    local item index branch result=""
    local -a candidates=("$@") selected=()
    selection="$(trim "$selection")"
    if [[ "${selection,,}" == "all" ]]; then
        for branch in "${candidates[@]}"; do
            [[ -z "$result" ]] || result+=","
            result+="$branch"
        done
        INTERACTIVE_VALUE="$result"
        return 0
    fi
    selection="$(printf '%s' "$selection" | sed -E 's/,[[:space:]]*/,/g')"
    [[ -n "$selection" ]] || return 1
    IFS=',' read -r -a selected <<<"$selection"
    for item in "${selected[@]}"; do
        [[ "$item" =~ ^[0-9]+$ ]] || return 1
        index=$((item - 1))
        ((index >= 0 && index < ${#candidates[@]})) || return 1
        branch="${candidates[$index]}"
        [[ -z "$result" ]] || result+=","
        result+="$branch"
    done
    INTERACTIVE_VALUE="$result"
}

choose_branches_interactive() {
    local mode="$1"
    local -a candidates=()
    local selection index
    if [[ "$mode" == "track" ]] && command -v gh >/dev/null 2>&1; then
        mapfile -t candidates < <(
            cd -- "$WORKDIR" \
                && timeout --foreground "${PR_DISCOVERY_TIMEOUT}s" \
                    gh pr list --author @me --state open --json headRefName --jq '.[].headRefName' 2>/dev/null \
                || true
        )
    else
        mapfile -t candidates < <(jq -r '.tracked_branches | keys[]' "$CONFIG_FILE")
    fi
    if ((${#candidates[@]} == 0)); then
        mapfile -t candidates < <(git -C "$WORKDIR" for-each-ref --format='%(refname:strip=3)' "refs/remotes/$REMOTE" | grep -Fvx "$TARGET_BRANCH")
    fi
    if [[ "$mode" == "track" ]]; then
        start_candidate_title_resolution "${candidates[@]}"
        render_title_candidates "${candidates[@]}"
    fi
    clear_tui_input_line
    printf 'Wybierz branche (numery po przecinku lub all):\n' >&2
    if [[ "$mode" != "track" ]]; then
        for index in "${!candidates[@]}"; do
            printf '  %d) %s\n' "$((index + 1))" "${candidates[$index]}" >&2
        done
    fi
    printf '> ' >&2
    read_tui_line selection || return 1
    parse_candidate_selection "$selection" "${candidates[@]}"
}

handle_track_interactive() {
    local raw="$1"
    local normalized branches_token supplied_policy supplied_cooldown supplied_merge_without_conflicts branch policy cooldown
    local -a branches=()
    if [[ -z "$(trim "$raw")" ]]; then
        choose_branches_interactive track || return 1
        branches_token="$INTERACTIVE_VALUE"
    else
        normalized="$(printf '%s' "$raw" | sed -E 's/,[[:space:]]*/,/g')"
        read -r branches_token supplied_policy supplied_cooldown supplied_merge_without_conflicts _ <<<"$normalized"
    fi
    IFS=',' read -r -a branches <<<"$branches_token"
    for branch in "${branches[@]}"; do
        branch="$(normalize_branch_name "$branch")"
        printf '\nKonfiguracja brancha %s\n' "$branch" >&2
        if [[ -n "${supplied_policy:-}" ]]; then
            policy="$supplied_policy"
        else
            choose_policy_interactive || return 1
            policy="$INTERACTIVE_VALUE"
        fi
        if [[ -n "${supplied_cooldown:-}" ]]; then
            cooldown="$supplied_cooldown"
        else
            choose_cooldown_interactive || return 1
            cooldown="$INTERACTIVE_VALUE"
        fi
        track_branches "$branch $policy $cooldown ${supplied_merge_without_conflicts:-}" || return 1
    done
}

show_pending_pull_requests() {
    local selection branches branch was_stopped=false
    local -a pending=() candidates=()
    mapfile -t pending < <(jq -r '
        (.pr_discovery.pending // [])[]
    ' "$STATE_FILE" 2>/dev/null)
    for branch in "${pending[@]}"; do
        if ! jq -e --arg branch "$branch" '.tracked_branches | has($branch)' "$CONFIG_FILE" >/dev/null; then
            candidates+=("$branch")
        fi
    done
    if ((${#candidates[@]} == 0)); then
        ((${#pending[@]} == 0)) || state_update '.pr_discovery.pending=[]'
        return 1
    fi
    [[ -e "$STOP_FILE" ]] && was_stopped=true
    touch "$STOP_FILE"
    start_candidate_title_resolution "${candidates[@]}"
    printf '\033[2J\033[H'
    render_title_candidates "${candidates[@]}"
    printf '\nWykryto nowe otwarte PR. Wpisz numery lub all, aby dodać je do śledzenia.\n'
    printf 'ENTER pomija to powiadomienie.\n> '
    read_tui_line selection || selection=""
    state_update '.pr_discovery.pending=[]'
    selection="$(trim "$selection")"
    if [[ -n "$selection" ]]; then
        if parse_candidate_selection "$selection" "${candidates[@]}"; then
            branches="$INTERACTIVE_VALUE"
            if handle_track_interactive "$branches"; then
                record_command_success "Dodano nowe PR do śledzenia: $branches"
            else
                record_command_error "${LAST_ERROR:-Nie udało się skonfigurować nowych PR}"
            fi
        else
            record_command_error "Niepoprawny wybór nowych PR: $selection"
        fi
    fi
    [[ "$was_stopped" == "true" ]] || rm -f -- "$STOP_FILE"
    printf '\033[2J\033[H'
    reset_renderer
    return 0
}

show_lubudubu() {
    local message='niech żyje nam prezes naszego klubu! Nieeech żyje nam!'
    local width padding
    width="${COLUMNS:-$(tput cols 2>/dev/null || printf '80')}"
    padding=$(((width - ${#message}) / 2))
    ((padding < 0)) && padding=0
    printf '\033[H\033[2J%*s%s\n' "$padding" '' "$message"
    sleep 2
}

show_help() {
    local help_text
    help_text=$'\033[H\033[2J\033[1mAUTOMERGER — pomoc\033[0m\n\n'
    help_text+=$'  track [branche] [policy] [cooldown] [true|false]  tracking i merge_without_conflicts\n'
    help_text+=$'  untrack [branch[,branch...]]                    usuwa śledzenie\n'
    help_text+=$'  stop / resume                                  zatrzymuje / wznawia automat\n'
    help_text+=$'  kill                                           zatrzymuje automat i aktywne polecenie\n'
    help_text+=$'  start / restart                                uruchamia worker od nowa\n'
    help_text+=$'  reset / clear                                  usuwa lokalne refy automergera i cały tracking\n'
    help_text+=$'  purge / purge_local_branches                   usuwa zmergowane, osierocone branche lokalne\n'
    help_text+=$'  update / update_local_branches                 wykonuje git pull dla lokalnych branchy z prefiksem\n'
    help_text+=$'  merge <branch>                                 jednorazowy merge jak ai_automerge_all, bez zmiany polityki\n'
    help_text+=$'  remove_title <branch|all>                      usuwa zapisany tytuł lub wszystkie tytuły\n'
    help_text+=$'  title / retitle <branch|all>                   generuje lub regeneruje tytuł\n'
    help_text+=$'  show <branch>                                  pokazuje tytuł i labele PR w logu [EKSPERYMENTALNE]\n'
    help_text+=$'  show_titles / hide_titles                      pokazuje / ukrywa tytuły w widoku głównym\n'
    help_text+=$'  nudge / rush / poke <branch|all|labeled|unlabeled>  pusty commit i push; filtry labeli [EKSPERYMENTALNE]\n'
    help_text+=$'  continuous_nudge <branch|all> [minuty]         cykliczny pusty commit i push\n'
    help_text+=$'  stop_continuous_nudge <branch|all>             zatrzymuje cykliczny nudge\n'
    help_text+=$'  clear_operations_log                           czyści log operacji TUI we wszystkich runtime\n'
    help_text+=$'  remove_log <model|title|all> [title]           usuwa trwałe logi błędów modeli\n'
    help_text+=$'  decrypt / activate_token [klucz]               aktywuje zaszyfrowany token GitHub w RAM\n'
    help_text+=$'  add_label / label <branch> <label>             dodaje labelkę do PR [EKSPERYMENTALNE]\n'
    help_text+=$'  remove_label <branch> <label|all>              usuwa labelkę albo wszystkie labele PR [EKSPERYMENTALNE]\n'
    help_text+=$'  ask <pytanie>                                  pyta model o stan i diagnostykę automergera\n'
    help_text+=$'  autorepair [opis problemu]                     kopia skryptu i próba autonaprawy przez model\n'
    help_text+=$'  git <argumenty>                                wykonuje polecenie git w workdir\n'
    help_text+=$'  com <polecenie>                                wykonuje polecenie powłoki w workdir\n'
    help_text+=$'  help                                            pokazuje tę planszę\n'
    help_text+=$'  exit                                            kończy program\n\n'
    help_text+=$'Polityki: basic, simple, full, manual (pełne nazwy również działają).\n'
    help_text+="Sam numer brancha używa prefiksu '$DEFAULT_BRANCH_PREFIX'. Komenda track może być pominięta."
    help_text+=$'\n\n\033[2mNaciśnij dowolny klawisz, aby wrócić.\033[0m'
    printf '%b' "$help_text"
    IFS= read -rsn1 _ || true
    reset_renderer
}

confirm_action() {
    local prompt="$1" answer
    clear_tui_input_line
    printf '%s [t/N]: ' "$prompt" >&2
    read_tui_line answer || return 1
    case "${answer,,}" in
        t | tak | y | yes) return 0 ;;
        *) return 1 ;;
    esac
}

show_notice() {
    local title="$1" message="$2"
    printf '\033[2J\033[H\033[1m%s\033[0m\n\n%s\n\n\033[2mNaciśnij dowolny klawisz, aby wrócić.\033[0m' \
        "$title" "$message"
    IFS= read -rsn1 _ || true
    printf '\033[2J\033[H'
    reset_renderer
}

read_escape_key() {
    local next sequence="" count=0
    ESCAPE_KEY="other"
    while ((count < 8)) && IFS= read -rn1 -t 0.20 next; do
        ((count++))
        sequence+="$next"
        case "$sequence" in
            '[A' | 'OA') ESCAPE_KEY="up"; return 0 ;;
            '[B' | 'OB') ESCAPE_KEY="down"; return 0 ;;
            '[C' | 'OC') ESCAPE_KEY="right"; return 0 ;;
            '[D' | 'OD') ESCAPE_KEY="left"; return 0 ;;
        esac
        [[ "$next" =~ [[:alpha:]~] ]] && break
    done
}

show_pending_command_output() {
    local row id label path status auto_close max_lines line key
    row="$(jq -r '
        (.command_outputs // [])
        | map(select(.shown != true))
        | first
        | if . == null then empty
          else [.id,.label,.path,.status,(.auto_close // true)] | @tsv
          end
    ' "$STATE_FILE" 2>/dev/null || true)"
    [[ -n "$row" ]] || return 1
    IFS=$'\t' read -r id label path status auto_close <<<"$row"
    terminal_dimensions
    max_lines=$((TUI_ROWS - 6))
    ((max_lines < 1)) && max_lines=1
    printf '\033[2J\033[H\033[1mWynik: %s\033[0m  [%s]\n\n' "$label" "$status"
    if [[ -s "$path" ]]; then
        while IFS= read -r line; do
            line="$(printf '%s' "$line" | sed -E $'s/\\x1B\\[[0-9;?]*[ -/]*[@-~]//g')"
            printf '%s\033[K\n' "$(truncate_text "$line" "$TUI_COLUMNS")"
        done < <(tail -n "$max_lines" -- "$path")
    else
        printf '(polecenie nie zwróciło tekstu)\n'
    fi
    if [[ "$auto_close" == "false" ]]; then
        printf '\n\033[2mNaciśnij dowolny klawisz, aby wrócić do ekranu głównego.\033[0m'
        IFS= read -rsn1 key || true
    else
        printf '\n\033[2mNaciśnij dowolny klawisz, aby wrócić; automatyczny powrót za %ds.\033[0m' \
            "$COMMAND_OUTPUT_AUTO_CLOSE_SECONDS"
        IFS= read -rsn1 -t "$COMMAND_OUTPUT_AUTO_CLOSE_SECONDS" key || true
    fi
    [[ "$key" == $'\e' ]] && read_escape_key
    state_update --arg id "$id" '
        .command_outputs |= map(if .id == $id then .shown=true else . end)
    '
    rm -f -- "$path"
    printf '\033[2J\033[H'
    reset_renderer
    return 0
}

record_command_error() {
    local message="$1"
    local id
    log_start "$message"
    id="$LAST_LOG_ID"
    log_finish "$id" "FAIL"
}

record_command_success() {
    local message="$1"
    local id
    log_start "$message"
    id="$LAST_LOG_ID"
    log_finish "$id" "DONE"
}

handle_command() {
    local command_line="$1"
    local command rest branches branch title interval extra token_key label labels label_count
    local -a labels_to_remove=()
    LAST_ERROR=""
    command_line="$(trim "$command_line")"
    [[ -n "$command_line" ]] || return 0
    command="${command_line%% *}"
    if [[ "$command_line" == *' '* ]]; then
        rest="${command_line#* }"
    else
        rest=""
    fi
    if looks_like_branch_command "$command"; then
        rest="$command_line"
        command="track"
    fi
    case "$command" in
        track | tr | add)
            touch "$STOP_FILE"
            if ! handle_track_interactive "$rest"; then
                record_command_error "${LAST_ERROR:-Niepoprawne parametry track}"
            fi
            rm -f -- "$STOP_FILE"
            reset_renderer
            ;;
        untrack | un | remove)
            if [[ -z "$(trim "$rest")" ]]; then
                if choose_branches_interactive untrack; then
                    branches="$INTERACTIVE_VALUE"
                else
                    branches=""
                fi
            else
                branches="$rest"
            fi
            if [[ -n "$branches" ]]; then
                if ! untrack_branches "$branches"; then
                    record_command_error "${LAST_ERROR:-Niepoprawne parametry untrack}"
                fi
            fi
            reset_renderer
            ;;
        stop | pause)
            touch "$STOP_FILE"
            stop_ai_immediately
            ;;
        kill)
            touch "$STOP_FILE"
            stop_current_immediately
            ;;
        resume | continue)
            rm -f -- "$STOP_FILE"
            ;;
        start | restart)
            restart_worker
            ;;
        decrypt | activate_token | activate-token)
            token_key="$(trim "$rest")"
            if [[ -z "$token_key" ]]; then
                read_tui_secret token_key "Klucz do odszyfrowania tokenu GitHub: " || token_key=""
            fi
            if [[ -z "$token_key" ]]; then
                record_command_error "Nie podano klucza do odszyfrowania tokenu GitHub"
            elif activate_github_access_token "$token_key"; then
                record_command_success "Token GitHub został aktywowany w bieżącej sesji"
            else
                record_command_error "${LAST_ERROR:-Nie udało się aktywować tokenu GitHub}"
            fi
            token_key=""
            unset token_key
            reset_renderer
            ;;
        reset | clear)
            if confirm_action "Usunąć wszystkie lokalne refy automergera i tracking? Zmiany wypchnięte do remote pozostaną bez zmian."; then
                if reset_local_state; then
                    show_notice "Reset zakończony" \
                        "Usunięto lokalne refy automergera: $RESET_REMOVED_REFS. Wszystkie branche są untracked. Automat pozostaje zatrzymany; użyj resume lub start."
                else
                    record_command_error "${LAST_ERROR:-Reset lokalnego stanu nie powiódł się}"
                fi
            fi
            reset_renderer
            ;;
        purge | purge_local_branches)
            if [[ -n "$(trim "$rest")" ]]; then
                record_command_error "Użycie: purge"
            elif [[ -z "$DEFAULT_BRANCH_PREFIX" ]]; then
                record_command_error "Purge wymaga niepustego default_branch_prefix"
            elif confirm_action "Usunąć lokalne branche zaczynające się od '$DEFAULT_BRANCH_PREFIX', które nie mają istniejącego upstreamu i są w pełni zmergeowane do $REMOTE/$TARGET_BRANCH?"; then
                queue_command purge "" \
                    || record_command_error "Nie udało się zakolejkować purge lokalnych branchy"
            fi
            reset_renderer
            ;;
        update | update_local_branches | update-local-branches)
            if [[ -n "$(trim "$rest")" ]]; then
                record_command_error "Użycie: update"
            elif [[ -z "$DEFAULT_BRANCH_PREFIX" ]]; then
                record_command_error "Update wymaga niepustego default_branch_prefix"
            else
                queue_command update_local_branches "" \
                    || record_command_error "Nie udało się zakolejkować aktualizacji lokalnych branchy"
            fi
            reset_renderer
            ;;
        merge)
            branch="$(trim "$rest")"
            if [[ -z "$branch" || "$branch" == *[[:space:]]* ]]; then
                record_command_error "Użycie: merge BRANCH"
            else
                branch="$(normalize_branch_name "$branch")"
                if git -C "$WORKDIR" check-ref-format --branch "$branch" >/dev/null 2>&1; then
                    queue_command force_merge "$branch" \
                        || record_command_error "Nie udało się zakolejkować jednorazowego merge $branch"
                else
                    record_command_error "Niepoprawna nazwa brancha: $branch"
                fi
            fi
            reset_renderer
            ;;
        remove_title | remove-title)
            stop_title_resolver
            if remove_branch_titles "$rest"; then
                record_command_success "remove_title ${rest:-?}"
            else
                record_command_error "${LAST_ERROR:-Nie udało się usunąć tytułu}"
            fi
            reset_renderer
            ;;
        add_title | add-title | title | retitle | refresh_title | refresh-title | recreate_title | recreate-title | resolve_title | resolve-title)
            if regenerate_branch_titles "$rest"; then
                record_command_success "Uruchomiono generowanie tytułów: $INTERACTIVE_VALUE"
            else
                record_command_error "${LAST_ERROR:-Nie udało się uruchomić title makera}"
            fi
            reset_renderer
            ;;
        ask)
            if [[ "$TUI_ACTIVE" == "true" ]]; then
                start_ask_background "$(trim "$rest")" || record_command_error "${LAST_ERROR:-Nie udało się uruchomić ask}"
            elif ! ask_automerger "$(trim "$rest")"; then
                record_command_error "${LAST_ERROR:-Nie udało się uzyskać odpowiedzi modelu}"
            fi
            reset_renderer
            ;;
        autorepair | auto_repair | auto-repair)
            if ! autorepair_automerger "$(trim "$rest")"; then
                record_command_error "${LAST_ERROR:-Autorepair nie zastosował poprawki}"
            fi
            reset_renderer
            ;;
        show)
            branch="$(trim "$rest")"
            if [[ -z "$branch" || "$branch" == *[[:space:]]* ]]; then
                record_command_error "Użycie: show BRANCH"
            else
                branch="$(normalize_branch_name "$branch")"
                title="$(jq -r --arg branch "$branch" '.branch_info[$branch].title // empty' "$BRANCHES_INFO_FILE")"
                [[ -n "$title" ]] || title="(brak zapisanego tytułu)"
                if ! github_token_is_active; then
                    record_command_success "$branch - $title | labele PR: niedostępne (użyj decrypt; funkcja eksperymentalna)"
                elif labels="$(get_pull_request_labels "$branch")"; then
                    record_command_success "$branch - $title | labele PR: $(format_pull_request_labels "$labels")"
                else
                    record_command_error "Nie udało się pobrać labeli PR dla $branch (funkcja eksperymentalna)"
                fi
            fi
            ;;
        add_label | add-label | label)
            branch="${rest%%[[:space:]]*}"
            label="$(trim "${rest#"$branch"}")"
            if [[ -z "$branch" || -z "$label" ]]; then
                record_command_error "Użycie: add_label BRANCH LABEL"
            else
                branch="$(normalize_branch_name "$branch")"
                if ! git -C "$WORKDIR" check-ref-format --branch "$branch" >/dev/null 2>&1; then
                    record_command_error "Niepoprawna nazwa brancha: $branch"
                elif add_pull_request_label "$branch" "$label"; then
                    record_command_success "Dodano labelkę '$label' do PR $branch [eksperymentalne]"
                else
                    record_command_error "${LAST_ERROR:-Nie udało się dodać labelki do PR $branch}"
                fi
            fi
            reset_renderer
            ;;
        remove_label | remove-label)
            branch="${rest%%[[:space:]]*}"
            label="$(trim "${rest#"$branch"}")"
            if [[ -z "$branch" || -z "$label" ]]; then
                record_command_error "Użycie: remove_label BRANCH LABEL|all"
            else
                branch="$(normalize_branch_name "$branch")"
                if ! git -C "$WORKDIR" check-ref-format --branch "$branch" >/dev/null 2>&1; then
                    record_command_error "Niepoprawna nazwa brancha: $branch"
                elif [[ "${label,,}" != "all" ]]; then
                    if remove_pull_request_label "$branch" "$label"; then
                        record_command_success "Usunięto labelkę '$label' z PR $branch [eksperymentalne]"
                    else
                        record_command_error "${LAST_ERROR:-Nie udało się usunąć labelki z PR $branch}"
                    fi
                elif labels="$(get_pull_request_labels "$branch")"; then
                    mapfile -t labels_to_remove <<<"$labels"
                    label_count=0
                    for label in "${labels_to_remove[@]}"; do
                        [[ -n "$label" ]] || continue
                        if remove_pull_request_label "$branch" "$label"; then
                            ((++label_count))
                        else
                            record_command_error "${LAST_ERROR:-Nie udało się usunąć labelki '$label' z PR $branch}"
                            break
                        fi
                    done
                    if [[ -z "$LAST_ERROR" ]]; then
                        record_command_success "Usunięto $label_count label(e/i) z PR $branch [eksperymentalne]"
                    fi
                else
                    record_command_error "${LAST_ERROR:-Nie udało się pobrać labeli PR $branch}"
                fi
            fi
            reset_renderer
            ;;
        show_titles | show-titles)
            config_update '.show_titles_in_main_view=true'
            record_command_success "Tytuły branchy są widoczne w widoku głównym"
            reset_renderer
            ;;
        hide_titles | hide-titles)
            config_update '.show_titles_in_main_view=false'
            record_command_success "Tytuły branchy są ukryte w widoku głównym"
            reset_renderer
            ;;
        clear_operations_log | clear_operation_log | clear_operations_logs \
        | remove_operations_log | remove_operations_logs | remove_operation_log \
        | remove_operation_logs | remove_opertaions_logs)
            if clear_runtime_operation_logs; then
                printf '\033[2J\033[H'
            else
                record_command_error "Nie udało się wyczyścić logów operacji"
            fi
            reset_renderer
            ;;
        remove_log | remove_logs | clear_log | clear_logs)
            read -r branch interval extra <<<"$(trim "$rest")"
            if [[ -z "$branch" || -n "$extra" ]]; then
                record_command_error "Użycie: remove_log MODEL|title|all [title]"
            elif (
                flock -x 9
                remove_model_logs "$branch" "${interval:-}"
            ) 9>"$MODEL_LOG_LOCK"; then
                record_command_success "Usunięto szczegółowe logi: $rest"
            else
                record_command_error "${LAST_ERROR:-Nie udało się usunąć szczegółowych logów}"
            fi
            reset_renderer
            ;;
        nudge | rush | poke)
            branch="$(trim "$rest")"
            if [[ -z "$branch" || "$branch" == *[[:space:]]* ]]; then
                record_command_error "Użycie: nudge, rush albo poke BRANCH|all|labeled|unlabeled"
            elif collect_nudge_targets "$branch"; then
                queue_nudge_targets || true
            else
                record_command_error "${LAST_ERROR:-Nie udało się przygotować nudge}"
            fi
            reset_renderer
            ;;
        continuous_poke | continuous_rush | continuous_nudge | poke_continuous | rush_continuous | nudge_continuous)
            read -r branch interval extra <<<"$(trim "$rest")"
            if [[ -z "$branch" || -n "$extra" ]]; then
                record_command_error "Użycie: continuous_nudge BRANCH|all [MINUTY]"
            else
                if [[ -z "$interval" ]]; then
                    if choose_continuous_interval; then
                        interval="$INTERACTIVE_VALUE"
                    else
                        interval=""
                        record_command_error "Interwał musi być dodatnią liczbą minut"
                    fi
                fi
                if [[ -n "$interval" ]] && ! start_continuous_nudges "$branch" "$interval"; then
                    [[ -z "$LAST_ERROR" ]] || record_command_error "$LAST_ERROR"
                fi
            fi
            reset_renderer
            ;;
        stop_continuous_nudge | stop_continuous_rush | stop_continuous_poke \
        | continuous_stop_nudge | continuous_stop_rush | continuous_stop_poke \
        | nudge_stop_continuous | rush_stop_continuous | poke_stop_continuous \
        | stop_nudge_continuous | stop_rush_continuous | stop_poke_continuous \
        | continuous_nudge_stop | continuous_rush_stop | continuous_poke_stop \
        | nudge_continuous_stop | rush_continuous_stop | poke_continuous_stop)
            branch="$(trim "$rest")"
            if [[ -z "$branch" || "$branch" == *[[:space:]]* ]]; then
                record_command_error "Użycie: stop_continuous_nudge BRANCH|all"
            elif ! stop_continuous_nudges "$branch"; then
                record_command_error "${LAST_ERROR:-Nie udało się zatrzymać continuous nudge}"
            fi
            reset_renderer
            ;;
        git)
            [[ -n "$rest" ]] && queue_command git "$rest" || record_command_error "Pusta komenda git"
            ;;
        com)
            [[ -n "$rest" ]] && queue_command com "$rest" || record_command_error "Pusta komenda com"
            ;;
        help | h | '?')
            show_help
            ;;
        łubudubu)
            show_lubudubu
            ;;
        exit)
            return 10
            ;;
        *)
            record_command_error "Nieznana komenda: $command_line"
            ;;
    esac
    return 0
}

tui_cleanup() {
    local exit_code=$?
    if [[ -n "$ASK_PID" ]] && kill -0 "$ASK_PID" 2>/dev/null; then
        kill -TERM "$ASK_PID" 2>/dev/null || true
        wait "$ASK_PID" 2>/dev/null || true
    fi
    [[ -z "$ASK_OUTPUT_FILE" ]] || rm -f -- "$ASK_OUTPUT_FILE"
    GITHUB_ACCESS_TOKEN=""
    unset GITHUB_ACCESS_TOKEN
    if [[ -n "$TUI_STTY_STATE" ]]; then
        stty "$TUI_STTY_STATE" 2>/dev/null || true
        TUI_STTY_STATE=""
    fi
    if [[ "$TUI_ACTIVE" == "true" ]]; then
        printf '\033[?25h\033[0m\n'
        TUI_ACTIVE=false
    fi
    if [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
        kill -TERM "$WORKER_PID" 2>/dev/null || true
        wait "$WORKER_PID" 2>/dev/null || true
    fi
    stop_title_resolver
    if ((exit_code != 0)); then
        printf 'BŁĄD: interfejs automergera zakończył się nieoczekiwanie (kod %d).\n' "$exit_code" >&2
    fi
    return "$exit_code"
}

run_tui() {
    local input_buffer="" char command_status next_render_at last_keypress_at=0
    local history_index=0 history_draft=""
    local -a command_history=()
    [[ -t 0 && -t 1 ]] || die "Tryb ciągły wymaga interaktywnego terminala. Użyj --once do pracy bez TUI."
    trap tui_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    TUI_STTY_STATE="$(stty -g)"
    enter_tui_character_mode
    TUI_ACTIVE=true
    printf '\033[2J\033[H'
    terminal_dimensions
    render_input_line "$input_buffer"
    start_worker
    render_screen "$input_buffer"
    update_now_ms
    next_render_at=$((NOW_MS + UI_REFRESH_MS))
    while true; do
        if IFS= read -rsn1 -t 0.01 char; then
            update_now_ms
            last_keypress_at="$NOW_MS"
            if [[ -z "$char" ]]; then
                if [[ -n "$(trim "$input_buffer")" ]]; then
                    if ! command_contains_secret "$input_buffer"; then
                        if ((${#command_history[@]} == 0)) \
                            || [[ "${command_history[-1]}" != "$input_buffer" ]]; then
                            command_history+=("$input_buffer")
                            ((${#command_history[@]} > 100)) && command_history=("${command_history[@]:1}")
                        fi
                    fi
                    handle_command "$input_buffer"
                else
                    reset_renderer
                    render_screen ""
                fi
                command_status=$?
                ((command_status == 10)) && break
                input_buffer=""
                history_index="${#command_history[@]}"
                history_draft=""
                terminal_dimensions
                render_input_line "$input_buffer"
            elif [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
                input_buffer="${input_buffer%?}"
                render_input_line "$input_buffer"
            elif [[ "$char" == $'\e' ]]; then
                read_escape_key
                case "$ESCAPE_KEY" in
                    up)
                        if ((${#command_history[@]} > 0)); then
                            if ((history_index >= ${#command_history[@]})); then
                                history_draft="$input_buffer"
                                history_index="${#command_history[@]}"
                            fi
                            if ((history_index > 0)); then
                                ((history_index--))
                                input_buffer="${command_history[$history_index]}"
                                render_input_line "$input_buffer"
                            fi
                        fi
                        ;;
                    down)
                        if ((history_index < ${#command_history[@]})); then
                            ((history_index++))
                            if ((history_index == ${#command_history[@]})); then
                                input_buffer="$history_draft"
                            else
                                input_buffer="${command_history[$history_index]}"
                            fi
                            render_input_line "$input_buffer"
                        fi
                        ;;
                esac
            elif [[ "$char" =~ [[:print:]] ]]; then
                input_buffer+="$char"
                history_index="${#command_history[@]}"
                history_draft="$input_buffer"
                render_input_line "$input_buffer"
            fi
        fi
        update_now_ms
        if ((NOW_MS >= next_render_at \
            && NOW_MS - last_keypress_at >= INPUT_RENDER_QUIET_PERIOD_MS)); then
            schedule_due_title_retries
            if show_completed_ask; then
                terminal_dimensions
                render_input_line "$input_buffer"
            elif show_pending_command_output; then
                terminal_dimensions
                render_input_line "$input_buffer"
            elif [[ -z "$input_buffer" ]] && show_pending_pull_requests; then
                terminal_dimensions
                render_input_line "$input_buffer"
            fi
            render_screen "$input_buffer"
            next_render_at=$((NOW_MS + UI_REFRESH_MS))
        elif ((NOW_MS >= next_render_at)); then
            next_render_at=$((last_keypress_at + INPUT_RENDER_QUIET_PERIOD_MS))
        fi
    done
}

main_core_mode() {
    case "$MODE" in
        validate-config)
            printf 'Konfiguracja jest poprawna.\n'
            ;;
        classify)
            fetch_remote || die "git fetch zakończył się błędem."
            refresh_target_snapshot || die "Brak $REMOTE/$TARGET_BRANCH."
            remote_branch_exists "$MODE_ARGUMENT" || die "Branch $REMOTE/$MODE_ARGUMENT nie istnieje."
            classify_branch "$MODE_ARGUMENT"
            printf '\n'
            ;;
        resolve-title)
            MODE_ARGUMENT="$(normalize_branch_name "$MODE_ARGUMENT")"
            fetch_remote || die "git fetch zakończył się błędem."
            refresh_target_snapshot || die "Brak $REMOTE/$TARGET_BRANCH."
            remote_branch_exists "$MODE_ARGUMENT" || die "Branch $REMOTE/$MODE_ARGUMENT nie istnieje."
            if resolve_branch_title "$MODE_ARGUMENT"; then
                branch_title_label "$MODE_ARGUMENT"
                printf '\n'
            else
                die "Nie udało się przygotować tytułu brancha $MODE_ARGUMENT. Szczegóły: $MODEL_ERROR_LOG"
            fi
            ;;
        ask)
            ask_automerger "$MODE_ARGUMENT" || die "$LAST_ERROR"
            ;;
        autorepair)
            autorepair_automerger "$MODE_ARGUMENT" || die "$LAST_ERROR"
            ;;
        track)
            fetch_remote || die "git fetch zakończył się błędem."
            track_branches "$MODE_ARGUMENT" || die "$LAST_ERROR"
            printf 'Zapisano konfigurację śledzenia.\n'
            ;;
        untrack)
            untrack_branches "$MODE_ARGUMENT" || die "$LAST_ERROR"
            printf 'Usunięto konfigurację śledzenia.\n'
            ;;
        once)
            run_cycle
            ;;
        *)
            return 2
            ;;
    esac
}

main() {
    parse_arguments "$@"
    require_commands
    validate_config
    init_runtime
    if [[ "$MODE" != "tui" ]]; then
        main_core_mode
        return
    fi
    run_tui
}

main "$@"
