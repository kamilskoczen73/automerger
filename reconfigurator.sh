#!/usr/bin/env bash
# Copyright (c) 2026 Andrzej Janczak
# SPDX-License-Identifier: MIT


set -uo pipefail
umask 077

readonly RECONFIGURATOR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RECONFIGURATOR_CONFIG="${AUTOMERGER_CONFIG:-$RECONFIGURATOR_DIR/config.json}"

while (($# > 0)); do
    case "$1" in
        --config)
            (($# >= 2)) || { printf 'BŁĄD: --config wymaga ścieżki.\n' >&2; exit 2; }
            RECONFIGURATOR_CONFIG="$2"
            shift 2
            ;;
        --help | -h)
            printf 'Użycie: reconfigurator.sh [--config PLIK]\n'
            exit 0
            ;;
        *) printf 'BŁĄD: nieznana opcja: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# Współdzielone prompty, detekcja modeli i generatory komend. Guard na końcu
# configurator.sh zapobiega uruchomieniu jego pełnego kreatora podczas source.
source "$RECONFIGURATOR_DIR/configurator.sh" --config "$RECONFIGURATOR_CONFIG"

MAIN_CONFIG_FILE="$CONFIG_FILE"
MODELS_CONFIG_FILE=""
BRANCHES_CONFIG_FILE=""

pause_screen() {
    printf '\nNaciśnij ENTER, aby wrócić do menu.'
    IFS= read -r _ || true
}

broken_configuration() {
    printf '\n%sKonfiguracja automergera jest uszkodzona, niekompletna albo brakuje jednego z jej plików.%s\n' "$RED" "$RESET"
    printf 'Napraw ją ręcznie albo utwórz ponownie przy pomocy configurator.sh.\n'
    [[ -z "${CONFIGURATION_ERROR:-}" ]] || printf '\nSzczegóły: %s\n' "$CONFIGURATION_ERROR"
    printf '\nNaciśnij ENTER, aby zakończyć.'
    IFS= read -r _ || true
    exit 1
}

resolve_configuration_files() {
    local config_dir models_relative branches_relative
    [[ -r "$MAIN_CONFIG_FILE" ]] || return 1
    jq -e . "$MAIN_CONFIG_FILE" >/dev/null 2>&1 || return 1
    config_dir="$(cd -- "$(dirname -- "$MAIN_CONFIG_FILE")" && pwd -P)"
    models_relative="$(jq -r '.models_config_file // empty' "$MAIN_CONFIG_FILE")"
    branches_relative="$(jq -r '.branches_config_file // empty' "$MAIN_CONFIG_FILE")"
    is_safe_relative_path "$models_relative" && is_safe_relative_path "$branches_relative" || return 1
    MODELS_CONFIG_FILE="$(realpath -e -- "$config_dir/$models_relative" 2>/dev/null)" || return 1
    BRANCHES_CONFIG_FILE="$(realpath -e -- "$config_dir/$branches_relative" 2>/dev/null)" || return 1
    [[ "$MODELS_CONFIG_FILE" == "$config_dir"/* && "$BRANCHES_CONFIG_FILE" == "$config_dir"/* ]] || return 1
    jq -e . "$MODELS_CONFIG_FILE" >/dev/null 2>&1 && jq -e . "$BRANCHES_CONFIG_FILE" >/dev/null 2>&1
}

validate_current_configuration() {
    local output
    resolve_configuration_files || return 1
    if ! output="$("$RECONFIGURATOR_DIR/automerger.sh" --config "$MAIN_CONFIG_FILE" --validate-config 2>&1)"; then
        CONFIGURATION_ERROR="$(trim "$output")"
        return 1
    fi
    CONFIGURATION_ERROR=""
}

atomic_jq_update() {
    local file="$1" tmp
    shift
    tmp="$(mktemp "$(dirname -- "$file")/.reconfigurator.XXXXXX")" || return 1
    if jq "$@" "$file" >"$tmp"; then
        chmod --reference="$file" "$tmp" 2>/dev/null || chmod 600 -- "$tmp"
        mv -f -- "$tmp" "$file"
    else
        rm -f -- "$tmp"
        return 1
    fi
}

save_scalar() {
    local key="$1" value="$2" type="${3:-string}"
    if [[ "$type" == "json" ]]; then
        atomic_jq_update "$MAIN_CONFIG_FILE" --arg key "$key" --argjson value "$value" '.[$key]=$value'
    else
        atomic_jq_update "$MAIN_CONFIG_FILE" --arg key "$key" --arg value "$value" '.[$key]=$value'
    fi
}

edit_string_setting() {
    local key="$1" label="$2" current value
    current="$(jq -r --arg key "$key" '.[$key] // ""' "$MAIN_CONFIG_FILE")"
    value="$(prompt_nonempty "$label" "$current")" || return 1
    [[ "$value" == "$current" ]] || save_scalar "$key" "$value"
}

edit_integer_setting() {
    local key="$1" label="$2" minimum="$3" current value
    current="$(jq -r --arg key "$key" '.[$key]' "$MAIN_CONFIG_FILE")"
    value="$(prompt_positive_integer "$label" "$current" "$minimum")" || return 1
    [[ "$value" == "$current" ]] || save_scalar "$key" "$value" json
}

edit_boolean_setting() {
    local key="$1" label="$2" current value
    current="$(jq -r --arg key "$key" '.[$key] // false' "$MAIN_CONFIG_FILE")"
    value="$(prompt_boolean "$label" "$current")" || return 1
    [[ "$value" == "$current" ]] || save_scalar "$key" "$value" json
}

edit_workdir() {
    local current value remote
    current="$(jq -r '.workdir' "$MAIN_CONFIG_FILE")"
    value="$(prompt_workdir "$current")" || return 1
    remote="$(jq -r '.remote' "$MAIN_CONFIG_FILE")"
    git -C "$value" remote get-url "$remote" >/dev/null 2>&1 || {
        printf '%sWybrane repozytorium nie ma skonfigurowanego remote „%s”.%s\n' "$RED" "$remote" "$RESET"
        return 1
    }
    [[ "$value" == "$current" ]] || save_scalar workdir "$value"
}

edit_remote() {
    local current value workdir
    current="$(jq -r '.remote' "$MAIN_CONFIG_FILE")"
    value="$(prompt_nonempty remote "$current" true)" || return 1
    workdir="$(jq -r '.workdir' "$MAIN_CONFIG_FILE")"
    git -C "$workdir" remote get-url "$value" >/dev/null 2>&1 || {
        printf '%sRemote „%s” nie istnieje w skonfigurowanym repozytorium.%s\n' "$RED" "$value" "$RESET"
        return 1
    }
    [[ "$value" == "$current" ]] || save_scalar remote "$value"
}

edit_target_branch() {
    local current value
    current="$(jq -r '.target_branch' "$MAIN_CONFIG_FILE")"
    value="$(prompt_nonempty target_branch "$current" true)" || return 1
    git check-ref-format --branch "$value" >/dev/null 2>&1 || {
        printf '%sNiepoprawna nazwa brancha.%s\n' "$RED" "$RESET"
        return 1
    }
    [[ "$value" == "$current" ]] || save_scalar target_branch "$value"
}

edit_branch_prefix() {
    local current value
    current="$(jq -r '.default_branch_prefix' "$MAIN_CONFIG_FILE")"
    value="$(prompt_branch_prefix "$current")" || return 1
    [[ "$value" == "$current" ]] || save_scalar default_branch_prefix "$value"
}

edit_autoresolve_files() {
    local current answer item result='[]'
    current="$(jq -r '.autoresolve_files_list | join(",")' "$MAIN_CONFIG_FILE")"
    printf 'autoresolve_files_list — ścieżki po przecinku [%s]: ' "$current"
    IFS= read -r answer || return 1
    answer="$(trim "$answer")"
    [[ -n "$answer" ]] || return 0
    IFS=',' read -r -a entries <<<"$answer"
    for item in "${entries[@]}"; do
        item="$(trim "$item")"
        is_safe_relative_path "$item" || { printf '%sNiepoprawna ścieżka: %s%s\n' "$RED" "$item" "$RESET"; return 1; }
        result="$(jq -c --arg item "$item" '. + [$item]' <<<"$result")"
    done
    atomic_jq_update "$MAIN_CONFIG_FILE" --argjson value "$result" '.autoresolve_files_list=$value'
}

reset_model_discovery_arrays() {
    MODEL_KEYS=(); MODEL_PROVIDERS=(); MODEL_CODE_NAMES=(); MODEL_EFFORT_OPTIONS=(); MODEL_DEFAULT_EFFORTS=(); MODEL_COMMANDS=(); MODEL_CLOSE_COMMANDS=(); MODEL_BASE_NAMES=()
    AVAILABLE_MODEL_NAMES=(); AVAILABLE_MODEL_GROUPS=(); AVAILABLE_MODEL_EFFORTS=(); AVAILABLE_MODEL_RAW_NAMES=()
}

edit_available_model_catalog() {
    local before after detect commands close_commands existing_models new_models='{}' key
    local -a generated_keys=()
    reset_model_discovery_arrays
    load_configured_available_models
    before="$(build_available_models_json)"
    detect="$(prompt_boolean "Czy dodać modele wykryte obecnie w systemie?" false)" || return 1
    if [[ "$detect" == "true" ]]; then
        command -v codex >/dev/null 2>&1 && discover_codex_models
        command -v claude >/dev/null 2>&1 && discover_claude_models
        command -v openhands >/dev/null 2>&1 && discover_openhands_models
    fi
    edit_available_models || return 1
    configure_available_model_efforts || return 1
    after="$(build_available_models_json)"
    if [[ "$(jq -Sc . <<<"$before")" == "$(jq -Sc . <<<"$after")" ]]; then
        printf '%sKatalog nie został zmieniony.%s\n' "$GREEN" "$RESET"
        return 0
    fi
    build_model_variants
    commands="$(build_commands_json start)"
    close_commands="$(build_commands_json close)"
    mapfile -t generated_keys < <(printf '%s\n' "${MODEL_KEYS[@]}")
    existing_models="$(jq -c '.models' "$MODELS_CONFIG_FILE")"
    for key in "${generated_keys[@]}"; do
        new_models="$(jq -c --arg key "$key" --argjson existing "$existing_models" '.[$key]=($existing[$key] // {})' <<<"$new_models")"
    done
    if ! jq -e --argjson commands "$commands" '
        [.automerge_all_models[],.automerge_simple_models[],.title_maker_models[],.ask_models[]?,.autorepair_models[]?]
        | all(. as $model | $commands | has($model))
    ' "$MAIN_CONFIG_FILE" >/dev/null; then
        printf '%sNie można usunąć modelu używanego na liście fallbacków. Najpierw zmień odpowiednią listę modeli.%s\n' "$RED" "$RESET"
        return 1
    fi
    atomic_jq_update "$MODELS_CONFIG_FILE" --argjson available "$after" --argjson models "$new_models" \
        --argjson commands "$commands" --argjson close "$close_commands" '
        .available_models=$available | .models=$models | .model_commands=$commands | .model_close_commands=$close
    '
}

load_model_variants_from_catalog() {
    reset_model_discovery_arrays
    load_configured_available_models
    build_model_variants
}

edit_policy_models() {
    local key="$1" label="$2" required current proceed result
    local -a chosen=()
    current="$(jq -r --arg key "$key" '.[$key] | join(" -> ")' "$MAIN_CONFIG_FILE")"
    printf 'Obecna kolejność: %s\n' "${current:-(brak)}"
    proceed="$(prompt_boolean "Czy zastąpić tę listę?" false)" || return 1
    [[ "$proceed" == "true" ]] || return 0
    load_model_variants_from_catalog
    required=false
    case "$key" in
        automerge_simple_models)
            jq -e '[.tracked_branches[]?.policy] | any(. == "ai_automerge_simple")' "$BRANCHES_CONFIG_FILE" >/dev/null && required=true
            ;;
        automerge_all_models)
            jq -e '[.tracked_branches[]?.policy] | any(. == "ai_automerge_all")' "$BRANCHES_CONFIG_FILE" >/dev/null && required=true
            ;;
    esac
    select_model_order "$label" "Wybierz primary model i kolejne fallbacki." "$required" chosen || return 1
    result="$(array_to_json "${chosen[@]}")"
    atomic_jq_update "$MAIN_CONFIG_FILE" --arg key "$key" --argjson value "$result" '.[$key]=$value'
}

edit_model_limits() {
    local model context current_timeout current_attempts timeout attempts answer index
    local -a model_names=()
    mapfile -t model_names < <(jq -r '.models | keys[]' "$MODELS_CONFIG_FILE")
    printf 'Modele:\n'
    for ((index = 0; index < ${#model_names[@]}; index++)); do printf '  %d. %s\n' "$((index + 1))" "${model_names[$index]}"; done
    printf 'Wybierz model: '; IFS= read -r answer || return 1
    [[ "$answer" =~ ^[0-9]+$ ]] || return 1
    index=$((10#$answer - 1)); ((index >= 0 && index < ${#model_names[@]})) || return 1
    model="${model_names[$index]}"
    printf 'Kontekst [ogólny/ai_automerge_simple/ai_automerge_all/title_maker/ask/autorepair] [ogólny]: '
    IFS= read -r context || return 1; context="$(trim "$context")"; context="${context:-ogólny}"
    case "$context" in ogólny | ai_automerge_simple | ai_automerge_all | title_maker | ask | autorepair) ;; *) printf '%sNiepoprawny kontekst.%s\n' "$RED" "$RESET"; return 1 ;; esac
    if [[ "$context" == "ogólny" ]]; then
        current_timeout="$(jq -r --arg m "$model" '.models[$m].max_working_time // 300' "$MODELS_CONFIG_FILE")"
        current_attempts="$(jq -r --arg m "$model" '.models[$m].max_attempts // 2' "$MODELS_CONFIG_FILE")"
    else
        current_timeout="$(jq -r --arg m "$model" --arg c "$context" '.models[$m][$c].max_working_time // .models[$m].max_working_time // 300' "$MODELS_CONFIG_FILE")"
        current_attempts="$(jq -r --arg m "$model" --arg c "$context" '.models[$m][$c].max_attempts // .models[$m].max_attempts // 2' "$MODELS_CONFIG_FILE")"
    fi
    timeout="$(prompt_positive_integer "max_working_time" "$current_timeout" 1)" || return 1
    attempts="$(prompt_positive_integer "max_attempts" "$current_attempts" 1)" || return 1
    if [[ "$timeout" == "$current_timeout" && "$attempts" == "$current_attempts" ]]; then
        printf '%sLimity nie zostały zmienione.%s\n' "$GREEN" "$RESET"
        return 0
    fi
    if [[ "$context" == "ogólny" ]]; then
        atomic_jq_update "$MODELS_CONFIG_FILE" --arg m "$model" --argjson t "$timeout" --argjson a "$attempts" '.models[$m].max_working_time=$t | .models[$m].max_attempts=$a'
    else
        atomic_jq_update "$MODELS_CONFIG_FILE" --arg m "$model" --arg c "$context" --argjson t "$timeout" --argjson a "$attempts" '.models[$m][$c].max_working_time=$t | .models[$m][$c].max_attempts=$a'
    fi
}

show_main_menu() {
    cat <<'EOF'

RECONFIGURATOR — wybierz jedną rzecz do edycji

  1. Katalog dostępnych modeli i komendy
  2. Modele: ai_automerge_simple
  3. Modele: ai_automerge_all
  4. Modele: title_maker
  5. Modele: ask
  6. Modele: autorepair
  7. Limity wybranego modelu
  8. workdir
  9. remote
 10. target_branch
 11. default_branch_prefix
 12. autoresolve_files_list
 13. fetch_interval_seconds
 14. ui_refresh_ms
 15. merge_cooldown_time_m_default
 16. min_time_between_merges_m
 17. model_max_working_time_s_default
 18. model_max_attempts_default
 19. push_after_merge
 20. merge_without_conflicts_default
 21. git_user_name
 22. git_user_email
 23. show_titles_in_main_view
 24. model_logs_retention_days
 25. Przygotuj ponownie token GitHub
 26. Sprawdź dostępność wymaganych komend
  0. Zakończ
EOF
}

run_selected_screen() {
    case "$1" in
        1) edit_available_model_catalog ;;
        2) edit_policy_models automerge_simple_models ai_automerge_simple ;;
        3) edit_policy_models automerge_all_models ai_automerge_all ;;
        4) edit_policy_models title_maker_models title_maker ;;
        5) edit_policy_models ask_models ask ;;
        6) edit_policy_models autorepair_models autorepair ;;
        7) edit_model_limits ;;
        8) edit_workdir ;;
        9) edit_remote ;;
        10) edit_target_branch ;;
        11) edit_branch_prefix ;;
        12) edit_autoresolve_files ;;
        13) edit_integer_setting fetch_interval_seconds fetch_interval_seconds 1 ;;
        14) edit_integer_setting ui_refresh_ms ui_refresh_ms 1 ;;
        15) edit_integer_setting merge_cooldown_time_m_default merge_cooldown_time_m_default 0 ;;
        16) edit_integer_setting min_time_between_merges_m min_time_between_merges_m 0 ;;
        17) edit_integer_setting model_max_working_time_s_default model_max_working_time_s_default 1 ;;
        18) edit_integer_setting model_max_attempts_default model_max_attempts_default 1 ;;
        19) edit_boolean_setting push_after_merge push_after_merge ;;
        20) edit_boolean_setting merge_without_conflicts_default merge_without_conflicts_default ;;
        21) edit_string_setting git_user_name git_user_name ;;
        22) edit_string_setting git_user_email git_user_email ;;
        23) edit_boolean_setting show_titles_in_main_view show_titles_in_main_view ;;
        24) edit_integer_setting model_logs_retention_days model_logs_retention_days 1 ;;
        25) bash "$RECONFIGURATOR_DIR/prepare_token.sh" --config "$MAIN_CONFIG_FILE" ;;
        26) check_environment true ;;
        *) printf '%sNieznany numer ekranu.%s\n' "$RED" "$RESET"; return 1 ;;
    esac
}

main_reconfigurator() {
    local choice
    validate_current_configuration || broken_configuration
    while true; do
        show_main_menu
        printf '\nWybór: '
        IFS= read -r choice || return 0
        choice="$(trim "$choice")"
        [[ "$choice" == "0" ]] && return 0
        if run_selected_screen "$choice"; then
            if validate_current_configuration; then
                printf '\n%sKonfiguracja jest poprawna.%s\n' "$GREEN" "$RESET"
            else
                printf '\n%sZmiana utworzyła niepoprawną konfigurację. Sprawdź pliki ręcznie.%s\n' "$RED" "$RESET"
            fi
        fi
        pause_screen
    done
}

main_reconfigurator
