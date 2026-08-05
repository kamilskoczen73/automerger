#!/usr/bin/env bash
# Copyright (c) 2026 Andrzej Janczak
# SPDX-License-Identifier: MIT

set -uo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly TOKEN_MARKER="AUTOMERGER_GITHUB_TOKEN_V1:"
readonly TOKEN_ITERATIONS=200000
CONFIG_FILE="$SCRIPT_DIR/config.json"
temporary_config=""

usage() {
    printf 'Użycie: %s [--config PLIK]\n' "$(basename -- "$0")"
}

die() {
    printf 'BŁĄD: %s\n' "$*" >&2
    exit 1
}

cleanup_secrets() {
    token=""
    encryption_key=""
    key_confirmation=""
    plaintext=""
    encrypted=""
    unset token encryption_key key_confirmation plaintext encrypted
}

cleanup() {
    [[ -z "$temporary_config" ]] || rm -f -- "$temporary_config"
    cleanup_secrets
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

while (($# > 0)); do
    case "$1" in
        --config)
            (($# >= 2)) || die "Brak wartości dla --config."
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Nieznany argument: $1"
            ;;
    esac
done

for command_name in jq openssl mktemp realpath; do
    command -v "$command_name" >/dev/null 2>&1 || die "Brak wymaganego polecenia: $command_name"
done

CONFIG_FILE="$(realpath -e -- "$CONFIG_FILE" 2>/dev/null)" \
    || die "Plik konfiguracji nie istnieje."
[[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" && -w "$CONFIG_FILE" ]] \
    || die "Plik konfiguracji musi być zwykłym, czytelnym i zapisywalnym plikiem."
[[ ! -L "$CONFIG_FILE" ]] || die "Plik konfiguracji nie może być dowiązaniem symbolicznym."
jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || die "Plik konfiguracji nie jest poprawnym JSON-em."

printf 'Token GitHub (wejście ukryte): ' >&2
IFS= read -rs token || die "Nie udało się odczytać tokenu."
printf '\nKlucz szyfrujący (wejście ukryte): ' >&2
IFS= read -rs encryption_key || die "Nie udało się odczytać klucza."
printf '\nPowtórz klucz szyfrujący: ' >&2
IFS= read -rs key_confirmation || die "Nie udało się odczytać potwierdzenia klucza."
printf '\n' >&2

[[ -n "$token" ]] || die "Token nie może być pusty."
[[ "$token" != *[[:space:][:cntrl:]]* ]] \
    || die "Token nie może zawierać białych ani sterujących znaków."
[[ -n "$encryption_key" ]] || die "Klucz szyfrujący nie może być pusty."
[[ "$encryption_key" == "$key_confirmation" ]] || die "Podane klucze nie są identyczne."

plaintext="${TOKEN_MARKER}${token}"
encrypted="$(
    printf '%s' "$plaintext" \
        | openssl enc -aes-256-cbc -pbkdf2 -iter "$TOKEN_ITERATIONS" -md sha256 \
            -salt -a -A -pass fd:3 3< <(printf '%s' "$encryption_key")
)" || die "Szyfrowanie tokenu nie powiodło się."
[[ -n "$encrypted" ]] || die "OpenSSL zwrócił pusty ciphertext."

config_directory="$(dirname -- "$CONFIG_FILE")"
temporary_config="$(mktemp "$config_directory/.config.token.XXXXXX")" \
    || die "Nie udało się utworzyć pliku do atomowego zapisu konfiguracji."

if ! jq --arg ciphertext "$encrypted" --argjson iterations "$TOKEN_ITERATIONS" '
    .github_access_token_encrypted = {
        version:1,
        cipher:"aes-256-cbc",
        kdf:"pbkdf2",
        digest:"sha256",
        iterations:$iterations,
        ciphertext:$ciphertext
    }
' "$CONFIG_FILE" >"$temporary_config"; then
    die "Nie udało się zaktualizować dokumentu JSON."
fi

chmod --reference="$CONFIG_FILE" "$temporary_config" 2>/dev/null || chmod 600 "$temporary_config"
mv -f -- "$temporary_config" "$CONFIG_FILE" || die "Nie udało się zapisać konfiguracji."
temporary_config=""

printf 'Zaszyfrowany token zapisano w polu github_access_token_encrypted.\n'
