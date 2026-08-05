#!/usr/bin/env bash
# Copyright (c) 2026 Andrzej Janczak
# SPDX-License-Identifier: MIT

set -euo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SOURCE_TOOL_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/automerger-test.XXXXXX")"
TEST_TOOL_DIR="$TMP_ROOT/tool"
REMOTE_REPO="$TMP_ROOT/remote.git"
SEED_REPO="$TMP_ROOT/seed"
WORK_REPO="$TMP_ROOT/work"
CONFIG="$TEST_TOOL_DIR/config.json"
PROMPT="$TEST_TOOL_DIR/prompt.md"
AUTOMERGER="$TEST_TOOL_DIR/automerger.sh"
MODEL_COMMANDS="$TEST_TOOL_DIR/model-commands.json"
STATE_DIR="$TMP_ROOT/state"
RUN_EXTERNAL_MODELS=false
RUN_LOCAL_MODELS=false
RUN_GPT_ONLY=false
RUN_CLAUDE_ONLY=false

if [[ "${1:-}" == "--external-models" ]]; then
    RUN_EXTERNAL_MODELS=true
elif [[ "${1:-}" == "--local-models" ]]; then
    RUN_LOCAL_MODELS=true
elif [[ "${1:-}" == "--gpt-only" ]]; then
    RUN_GPT_ONLY=true
elif [[ "${1:-}" == "--claude-only" ]]; then
    RUN_CLAUDE_ONLY=true
fi

cleanup() {
    if [[ "${AUTOMERGER_KEEP_TEST_TMP:-0}" == "1" ]]; then
        printf 'Pozostawiono dane testowe: %s\n' "$TMP_ROOT" >&2
        return
    fi
    rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

report_unexpected_error() {
    local exit_code=$?
    printf 'FAIL: nieoczekiwany błąd (kod %s) w linii %s\n' "$exit_code" "${BASH_LINENO[0]:-?}" >&2
    exit "$exit_code"
}

trap report_unexpected_error ERR

assert_equals() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [[ "$actual" == "$expected" ]] || fail "$label: oczekiwano '$expected', otrzymano '$actual'"
    printf 'PASS: %s\n' "$label"
}

assert_ref_exists() {
    local ref="$1"
    local label="$2"
    git -C "$WORK_REPO" show-ref --verify --quiet "$ref" || fail "$label: brak refa $ref"
    printf 'PASS: %s\n' "$label"
}

assert_ref_missing() {
    local ref="$1"
    local label="$2"
    if git -C "$WORK_REPO" show-ref --verify --quiet "$ref"; then
        fail "$label: ref $ref nie powinien istnieć"
    fi
    printf 'PASS: %s\n' "$label"
}

write_file() {
    local path="$1"
    local content="$2"
    printf '%s\n' "$content" >"$path"
}

commit_all() {
    local message="$1"
    git -C "$SEED_REPO" add -A
    git -C "$SEED_REPO" commit -m "$message" >/dev/null
}

prepare_tool_copy() {
    mkdir -p -- "$TEST_TOOL_DIR"
    cp -- "$SOURCE_TOOL_DIR/automerger.sh" "$AUTOMERGER"
    cp -- "$SOURCE_TOOL_DIR/prompt.md" "$PROMPT"
    cp -- "$SOURCE_TOOL_DIR/model-commands.json" "$MODEL_COMMANDS"
    cp -- "$SOURCE_TOOL_DIR/model-commands.json" "$TMP_ROOT/model-commands.json"
    chmod +x -- "$AUTOMERGER"
}

create_fixture_repository() {
    git init --bare --initial-branch=test_branch_target "$REMOTE_REPO" >/dev/null
    git init --initial-branch=test_branch_target "$SEED_REPO" >/dev/null
    git -C "$SEED_REPO" config user.name "Test Automergera"
    git -C "$SEED_REPO" config user.email "automerger-test@localhost"
    write_file "$SEED_REPO/allowed.txt" $'wartość bazowa\nlinia wspólna'
    write_file "$SEED_REPO/complex.txt" $'wartość bazowa\nlinia wspólna'
    write_file "$SEED_REPO/base.txt" "plik bazowy"
    mkdir -p -- "$SEED_REPO/folder/inny_folder/deep"
    write_file "$SEED_REPO/folder/inny_folder/deep/nested.txt" $'wartość bazowa\nlinia wspólna'
    commit_all "Stan bazowy"
    local base_sha
    base_sha="$(git -C "$SEED_REPO" rev-parse HEAD)"

    git -C "$SEED_REPO" switch -c test_branch_1 "$base_sha" >/dev/null
    write_file "$SEED_REPO/branch-1.txt" "niezależna zmiana brancha 1"
    commit_all "Zmiana bez konfliktu"

    git -C "$SEED_REPO" switch -c test_branch_2 "$base_sha" >/dev/null
    write_file "$SEED_REPO/allowed.txt" $'zmiana z brancha 2\nlinia wspólna'
    commit_all "Prosty konflikt"

    git -C "$SEED_REPO" switch -c test_branch_nested "$base_sha" >/dev/null
    write_file "$SEED_REPO/folder/inny_folder/deep/nested.txt" $'zmiana z brancha zagnieżdżonego\nlinia wspólna'
    commit_all "Prosty konflikt w zagnieżdżonym pliku"

    git -C "$SEED_REPO" switch -c test_branch_3 "$base_sha" >/dev/null
    write_file "$SEED_REPO/complex.txt" $'zmiana z brancha 3\nlinia wspólna'
    commit_all "Złożony konflikt"

    git -C "$SEED_REPO" switch test_branch_target >/dev/null
    write_file "$SEED_REPO/allowed.txt" $'zmiana z target_branch\nlinia wspólna'
    write_file "$SEED_REPO/complex.txt" $'zmiana z target_branch\nlinia wspólna'
    write_file "$SEED_REPO/folder/inny_folder/deep/nested.txt" $'zmiana z target_branch\nlinia wspólna'
    write_file "$SEED_REPO/target-branch.txt" "nowa zmiana brancha docelowego"
    commit_all "Zmiany target_branch"

    git -C "$SEED_REPO" remote add origin "$REMOTE_REPO"
    git -C "$SEED_REPO" push origin \
        test_branch_target \
        test_branch_1 \
        test_branch_2 \
        test_branch_nested \
        test_branch_3 >/dev/null
    git clone "$REMOTE_REPO" "$WORK_REPO" >/dev/null
    git -C "$WORK_REPO" config user.name "Test Automergera"
    git -C "$WORK_REPO" config user.email "automerger-test@localhost"
}

create_config() {
    jq \
        --arg workdir "$WORK_REPO" \
        '.workdir=$workdir
        | .target_branch="test_branch_target"
        | .prompt_file="prompt.md"
        | .fetch_interval_seconds=1
        | .ui_refresh_settings=50
        | .merge_cooldown_time_default=0
        | .model_max_working_time_default=5
        | .model_max_attempts_default=1
        | .push_after_merge=false
        | .default_branch_prefix="test_branch_"
        | .autoresolve_files_list=["allowed.txt","folder/inny_folder/*"]
        | .automerge_all_models=[]
        | .automerge_simple_models=[]
        | .title_maker_models=[]
        | .models={}
        | .tracked_branches={}' \
        "$SOURCE_TOOL_DIR/config.json" >"$CONFIG"
    jq '.model_commands={} | .model_close_commands={}' "$MODEL_COMMANDS" >"$MODEL_COMMANDS.updated"
    mv -f -- "$MODEL_COMMANDS.updated" "$MODEL_COMMANDS"
    cp -- "$MODEL_COMMANDS" "$TMP_ROOT/model-commands.json"
}

run_tool() {
    AUTOMERGER_STATE_DIR="$STATE_DIR" "$AUTOMERGER" --config "$CONFIG" "$@"
}

update_config() {
    update_config_with_args "$1"
}

update_config_with_args() {
    local filter="$1"
    shift
    local combined="$CONFIG.combined" transformed="$CONFIG.transformed"
    local updated="$CONFIG.updated" commands_updated="$MODEL_COMMANDS.updated"
    jq -s '
        .[0] + {
            model_commands:(.[1].model_commands // {}),
            model_close_commands:(.[1].model_close_commands // {})
        }
    ' "$CONFIG" "$MODEL_COMMANDS" >"$combined"
    jq "$@" "$filter" "$combined" >"$transformed"
    jq '{model_commands:(.model_commands // {}),model_close_commands:(.model_close_commands // {})}' \
        "$transformed" >"$commands_updated"
    jq 'del(.model_commands,.model_close_commands)' "$transformed" >"$updated"
    mv -f -- "$commands_updated" "$MODEL_COMMANDS"
    mv -f -- "$updated" "$CONFIG"
    rm -f -- "$combined" "$transformed"
}

assert_invalid_config() {
    local invalid_config="$1"
    local expected_message="$2"
    local label="$3"
    local output_file="$TMP_ROOT/invalid-config-output.log"
    local invalid_state="$TMP_ROOT/invalid-state"
    if AUTOMERGER_STATE_DIR="$invalid_state" "$AUTOMERGER" --config "$invalid_config" --validate-config >"$output_file" 2>&1; then
        fail "$label: niepoprawna konfiguracja została zaakceptowana"
    fi
    grep -Fq "$expected_message" "$output_file" || fail "$label: brak oczekiwanego komunikatu '$expected_message'"
    [[ ! -e "$invalid_state" ]] || fail "$label: skrypt utworzył stan runtime mimo błędnej konfiguracji"
    printf 'PASS: %s\n' "$label"
}

test_config_validation() {
    local invalid_config="$TMP_ROOT/invalid-config.json"
    local output_file="$TMP_ROOT/track-without-models.log"
    local outside_prompt="$TMP_ROOT/outside-prompt.md"

    write_file "$invalid_config" '{"version": 1'
    assert_invalid_config "$invalid_config" "nie jest poprawnym dokumentem JSON" "uszkodzony JSON zatrzymuje start przed inicjalizacją"

    jq 'del(.workdir)' "$CONFIG" >"$invalid_config"
    assert_invalid_config "$invalid_config" "Brak wymaganego pola 'workdir'" "brak wymaganego pola zatrzymuje start"

    jq '.workdir="   "' "$CONFIG" >"$invalid_config"
    assert_invalid_config "$invalid_config" "niepoprawne albo puste wartości" "pusta wymagana wartość zatrzymuje start"

    jq '.ui_refresh_settings=0.75' "$CONFIG" >"$invalid_config"
    assert_invalid_config "$invalid_config" "niepoprawne albo puste wartości" "odświeżanie TUI wymaga dodatniej liczby całkowitej milisekund"

    jq '.prompt_file="../prompt.md"' "$CONFIG" >"$invalid_config"
    assert_invalid_config "$invalid_config" "prompt_file musi być bezpieczną ścieżką względną" "prompt_file odrzuca path traversal"

    jq --arg prompt "$PROMPT" '.prompt_file=$prompt' "$CONFIG" >"$invalid_config"
    assert_invalid_config "$invalid_config" "prompt_file musi być bezpieczną ścieżką względną" "prompt_file odrzuca ścieżkę absolutną"

    write_file "$outside_prompt" "prompt spoza katalogu narzędzia"
    ln -s -- "$outside_prompt" "$TEST_TOOL_DIR/escape-prompt.md"
    jq '.prompt_file="escape-prompt.md"' "$CONFIG" >"$invalid_config"
    assert_invalid_config "$invalid_config" "path traversal przez symlink jest zabroniony" "prompt_file odrzuca symlink wychodzący poza katalog skryptu"

    jq '.autoresolve_files_list=["../allowed.txt"]' "$CONFIG" >"$invalid_config"
    assert_invalid_config "$invalid_config" "autoresolve_files_list zawiera niedozwoloną ścieżkę" "autoresolve_files_list odrzuca path traversal"

    jq '.autoresolve_files_list=["folder/../allowed.txt"]' "$CONFIG" >"$invalid_config"
    assert_invalid_config "$invalid_config" "autoresolve_files_list zawiera niedozwoloną ścieżkę" "autoresolve_files_list odrzuca traversal w środkowym segmencie"

    jq '
        .automerge_simple_models=["model-with-defaults"]
        | .models={}
    ' "$CONFIG" >"$invalid_config"
    jq '.model_commands={"model-with-defaults":"true"} | .model_close_commands={}' \
        "$TMP_ROOT/model-commands.json" >"$TMP_ROOT/model-commands.updated"
    mv -f -- "$TMP_ROOT/model-commands.updated" "$TMP_ROOT/model-commands.json"
    AUTOMERGER_STATE_DIR="$TMP_ROOT/default-model-state" \
        "$AUTOMERGER" --config "$invalid_config" --validate-config >/dev/null
    printf 'PASS: brak ustawień modelu i close command używa wartości domyślnych\n'

    jq '.tracked_branches.test_branch_2={policy:"ai_automerge_simple",merge_cooldown_time:"auto",tracked_at:0}' "$CONFIG" >"$invalid_config"
    assert_invalid_config "$invalid_config" "automerge_simple_models jest puste" "polityka AI bez modeli zatrzymuje start"

    if run_tool --track "test_branch_2 ai_automerge_simple 0" >"$output_file" 2>&1; then
        fail "track pozwolił przypisać politykę AI bez modeli"
    fi
    grep -Fq "lista modeli jest pusta" "$output_file" || fail "track nie wyświetlił informacji o pustej liście modeli"
    assert_equals "false" "$(jq -r '.tracked_branches | has("test_branch_2")' "$CONFIG")" "odrzucony track nie modyfikuje konfiguracji"

    run_tool --validate-config >/dev/null
    printf 'PASS: brak modeli jest dozwolony dla konfiguracji bez polityk AI\n'
}

test_classification() {
    local result
    result="$(run_tool --classify test_branch_1 | tail -n1)"
    assert_equals "mergable" "$result" "branch bez konfliktów jest mergable"
    result="$(run_tool --classify test_branch_2 | tail -n1)"
    assert_equals "simple conflicts" "$result" "konflikt tylko z autoresolve_files_list jest simple conflicts"
    result="$(run_tool --classify test_branch_nested | tail -n1)"
    assert_equals "simple conflicts" "$result" "wzorzec folder/inny_folder/* obejmuje także zagnieżdżony konflikt"
    result="$(run_tool --classify test_branch_3 | tail -n1)"
    assert_equals "conflicts" "$result" "konflikt poza autoresolve_files_list jest conflicts"
}

test_tracking() {
    run_tool --track "test_branch_1 basic_automerge 5" >/dev/null
    assert_equals "basic_automerge" "$(jq -r '.tracked_branches.test_branch_1.policy' "$CONFIG")" "track zapisuje politykę"
    assert_equals "5" "$(jq -r '.tracked_branches.test_branch_1.merge_cooldown_time' "$CONFIG")" "track zapisuje cooldown"
    run_tool --track "1 basic 7" >/dev/null
    assert_equals "basic_automerge" "$(jq -r '.tracked_branches.test_branch_1.policy' "$CONFIG")" "track rozwija numer brancha i alias polityki basic"
    assert_equals "7" "$(jq -r '.tracked_branches.test_branch_1.merge_cooldown_time' "$CONFIG")" "alias track zachowuje cooldown"
    run_tool --track "test_branch_1 manual auto" >/dev/null
    assert_equals "manual" "$(jq -r '.tracked_branches.test_branch_1.policy' "$CONFIG")" "ponowny track aktualizuje politykę"
    run_tool --untrack "test_branch_1" >/dev/null
    assert_equals "false" "$(jq -r '.tracked_branches | has("test_branch_1")' "$CONFIG")" "untrack usuwa konfigurację"
}

test_tui_accepts_commands_while_refreshing() {
    local marker="$TMP_ROOT/tui-command.txt"
    local automerger_command
    command -v script >/dev/null 2>&1 || {
        printf 'SKIP: brak polecenia script do testu pseudo-terminala\n'
        return
    }
    printf -v automerger_command 'AUTOMERGER_STATE_DIR=%q %q --config %q' "$STATE_DIR" "$AUTOMERGER" "$CONFIG"
    {
        printf 'com sleep 30\n'
        for _ in {1..25}; do
            [[ "$(jq -r '.kind // ""' "$STATE_DIR/current.json" 2>/dev/null || true)" == "shell" ]] && break
            sleep 0.2
        done
        printf 'restart\n'
        printf 'com printf dziala > %s\n' "$marker"
        for _ in {1..50}; do
            [[ -e "$marker" ]] && break
            sleep 0.2
        done
        printf 'exit\n'
    } | timeout 15 script -qefc "$automerger_command" /dev/null >/dev/null
    [[ -e "$marker" ]] || fail "TUI nie wykonał zakolejkowanej komendy w ciągu 10 sekund"
    assert_equals "dziala" "$(<"$marker")" "TUI przyjmuje komendy, a restart przerywa poprzednią operację"
}

test_tui_interactive_track_aliases_and_help() {
    local automerger_command tui_output="$TMP_ROOT/tui-interactive-track.log"
    command -v script >/dev/null 2>&1 || {
        printf 'SKIP: brak polecenia script do testu interaktywnego track\n'
        return
    }
    printf -v automerger_command 'AUTOMERGER_STATE_DIR=%q %q --config %q' "$STATE_DIR" "$AUTOMERGER" "$CONFIG"
    {
        printf 'track test_branch_1\n'
        sleep 0.5
        printf '3\n'
        sleep 0.5
        printf '5\n'
        sleep 0.5
        printf 'exit\n'
    } | timeout 15 script -qefc "$automerger_command" /dev/null >"$tui_output"
    assert_equals "basic_automerge" "$(jq -r '.tracked_branches.test_branch_1.policy' "$CONFIG")" "interaktywny track zapisuje wybraną politykę"
    assert_equals "5" "$(jq -r '.tracked_branches.test_branch_1.merge_cooldown_time' "$CONFIG")" "interaktywny track pyta o cooldown po polityce"
    if grep -Fq "Niepoprawna polityka" "$tui_output"; then
        fail "interaktywny prompt został błędnie odczytany jako wartość polityki"
    fi
    printf 'PASS: tekst promptu nie trafia do wartości zwracanej przez interaktywny wybór\n'

    {
        printf '1 basic 0\n'
        sleep 0.5
        printf 'help\n'
        sleep 0.5
        printf '\n'
        sleep 0.5
        printf 'exit\n'
    } | timeout 15 script -qefc "$automerger_command" /dev/null >"$tui_output"
    assert_equals "0" "$(jq -r '.tracked_branches.test_branch_1.merge_cooldown_time' "$CONFIG")" "domniemany track obsługuje sam numer i alias polityki"
    grep -Fq "AUTOMERGER — pomoc" "$tui_output" || fail "komenda help nie wyświetliła planszy"
    printf 'PASS: help pozostaje modalny do naciśnięcia klawisza\n'
    run_tool --untrack "test_branch_1" >/dev/null
}

test_stop_and_kill_have_distinct_shell_behavior() {
    local stop_marker="$TMP_ROOT/stop-finished.txt"
    local kill_marker="$TMP_ROOT/kill-must-not-finish.txt"
    local automerger_command tui_output="$TMP_ROOT/tui-stop-kill.log"
    command -v script >/dev/null 2>&1 || {
        printf 'SKIP: brak polecenia script do testu stop/kill\n'
        return
    }
    printf -v automerger_command 'AUTOMERGER_STATE_DIR=%q %q --config %q' "$STATE_DIR" "$AUTOMERGER" "$CONFIG"
    {
        printf 'com sleep 2; printf stop-done > %q\n' "$stop_marker"
        for _ in {1..50}; do
            [[ "$(jq -r '.kind // ""' "$STATE_DIR/current.json" 2>/dev/null || true)" == "shell" ]] && break
            sleep 0.1
        done
        printf 'stop\n'
        sleep 0.3
        [[ "$(jq -r '.kind // ""' "$STATE_DIR/current.json" 2>/dev/null || true)" == "shell" ]] || exit 1
        for _ in {1..40}; do
            [[ -e "$stop_marker" ]] && break
            sleep 0.1
        done
        [[ -e "$stop_marker" && -e "$STATE_DIR/stopped" ]] || exit 1
        printf 'resume\n'
        printf 'com sleep 30; printf kill-done > %q\n' "$kill_marker"
        for _ in {1..50}; do
            [[ "$(jq -r '.kind // ""' "$STATE_DIR/current.json" 2>/dev/null || true)" == "shell" ]] && break
            sleep 0.1
        done
        printf 'kill\n'
        for _ in {1..50}; do
            [[ "$(jq -r '.kind // ""' "$STATE_DIR/current.json" 2>/dev/null || true)" != "shell" ]] && break
            sleep 0.1
        done
        printf 'resume\n'
        printf 'exit\n'
    } | timeout 15 script -qefc "$automerger_command" /dev/null >"$tui_output"
    assert_equals "stop-done" "$(<"$stop_marker")" "stop pozwala aktywnej komendzie powłoki zakończyć pracę"
    [[ ! -e "$kill_marker" ]] || fail "kill nie przerwał aktywnej komendy powłoki"
    printf 'PASS: kill przerywa aktywną komendę powłoki\n'
}

test_cooldown_and_basic_merge() {
    run_tool --track "test_branch_1 basic_automerge 5" >/dev/null
    run_tool --once >/dev/null
    assert_equals "merged" "$(jq -r '.branches.test_branch_1.action_state' "$STATE_DIR/state.json")" "pierwszy merge jest wykonywany natychmiast mimo cooldownu"
    assert_ref_exists "refs/automerger/results/test_branch_1" "push_after_merge=false zapisuje wyłącznie lokalny wynik"
    local result_sha target_branch_sha
    result_sha="$(git -C "$WORK_REPO" rev-parse refs/automerger/results/test_branch_1)"
    target_branch_sha="$(git -C "$WORK_REPO" rev-parse refs/automerger/target)"
    git -C "$WORK_REPO" merge-base --is-ancestor "$target_branch_sha" "$result_sha" || fail "wynik musi zawierać snapshot target_branch"
    printf 'PASS: wynik basic_automerge zawiera lokalny snapshot target_branch\n'

    git -C "$SEED_REPO" switch test_branch_target >/dev/null
    write_file "$SEED_REPO/target-branch-after-merge.txt" "kolejna zmiana brancha docelowego"
    commit_all "Kolejna zmiana target_branch"
    git -C "$SEED_REPO" push origin test_branch_target >/dev/null
    run_tool --once >/dev/null
    assert_equals "waiting" "$(jq -r '.branches.test_branch_1.action_state' "$STATE_DIR/state.json")" "cooldown jest liczony dopiero od udanego merge"
    run_tool --untrack "test_branch_1" >/dev/null
}

test_incompatible_policies_are_skipped() {
    run_tool --track "test_branch_2 basic 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "skipped" "$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")" "basic_automerge pomija branch z prostym konfliktem"
    assert_equals "0" "$(jq '[.logs[] | select(.label == "merge test_branch_target -> test_branch_2")] | length' "$STATE_DIR/state.json")" "pominięty basic_automerge nie rozpoczyna próby merge"
    run_tool --untrack "test_branch_2" >/dev/null

    update_config '
        .automerge_simple_models=["model-must-not-run"]
        | .models={"model-must-not-run":{"max_working_time":5}}
        | .model_commands={"model-must-not-run":"exit 91"}
        | .model_close_commands={"model-must-not-run":"true"}'
    run_tool --track "test_branch_3 simple 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "skipped" "$(jq -r '.branches.test_branch_3.action_state' "$STATE_DIR/state.json")" "ai_automerge_simple pomija konflikt spoza autoresolve listy"
    assert_equals "0" "$(jq '[.logs[] | select(.label == "model AI: model-must-not-run")] | length' "$STATE_DIR/state.json")" "pominięty ai_automerge_simple nie uruchamia modelu"
    run_tool --untrack "test_branch_3" >/dev/null
}

test_ai_fallback_and_simple_merge() {
    update_config '
        .automerge_simple_models=["model-failure","model-success"]
        | .models={
            "model-failure": {"max_working_time": 5},
            "model-success": {"max_working_time": 5}
        }
        | .model_commands={
            "model-failure": "printf \"CONFLICT_RESOLVE_FAILURE\\nNie udało się.\\n\"",
            "model-success": "printf \"wartość po bezpiecznym rozwiązaniu\\nlinia wspólna\\n\" > allowed.txt; printf \"CONFLICTS_RESOLVE_SUCCESS\\n\""
        }
        | .model_close_commands={
            "model-failure": "true",
            "model-success": "true"
        }'
    run_tool --track "test_branch_2 ai_automerge_simple 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "merged" "$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")" "ai_automerge_simple używa kolejnego modelu po błędzie"
    assert_ref_exists "refs/automerger/results/test_branch_2" "AI zapisuje lokalny wynik merge"
    assert_equals "2" "$(jq '[.logs[] | select(.label | startswith("model AI:"))] | length' "$STATE_DIR/state.json")" "fallback uruchamia modele w kolejności konfiguracji"
    run_tool --untrack "test_branch_2" >/dev/null
}

test_model_close_commands_for_all_outcomes() {
    local close_markers session_dirs
    git -C "$WORK_REPO" update-ref -d refs/automerger/results/test_branch_2 || true
    update_config '
        .automerge_simple_models=["model-close-timeout","model-close-failure","model-close-success"]
        | .models={
            "model-close-timeout":{"max_working_time":1},
            "model-close-failure":{"max_working_time":5},
            "model-close-success":{"max_working_time":5}
        }
        | .model_commands={
            "model-close-timeout":"sleep 5",
            "model-close-failure":"exit 7",
            "model-close-success":"printf \"wartość po cleanupie\\nlinia wspólna\\n\" > allowed.txt; printf \"CONFLICTS_RESOLVE_SUCCESS\\n\""
        }
        | .model_close_commands={
            "model-close-timeout":"printf closed > {{MODEL_OUTPUT_FILE}}.closed",
            "model-close-failure":"printf closed > {{MODEL_OUTPUT_FILE}}.closed",
            "model-close-success":"printf closed > {{MODEL_OUTPUT_FILE}}.closed"
        }'
    run_tool --track "test_branch_2 ai_automerge_simple 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "merged" "$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")" "fallback przechodzi przez timeout i błąd do modelu zakończonego sukcesem"
    close_markers="$(find "$STATE_DIR" -maxdepth 1 -name 'output-model-close-*.log.closed' -type f | wc -l | tr -d '[:space:]')"
    assert_equals "3" "$close_markers" "model_close_commands wykonuje się po timeout, błędzie i sukcesie"
    assert_equals "3" "$(jq '[.logs[] | select(.label | startswith("zamykanie sesji modelu AI: model-close-"))] | length' "$STATE_DIR/state.json")" "każda próba modelu ma zalogowane sprzątanie sesji"
    session_dirs="$(find "$STATE_DIR" -maxdepth 1 -name 'model-session.*' -type d | wc -l | tr -d '[:space:]')"
    assert_equals "0" "$session_dirs" "tymczasowe katalogi sesji modeli są usuwane"
    run_tool --untrack "test_branch_2" >/dev/null
}

test_ai_fallback_exhaustion_is_not_retried() {
    local before_retry after_retry failure_reason
    git -C "$WORK_REPO" update-ref -d refs/automerger/results/test_branch_2 || true
    update_config '
        .automerge_simple_models=["model-exhausted-a","model-exhausted-b"]
        | .models={
            "model-exhausted-a": {"max_working_time": 5},
            "model-exhausted-b": {"max_working_time": 5}
        }
        | .model_commands={
            "model-exhausted-a": "printf \"CONFLICT_RESOLVE_FAILURE\\nPierwszy model odmówił.\\n\"",
            "model-exhausted-b": "exit 7"
        }
        | .model_close_commands={
            "model-exhausted-a": "true",
            "model-exhausted-b": "true"
        }'
    run_tool --track "test_branch_2 ai_automerge_simple 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "fail" "$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")" "wyczerpanie fallbacku kończy się statusem FAIL"
    failure_reason="$(jq -r '.branches.test_branch_2.error' "$STATE_DIR/state.json")"
    [[ "$failure_reason" == Wyczerpano\ listę\ modeli\ fallback* ]] || fail "brak czytelnej przyczyny wyczerpania fallbacku"
    printf 'PASS: wyczerpanie fallbacku zapisuje czytelną przyczynę\n'
    before_retry="$(jq '[.logs[] | select(.label == "model AI: model-exhausted-a" or .label == "model AI: model-exhausted-b")] | length' "$STATE_DIR/state.json")"
    assert_equals "2" "$before_retry" "wszystkie modele fallback zostały użyte dokładnie raz"

    run_tool --once >/dev/null
    after_retry="$(jq '[.logs[] | select(.label == "model AI: model-exhausted-a" or .label == "model AI: model-exhausted-b")] | length' "$STATE_DIR/state.json")"
    assert_equals "$before_retry" "$after_retry" "ten sam nieudany snapshot nie zużywa ponownie tokenów"
    assert_equals "$failure_reason" "$(jq -r '.branches.test_branch_2.error' "$STATE_DIR/state.json")" "przyczyna błędu pozostaje widoczna po kolejnym cyklu"

    update_config '
        .automerge_simple_models=["model-recovery"]
        | .models={"model-recovery": {"max_working_time": 5}}
        | .model_commands={
            "model-recovery": "printf \"wartość po odzyskaniu\\nlinia wspólna\\n\" > allowed.txt; printf \"CONFLICTS_RESOLVE_SUCCESS\\n\""
        }
        | .model_close_commands={"model-recovery":"true"}'
    run_tool --track "test_branch_2 ai_automerge_simple 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "merged" "$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")" "aktualizacja konfiguracji przez track odblokowuje kontrolowaną ponowną próbę"
    run_tool --untrack "test_branch_2" >/dev/null
}

test_stop_resume_allows_retry() {
    local automerger_command tui_output="$TMP_ROOT/tui-stop-resume.log"
    command -v script >/dev/null 2>&1 || {
        printf 'SKIP: brak polecenia script do testu stop/resume AI\n'
        return
    }
    git -C "$WORK_REPO" update-ref -d refs/automerger/results/test_branch_2 || true
    update_config '
        .automerge_simple_models=["model-resumable"]
        | .models={"model-resumable": {"max_working_time": 40}}
        | .model_commands={"model-resumable": "sleep 30"}
        | .model_close_commands={"model-resumable":"true"}'
    run_tool --track "test_branch_2 ai_automerge_simple 0" >/dev/null
    printf -v automerger_command 'AUTOMERGER_STATE_DIR=%q %q --config %q' "$STATE_DIR" "$AUTOMERGER" "$CONFIG"
    {
        for _ in {1..50}; do
            [[ "$(jq -r '.kind // ""' "$STATE_DIR/current.json" 2>/dev/null || true)" == "ai" ]] && break
            sleep 0.2
        done
        [[ "$(jq -r '.kind // ""' "$STATE_DIR/current.json" 2>/dev/null || true)" == "ai" ]] || exit 1
        printf 'stop\n'
        for _ in {1..50}; do
            [[ -e "$STATE_DIR/stopped" && "$(jq -r '.branches.test_branch_2.action_state // ""' "$STATE_DIR/state.json" 2>/dev/null || true)" == "fail" ]] && break
            sleep 0.2
        done
        update_config '
            .model_commands["model-resumable"]="printf \"wartość po resume\\nlinia wspólna\\n\" > allowed.txt; printf \"CONFLICTS_RESOLVE_SUCCESS\\n\""'
        printf 'resume\n'
        for _ in {1..75}; do
            [[ "$(jq -r '.branches.test_branch_2.action_state // ""' "$STATE_DIR/state.json" 2>/dev/null || true)" == "merged" ]] && break
            sleep 0.2
        done
        printf 'exit\n'
    } | timeout 25 script -qefc "$automerger_command" /dev/null >"$tui_output"
    assert_equals "merged" "$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")" "stop/resume może ponowić ręcznie zatrzymaną próbę AI"
    assert_equals "false" "$(jq -r '.branches.test_branch_2 | has("failed_target_branch_sha")' "$STATE_DIR/state.json")" "ręczne zatrzymanie nie blokuje snapshotu jako trwały błąd"
    run_tool --untrack "test_branch_2" >/dev/null
}

test_ai_rejects_out_of_scope_change() {
    update_config '
        .automerge_all_models=["model-out-of-scope"]
        | .automerge_simple_models=[]
        | .models={"model-out-of-scope": {"max_working_time": 5}}
        | .model_commands={
            "model-out-of-scope": "printf \"rozwiązany konflikt\\nlinia wspólna\\n\" > complex.txt; rm -f base.txt; printf \"CONFLICTS_RESOLVE_SUCCESS\\n\""
        }
        | .model_close_commands={"model-out-of-scope":"true"}'
    run_tool --track "test_branch_3 ai_automerge_all 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "fail" "$(jq -r '.branches.test_branch_3.action_state' "$STATE_DIR/state.json")" "zmiana AI poza listą konfliktów kończy operację błędem"
    assert_ref_missing "refs/automerger/results/test_branch_3" "odrzucona próba AI nie zapisuje wyniku"
    assert_equals "plik bazowy" "$(<"$WORK_REPO/base.txt")" "rollback nie zmienia głównego worktree"
    run_tool --untrack "test_branch_3" >/dev/null
}

test_ai_cannot_read_protected_files_or_signal_host() {
    local host_pid="$$" protected_canary="AUTOMERGER_SECRET_CANARY_7319"
    git -C "$WORK_REPO" update-ref -d refs/automerger/results/test_branch_2 || true
    update_config_with_args '
        .security_test_canary=$canary
        | .automerge_all_models=[]
        | .automerge_simple_models=["model-isolated"]
        | .models={"model-isolated":{"max_working_time":10}}
        | .model_commands={
            "model-isolated": (
                "if cat .git >/dev/null 2>&1 || cat .automerger/config.json >/dev/null 2>&1 || cat "
                + ($host_config | @sh)
                + " >/dev/null 2>&1 || kill -0 " + $host_pid + " >/dev/null 2>&1; then exit 91; fi; "
                + "setsid sh -c " + (("kill -TERM " + $host_pid) | @sh) + " >/dev/null 2>&1 || true; "
                + "printf \"wartość po izolacji\\nlinia wspólna\\n\" > allowed.txt; printf \"CONFLICTS_RESOLVE_SUCCESS\\n\""
            )
        }
        | .model_close_commands={"model-isolated":"true"}
    ' --arg host_pid "$host_pid" --arg host_config "$CONFIG" --arg canary "$protected_canary"
    run_tool --track "test_branch_2 ai_automerge_simple 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "merged" "$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")" "AI nie odczytuje .git, plików narzędzia ani ścieżki hosta"
    kill -0 "$host_pid" 2>/dev/null || fail "proces testowy został zasygnalizowany z sandboxa AI"
    printf 'PASS: osobna przestrzeń PID chroni proces i terminal automergera\n'
    run_tool --untrack "test_branch_2" >/dev/null
}

test_simple_ai_rejects_allowed_but_nonconflicting_file() {
    git -C "$WORK_REPO" update-ref -d refs/automerger/results/test_branch_2 || true
    update_config '
        .autoresolve_files_list=["allowed.txt","base.txt"]
        | .automerge_all_models=[]
        | .automerge_simple_models=["model-malicious-simple"]
        | .models={"model-malicious-simple":{"max_working_time":10}}
        | .model_commands={
            "model-malicious-simple":"printf \"niedozwolona zmiana\\n\" > base.txt; printf \"rozwiązanie\\nlinia wspólna\\n\" > allowed.txt; printf \"CONFLICTS_RESOLVE_SUCCESS\\n\""
        }
        | .model_close_commands={"model-malicious-simple":"true"}'
    run_tool --track "test_branch_2 ai_automerge_simple 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "fail" "$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")" "simple odrzuca zmianę dozwolonego pliku, który nie konfliktował"
    [[ "$(jq -r '.branches.test_branch_2.error' "$STATE_DIR/state.json")" == Wykryto\ złośliwe\ zachowanie* ]] \
        || fail "brak jednoznacznej informacji o złośliwym zachowaniu AI"
    printf 'PASS: naruszenie zakresu zapisuje informację o złośliwym zachowaniu\n'
    assert_ref_missing "refs/automerger/results/test_branch_2" "złośliwa próba simple nie zapisuje wyniku"
    assert_equals "plik bazowy" "$(<"$WORK_REPO/base.txt")" "złośliwa zmiana nigdy nie trafia do głównego worktree"
    run_tool --untrack "test_branch_2" >/dev/null
}

test_ai_need_attention_stops_fallback() {
    update_config '
        .automerge_all_models=["model-attention","model-must-not-run"]
        | .automerge_simple_models=[]
        | .models={
            "model-attention": {"max_working_time": 5},
            "model-must-not-run": {"max_working_time": 5}
        }
        | .model_commands={
            "model-attention": "printf \"CONFLICT_RESOLVE_NEED_ATTENTION\\nPotrzebna jest decyzja człowieka.\\n\"",
            "model-must-not-run": "printf \"CONFLICTS_RESOLVE_SUCCESS\\n\""
        }
        | .model_close_commands={
            "model-attention":"true",
            "model-must-not-run":"true"
        }'
    run_tool --track "test_branch_3 ai_automerge_all 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "attention" "$(jq -r '.branches.test_branch_3.action_state' "$STATE_DIR/state.json")" "NEED_ATTENTION zatrzymuje automatyzację"
    [[ -e "$STATE_DIR/stopped" ]] || fail "NEED_ATTENTION powinien utworzyć stan stopped"
    printf 'PASS: NEED_ATTENTION zapisuje stan stopped\n'
    assert_equals "0" "$(jq '[.logs[] | select(.label == "model AI: model-must-not-run")] | length' "$STATE_DIR/state.json")" "po NEED_ATTENTION nie jest uruchamiany kolejny model"
    rm -f -- "$STATE_DIR/stopped"
    run_tool --untrack "test_branch_3" >/dev/null
}

test_real_claude_model() {
    command -v claude >/dev/null 2>&1 || fail "brak klienta Claude"
    git -C "$WORK_REPO" update-ref -d refs/automerger/results/test_branch_2 || true
    update_config '
        .automerge_all_models=[]
        | .automerge_simple_models=["claude-sonnet"]
        | .models={"claude-sonnet": {"max_working_time": 180}}
        | .model_commands={
            "claude-sonnet": "claude --model sonnet --permission-mode acceptEdits --no-session-persistence --disable-slash-commands --tools \"Read,Edit,Glob,Grep\" --disallowedTools \"Bash,WebFetch,WebSearch,NotebookEdit\" --append-system-prompt \"$(cat {{PROMPT_FILE}})\" -p {{PROMPT}}"
        }
        | .model_close_commands={"claude-sonnet":"true"}'
    run_tool --track "test_branch_2 ai_automerge_simple 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "merged" "$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")" "Claude rozwiązuje prosty konflikt"
    assert_ref_exists "refs/automerger/results/test_branch_2" "wynik Claude pozostaje lokalny"
    run_tool --untrack "test_branch_2" >/dev/null
}

test_real_gpt_model() {
    local action_state output_file
    command -v codex >/dev/null 2>&1 || fail "brak klienta Codex"
    git -C "$WORK_REPO" update-ref -d refs/automerger/results/test_branch_2 || true
    update_config '
        .automerge_all_models=[]
        | .automerge_simple_models=["gpt-5.6-terra-medium"]
        | .models={"gpt-5.6-terra-medium":{"max_working_time":600}}
        | .model_commands={
            "gpt-5.6-terra-medium":"codex exec --model gpt-5.6-terra --config '\''model_reasoning_effort=\"medium\"'\'' --config '\''approval_policy=\"never\"'\'' --sandbox danger-full-access --ephemeral {{PROMPT}}"
        }
        | .model_close_commands={"gpt-5.6-terra-medium":"true"}'
    run_tool --track "test_branch_2 ai_automerge_simple 0" >/dev/null
    run_tool --once >/dev/null
    action_state="$(jq -r '.branches.test_branch_2.action_state' "$STATE_DIR/state.json")"
    if [[ "$action_state" != "merged" ]]; then
        for output_file in "$STATE_DIR"/output-gpt-5.6-terra-medium-*.log; do
            [[ -f "$output_file" ]] || continue
            printf '\n--- Diagnostyka Codex: %s ---\n' "$output_file" >&2
            tail -n 80 -- "$output_file" >&2
        done
    fi
    assert_equals "merged" "$action_state" "GPT-5.6 Terra medium rozwiązuje prosty konflikt"
    assert_ref_exists "refs/automerger/results/test_branch_2" "wynik GPT pozostaje lokalny"
    assert_equals "DONE" "$(jq -r '[.logs[] | select(.label == "zamykanie sesji modelu AI: gpt-5.6-terra-medium")][-1].status' "$STATE_DIR/state.json")" "efemeryczna sesja Codex przechodzi cleanup"
    run_tool --untrack "test_branch_2" >/dev/null
}

test_real_local_model() {
    local local_model="${AUTOMERGER_LOCAL_MODEL:-hosted_vllm/qwen36-long}"
    command -v openhands >/dev/null 2>&1 || fail "brak klienta OpenHands dla modelu lokalnego"
    git -C "$WORK_REPO" update-ref -d refs/automerger/results/test_branch_3 || true
    update_config_with_args '
        .automerge_all_models=["openhands-local"]
        | .automerge_simple_models=[]
        | .models={"openhands-local": {"max_working_time": 240}}
        | .model_commands={
            "openhands-local": ("OPENHANDS_SUPPRESS_BANNER=1 OPENHANDS_CONVERSATIONS_DIR={{MODEL_SESSION_DIR}} LLM_MODEL=" + ($local_model | @sh) + " openhands --headless --always-approve --exit-without-confirmation --override-with-envs -t {{PROMPT}}")
        }
        | .model_close_commands={"openhands-local":"rm -rf -- {{MODEL_SESSION_DIR}}"}
    ' --arg local_model "$local_model"
    run_tool --track "test_branch_3 ai_automerge_all 0" >/dev/null
    run_tool --once >/dev/null
    assert_equals "merged" "$(jq -r '.branches.test_branch_3.action_state' "$STATE_DIR/state.json")" "lokalny model OpenHands rozwiązuje konflikt w trybie ai_automerge_all"
    assert_ref_exists "refs/automerger/results/test_branch_3" "wynik lokalnego modelu pozostaje lokalny"
    run_tool --untrack "test_branch_3" >/dev/null
}

main() {
    prepare_tool_copy
    create_fixture_repository
    create_config
    run_tool --validate-config >/dev/null
    if [[ "$RUN_LOCAL_MODELS" == "true" ]]; then
        test_real_local_model
        printf '\nTest modelu lokalnego skonfigurowanego w OpenHands zakończył się powodzeniem.\n'
        return
    fi
    if [[ "$RUN_GPT_ONLY" == "true" ]]; then
        test_real_gpt_model
        printf '\nTest rzeczywistego modelu GPT przez Codex zakończył się powodzeniem.\n'
        return
    fi
    if [[ "$RUN_CLAUDE_ONLY" == "true" ]]; then
        test_real_claude_model
        printf '\nTest rzeczywistego modelu Claude zakończył się powodzeniem.\n'
        return
    fi
    test_config_validation
    test_classification
    test_tracking
    test_tui_interactive_track_aliases_and_help
    test_tui_accepts_commands_while_refreshing
    test_stop_and_kill_have_distinct_shell_behavior
    test_cooldown_and_basic_merge
    test_incompatible_policies_are_skipped
    test_ai_fallback_and_simple_merge
    test_model_close_commands_for_all_outcomes
    test_ai_fallback_exhaustion_is_not_retried
    test_stop_resume_allows_retry
    test_ai_rejects_out_of_scope_change
    test_ai_cannot_read_protected_files_or_signal_host
    test_simple_ai_rejects_allowed_but_nonconflicting_file
    test_ai_need_attention_stops_fallback
    if [[ "$RUN_EXTERNAL_MODELS" == "true" ]]; then
        test_real_gpt_model
        test_real_claude_model
        test_real_local_model
    fi
    printf '\nWszystkie testy integracyjne zakończyły się powodzeniem.\n'
}

main "$@"
