#!/usr/bin/env bash
# Copyright (c) 2026 Andrzej Janczak
# SPDX-License-Identifier: MIT

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TOOL_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"
readonly CONFIGURATOR="$TOOL_DIR/configurator.sh"
readonly AUTOMERGER="$TOOL_DIR/automerger.sh"
readonly PROJECT_DIR="$(cd -- "$TOOL_DIR/.." && pwd -P)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/automerger-configurator-test.XXXXXX")"
FULL_BIN="$TMP_ROOT/full-bin"
MISSING_BIN="$TMP_ROOT/missing-bin"
NO_AI_BIN="$TMP_ROOT/no-ai-bin"
CONFIG="$TMP_ROOT/config.json"
CODEX_CACHE="$TMP_ROOT/models_cache.json"
OPENHANDS_HOME="$TMP_ROOT/openhands"
OUTPUT="$TMP_ROOT/output.log"
MODEL_INVOKED_MARKER="$TMP_ROOT/model-invoked"

cleanup() {
    rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equals() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" == "$expected" ]] || fail "$label: oczekiwano '$expected', otrzymano '$actual'"
    printf 'PASS: %s\n' "$label"
}

assert_contains() {
    local pattern="$1" file="$2" label="$3"
    if ! grep -Fq -- "$pattern" "$file"; then
        printf '%s\n' '--- zawartość raportu ---' >&2
        sed -n '1,240p' "$file" >&2
        fail "$label: brak tekstu '$pattern'"
    fi
    printf 'PASS: %s\n' "$label"
}

assert_not_contains() {
    local pattern="$1" file="$2" label="$3"
    if grep -Fq -- "$pattern" "$file"; then
        printf '%s\n' '--- zawartość raportu ---' >&2
        sed -n '1,240p' "$file" >&2
        fail "$label: znaleziono nieoczekiwany tekst '$pattern'"
    fi
    printf 'PASS: %s\n' "$label"
}

assert_occurrences() {
    local expected="$1" pattern="$2" file="$3" label="$4" actual
    actual="$(grep -Fc -- "$pattern" "$file" || true)"
    assert_equals "$expected" "$actual" "$label"
}

link_command() {
    local target_dir="$1" command_name="$2" command_path
    command_path="$(command -v "$command_name")" || fail "brak polecenia testowego $command_name"
    ln -s -- "$command_path" "$target_dir/$command_name"
}

prepare_fake_bins() {
    local command_name
    mkdir -p -- "$FULL_BIN" "$MISSING_BIN" "$NO_AI_BIN"
    for command_name in git jq flock timeout setsid base64 mktemp realpath sha256sum stat find stty sed cut sort sleep gh dirname chmod mv rm; do
        link_command "$FULL_BIN" "$command_name"
        [[ "$command_name" == "gh" ]] || link_command "$MISSING_BIN" "$command_name"
        link_command "$NO_AI_BIN" "$command_name"
    done
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$FULL_BIN/bwrap"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$MISSING_BIN/bwrap"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"$NO_AI_BIN/bwrap"
    printf '%s\n' '#!/bin/sh' 'printf "model nie powinien zostać uruchomiony\n" >"$MODEL_INVOKED_MARKER"; exit 99' >"$FULL_BIN/codex"
    printf '%s\n' '#!/bin/sh' \
        'if [ "${1:-}" = "--help" ]; then printf "%s\n" "--model alias: sonnet, opus, fable" "--effort <level> (low, medium, high, xhigh, max)"; exit 0; fi' \
        'printf "model nie powinien zostać uruchomiony\n" >"$MODEL_INVOKED_MARKER"; exit 99' >"$FULL_BIN/claude"
    printf '%s\n' '#!/bin/sh' 'printf "model nie powinien zostać uruchomiony\n" >"$MODEL_INVOKED_MARKER"; exit 99' >"$FULL_BIN/openhands"
    chmod 700 -- "$FULL_BIN/bwrap" "$MISSING_BIN/bwrap" "$NO_AI_BIN/bwrap" "$FULL_BIN/codex" "$FULL_BIN/claude" "$FULL_BIN/openhands"
}

prepare_fixtures() {
    mkdir -p -- "$OPENHANDS_HOME"
    cp -- "$TOOL_DIR/model-commands.json" "$TMP_ROOT/model-commands.json"
    jq --arg workdir "$PROJECT_DIR" '
        .workdir=$workdir
        | .automerge_all_models=[]
        | .automerge_simple_models=[]
        | .models={}
        | .tracked_branches={}
    ' "$TOOL_DIR/config.json" >"$CONFIG"
    printf '%s\n' '{"models":[{"slug":"gpt-test","visibility":"list","default_reasoning_level":"medium","description":"Model testowy","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}]},{"slug":"hidden","visibility":"hide"}]}' >"$CODEX_CACHE"
    printf '%s\n' '{"llm":{"model":"hosted_vllm/qwen-test","reasoning_effort":"high"}}' >"$OPENHANDS_HOME/agent_settings.json"
    printf '%s\n' '{"llm":{"model":"hosted_vllm/qwen-test"}}' >"$OPENHANDS_HOME/cli_config.json"
}

run_missing_report_confirmation_scenario() {
    local before_hash after_hash
    before_hash="$(sha256sum "$CONFIG" | cut -d' ' -f1)"
    if printf '\n\n' | env -u BASH_ENV -u ENV \
        PATH="$FULL_BIN" \
        NO_COLOR=1 \
        AUTOMERGER_CONFIGURATOR_LINE_DELAY_MS=0 \
        AUTOMERGER_CODEX_MODELS_CACHE="$CODEX_CACHE" \
        AUTOMERGER_OPENHANDS_HOME="$OPENHANDS_HOME" \
        /bin/bash --noprofile --norc "$CONFIGURATOR" --config "$CONFIG" >"$OUTPUT" 2>&1; then
        fail "brak ENTER po raporcie modeli powinien zatrzymać konfigurator"
    fi
    after_hash="$(sha256sum "$CONFIG" | cut -d' ' -f1)"
    assert_equals "$before_hash" "$after_hash" "brak potwierdzenia raportu nie zmienia konfiguracji"
}

run_success_scenario() {
    {
        printf '\n\n\n'
        printf '1,2,5\n'
        printf '3\n'
        printf '2\n'
        printf '111\n2\n222\n3\n333\n4\n444\n5\n555\n6\n'
        printf '\n45\n250\n12\n600\n2\nTASK-\ntak\nTest Automerger\ntest-automerger@example.test\ntak\n\n'
    } | env -u BASH_ENV -u ENV \
        PATH="$FULL_BIN" \
        NO_COLOR=1 \
        AUTOMERGER_CONFIGURATOR_LINE_DELAY_MS=0 \
        MODEL_INVOKED_MARKER="$MODEL_INVOKED_MARKER" \
        AUTOMERGER_CODEX_MODELS_CACHE="$CODEX_CACHE" \
        AUTOMERGER_OPENHANDS_HOME="$OPENHANDS_HOME" \
        /bin/bash --noprofile --norc "$CONFIGURATOR" --config "$CONFIG" >"$OUTPUT" 2>&1

    [[ ! -e "$MODEL_INVOKED_MARKER" ]] || fail "konfigurator uruchomił sesję modelu"
    printf 'PASS: konfigurator nie uruchamia Codex ani OpenHands i używa wyłącznie claude --help\n'
    assert_equals '["codex-gpt-test-medium","claude-sonnet","openhands-hosted_vllm-qwen-test"]' "$(jq -c '.automerge_simple_models' "$CONFIG")" "kolejność simple odpowiada kolejności wyboru"
    assert_equals '["claude-opus"]' "$(jq -c '.automerge_all_models' "$CONFIG")" "kolejność all odpowiada wyborowi"
    assert_equals '["claude-sonnet"]' "$(jq -c '.title_maker_models' "$CONFIG")" "kolejność title makerów odpowiada wyborowi"
    assert_equals '111' "$(jq -r '.models["codex-gpt-test-medium"].ai_automerge_simple.max_working_time' "$CONFIG")" "timeout Codex simple został zapisany"
    assert_equals '222' "$(jq -r '.models["claude-sonnet"].ai_automerge_simple.max_working_time' "$CONFIG")" "timeout Claude simple został zapisany"
    assert_equals '333' "$(jq -r '.models["openhands-hosted_vllm-qwen-test"].ai_automerge_simple.max_working_time' "$CONFIG")" "timeout OpenHands simple został zapisany"
    assert_equals '444' "$(jq -r '.models["claude-opus"].ai_automerge_all.max_working_time' "$CONFIG")" "timeout modelu all został zapisany"
    assert_equals '555' "$(jq -r '.models["claude-sonnet"].title_maker.max_working_time' "$CONFIG")" "timeout title makera został zapisany"
    assert_equals '2' "$(jq -r '.models["codex-gpt-test-medium"].ai_automerge_simple.max_attempts' "$CONFIG")" "liczba prób Codex simple została zapisana"
    assert_equals '3' "$(jq -r '.models["claude-sonnet"].ai_automerge_simple.max_attempts' "$CONFIG")" "liczba prób Claude simple została zapisana"
    assert_equals '4' "$(jq -r '.models["openhands-hosted_vllm-qwen-test"].ai_automerge_simple.max_attempts' "$CONFIG")" "liczba prób OpenHands simple została zapisana"
    assert_equals '5' "$(jq -r '.models["claude-opus"].ai_automerge_all.max_attempts' "$CONFIG")" "liczba prób Claude all została zapisana"
    assert_equals '6' "$(jq -r '.models["claude-sonnet"].title_maker.max_attempts' "$CONFIG")" "liczba prób title makera została zapisana"
    assert_equals '45' "$(jq -r '.fetch_interval_seconds' "$CONFIG")" "fetch_interval_seconds został zapisany"
    assert_equals '250' "$(jq -r '.ui_refresh_settings' "$CONFIG")" "ui_refresh_settings został zapisany w ms"
    assert_equals '12' "$(jq -r '.merge_cooldown_time_default' "$CONFIG")" "domyślny cooldown został zapisany"
    assert_equals '600' "$(jq -r '.model_max_working_time_default' "$CONFIG")" "domyślny timeout modeli został zapisany"
    assert_equals '2' "$(jq -r '.model_max_attempts_default' "$CONFIG")" "domyślna liczba prób została zapisana"
    assert_equals 'TASK-' "$(jq -r '.default_branch_prefix' "$CONFIG")" "domyślny prefiks brancha został zapisany"
    assert_equals 'true' "$(jq -r '.push_after_merge' "$CONFIG")" "push_after_merge został zapisany"
    assert_equals 'Test Automerger' "$(jq -r '.git_user_name' "$CONFIG")" "git_user_name został zapisany"
    assert_equals 'test-automerger@example.test' "$(jq -r '.git_user_email' "$CONFIG")" "git_user_email został zapisany"
    assert_equals 'true' "$(jq -r '.show_titles_in_main_view' "$CONFIG")" "widoczność tytułów została zapisana"
    assert_equals 'model-commands.json' "$(jq -r '.model_commands_file' "$CONFIG")" "nazwa profilu komend modeli została zapisana"
    assert_equals 'false' "$(jq 'has("model_commands") or has("model_close_commands")' "$CONFIG")" "komendy modeli nie są trzymane w config.json"
    assert_equals 'true' "$(jq -r 'has("model_commands") and has("model_close_commands")' "$TMP_ROOT/model-commands.json")" "osobny profil zawiera komendy startowe i zamykające"
    assert_contains 'Wszystkie wymagane polecenia są dostępne.' "$OUTPUT" "pełne środowisko ma jednoznaczny komunikat"
    assert_not_contains 'Niedostępne:' "$OUTPUT" "pełne środowisko nie pokazuje pustej sekcji niedostępnych poleceń"
    assert_occurrences 3 'Naciśnij ENTER, aby przejść dalej.' "$OUTPUT" "każdy raport listujący wymaga potwierdzenia"
    assert_contains 'Codex:' "$OUTPUT" "modele mają sekcję Codex"
    assert_contains 'Claude:' "$OUTPUT" "modele mają sekcję Claude"
    assert_contains 'OpenHands:' "$OUTPUT" "modele mają sekcję OpenHands"
    assert_contains '  gpt-test' "$OUTPUT" "raport pokazuje kodową nazwę modelu Codex"
    assert_contains 'effort: low, medium, high (domyślny: medium)' "$OUTPUT" "raport pokazuje wszystkie effort z cache Codex"
    assert_contains 'effort wg klienta: low, medium, high, xhigh, max' "$OUTPUT" "raport pokazuje effort deklarowane przez Claude CLI"
    assert_contains 'skonfigurowany effort: high' "$OUTPUT" "raport rozróżnia effort ustawiony w OpenHands"
    assert_not_contains 'Model testowy' "$OUTPUT" "raport nie pokazuje opisów modeli"
    assert_contains 'Modele o niewybranych numerach nie zostaną wpisane do tej listy.' "$OUTPUT" "wybór fallbacków wyjaśnia pomijanie numerów"
    assert_contains 'Przejrzyj i uzupełnij ręcznie autoresolve_files_list' "$OUTPUT" "konfigurator przypomina o ustawieniach ręcznych"
    "$AUTOMERGER" --config "$CONFIG" --validate-config >/dev/null
    printf 'PASS: wynik konfiguratora przechodzi walidację głównego skryptu\n'
}

run_missing_dependency_scenario() {
    local before_hash after_hash
    before_hash="$(sha256sum "$CONFIG" | cut -d' ' -f1)"
    if printf '\n' | env -u BASH_ENV -u ENV PATH="$MISSING_BIN" NO_COLOR=1 AUTOMERGER_CONFIGURATOR_LINE_DELAY_MS=0 /bin/bash --noprofile --norc "$CONFIGURATOR" --config "$CONFIG" >"$OUTPUT" 2>&1; then
        fail "brak gh powinien zatrzymać konfigurator"
    fi
    after_hash="$(sha256sum "$CONFIG" | cut -d' ' -f1)"
    assert_equals "$before_hash" "$after_hash" "brak zależności nie zmienia konfiguracji"
    assert_contains '✗ gh' "$OUTPUT" "raport wskazuje brakującą zależność"
    assert_contains 'muszą zostać doinstalowane ręcznie' "$OUTPUT" "raport podaje instrukcję instalacji"
}

run_no_ai_tools_scenario() {
    local before_hash after_hash
    before_hash="$(sha256sum "$CONFIG" | cut -d' ' -f1)"
    if printf '\n\n' | env -u BASH_ENV -u ENV PATH="$NO_AI_BIN" NO_COLOR=1 AUTOMERGER_CONFIGURATOR_LINE_DELAY_MS=0 /bin/bash --noprofile --norc "$CONFIGURATOR" --config "$CONFIG" >"$OUTPUT" 2>&1; then
        fail "brak wszystkich klientów AI powinien zatrzymać konfigurator"
    fi
    after_hash="$(sha256sum "$CONFIG" | cut -d' ' -f1)"
    assert_equals "$before_hash" "$after_hash" "brak wszystkich klientów AI nie zmienia konfiguracji"
    assert_contains 'Nie wykryto żadnego z narzędzi' "$OUTPUT" "raport wymaga co najmniej jednego klienta AI"
}

run_line_delay_scenario() {
    local started_at finished_at elapsed
    started_at="$(date +%s%3N)"
    NO_COLOR=1 /bin/bash --noprofile --norc "$CONFIGURATOR" --help >/dev/null 2>&1
    finished_at="$(date +%s%3N)"
    elapsed=$((finished_at - started_at))
    ((elapsed >= 60)) || fail "domyślne opóźnienie nowych linii jest krótsze niż oczekiwane 20 ms na linię: ${elapsed} ms"
    printf 'PASS: domyślne opóźnienie 20 ms jest stosowane po nowych liniach\n'
}

main() {
    prepare_fake_bins
    prepare_fixtures
    run_line_delay_scenario
    run_missing_report_confirmation_scenario
    run_success_scenario
    run_missing_dependency_scenario
    run_no_ai_tools_scenario
    printf '\nWszystkie testy konfiguratora zakończyły się powodzeniem.\n'
}

main "$@"
