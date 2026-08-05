## Tryby diagnostyczne

```bash
./automerger.sh --once
./automerger.sh --classify feature/ABC
./automerger.sh --resolve-title feature/ABC
./automerger.sh --track "feature/ABC manual auto"
./automerger.sh --untrack "feature/ABC"
```

### Szczegółowe logi modeli

Zwięzłe komunikaty pozostają w sekcji „Operacje”. Trwała diagnostyka powstaje wyłącznie po nieudanej próbie modelu. Domyślny układ to `logs/<bezpieczna-nazwa-modelu>/<DD-MM-RRRR>/`; niedozwolone znaki nazwy modelu są zastępowane przez `x`. Przykładowe artefakty to `01_22_17-title-att-2.out.log`, `01_22_17-title-att-2.req.md` oraz dzienny `errors.jsonl`. Kolizja w tej samej sekundzie otrzymuje krótki licznik zamiast PID-u lub losowej wartości.

Plik `.out.log` zaczyna się ustandaryzowanym nagłówkiem z datą, kontekstem, branchem, modelem, próbą, kategorią, kodem wyjścia i komunikatem. Dalej zawiera oczyszczony z sekwencji ANSI stdout/stderr; wyjątkowo duży output zachowuje pierwsze 300 i ostatnie 900 linii. `.req.md` przechowuje dokładny prompt, a `errors.jsonl` indeksuje oba artefakty. Przy starcie katalogi starsze niż `model_logs_retention_days` są automatycznie usuwane.

Kategorie rozróżniają między innymi `timeout`, `sandbox_unavailable`, `sandbox_start_failure`, `model_exit`, `cleanup_failure`, `invalid_model_protocol`, `invalid_title_protocol`, `validation_failure` i `security_violation`. Katalog można zmienić przez `AUTOMERGER_MODEL_LOG_DIR`; musi pozostać prywatny, ponieważ prompty i odpowiedzi mogą zawierać kod, ścieżki, nazwy branchy i inne dane repozytorium. Zawartości `logs/` nie należy dołączać do commita, archiwum źródłowego ani publicznego wydania; repozytorium ignoruje ją przez `.gitignore`.

### Dlaczego log pozostaje po ponownym uruchomieniu?

Stan TUI nie jest przechowywany w pamięci procesu. Domyślny katalog runtime ma deterministyczną nazwę `/tmp/automerger-<uid>-<sha256 config.json>`, a sekcja „Operacje” pochodzi z jego pliku `state.json`. Zwykłe `exit` zatrzymuje procesy i przywraca terminal, ale celowo nie usuwa tego katalogu, dlatego kolejna sesja z identycznym `config.json` odczytuje poprzednie wpisy. Zmiana głównego configu zmienia hash i tworzy osobny runtime; `AUTOMERGER_STATE_DIR` może wskazać jawny katalog. `reset` / `clear` czyści log operacji w aktywnym runtime.

Pliki pod `logs/<model>/<data>/` są jeszcze bardziej trwałe: znajdują się obok skryptu, niezależnie od runtime TUI, i nie są usuwane przez zwykłe wyjście ani reset trackingu. Usuwa je retencja albo rodzina komend `remove_log`. Przy pierwszym starcie stare, płaskie artefakty z `model-errors.jsonl` są automatycznie migrowane do nowego układu i otrzymują ten sam czytelny nagłówek.

## Testy

Zwykły zestaw tworzy w `/tmp` lokalny bare remote, cztery wymagane branche (`test_branch_1`, `test_branch_2`, `test_branch_3`, `test_branch_target`) oraz pomocniczy `test_branch_nested` do sprawdzenia wzorca rekurencyjnego. Nie dotyka brancha ani plików repozytorium projektu i nie wykonuje push do żadnego zewnętrznego remote.

```bash
./tests/test_automerger.sh
```

Test interaktywnego konfiguratora korzysta z kontrolowanych klientów i cache modeli; nie uruchamia żadnej sesji AI:

```bash
./tests/test_configurator.sh
```

Test rzeczywistych klientów (zużywa tokeny i wymaga dostępu do API):

```bash
./tests/test_automerger.sh --external-models
```

Tylko GPT-5.6 Terra medium przez Codex:

```bash
./tests/test_automerger.sh --gpt-only
```

Tylko Claude Sonnet:

```bash
./tests/test_automerger.sh --claude-only
```

Dowolny model skonfigurowany lokalnie w OpenHands (domyślnie `hosted_vllm/qwen36-long`):

```bash
./tests/test_automerger.sh --local-models
AUTOMERGER_LOCAL_MODEL=hosted_vllm/inny-model ./tests/test_automerger.sh --local-models
```

Ustawienie `AUTOMERGER_KEEP_TEST_TMP=1` zachowuje repozytorium testowe do diagnostyki. Zwykły zestaw bez flag nie uruchamia żadnego klienta AI. Test Codex działa w trybie `--ephemeral`, więc nie zapisuje sesji do późniejszego wznowienia.
