## Konfiguracja

Najważniejsze pola `config.json`:

| Pole | Znaczenie |
|---|---|
| `workdir` | Bezwzględna ścieżka repozytorium, w którego kontekście działa skrypt |
| `remote` | Nazwa remote, zwykle `origin` |
| `target_branch` | Branch źródłowy wciągany do śledzonych branchy, np. `main` |
| `fetch_interval_seconds` | Częstotliwość fetch i ponownej klasyfikacji |
| `ui_refresh_ms` | Częstotliwość odświeżania TUI w milisekundach, np. `750` oznacza 750 ms |
| `merge_cooldown_time_m_default` | Domyślny cooldown w minutach. Określa po jakim czasie ten sam branch może zostać ponownie zmergeowany |
| `min_time_between_merges_m` | Globalna minimalna przerwa w minutach po udanym merge przed rozpoczęciem merge kolejnego brancha; domyślnie `5` |
| `merge_without_conflicts_default` | Domyślna zgoda na automatyczny merge brancha bez konfliktów; domyślnie `false`. Jeśli Twoje repozytorium posiada już inny mechanizm cyklicznie meregujący branche, które nie mają konfliktów - pozostaw to ustawienie na false. W przeciwnym razie automerger przyjmie rolę takiego właśnie systemu (ale uruchomionego lokalnie na maszynie użytkownika) |
| `model_max_working_time_s_default` | Timeout w sekundach używany, gdy model nie ma własnego `max_working_time` |
| `model_max_attempts_default` | Łączna liczba prób używana, gdy model nie ma własnego `max_attempts` |
| `push_after_merge` | `false`: tylko lokalny ref wyniku; `true`: push do śledzonego brancha |
| `git_user_name` / `git_user_email` | Autor i e-mail commitów merge oraz `nudge`; brak pól zachowuje wartości `Automerger` / `automerger@localhost` |
| `show_titles_in_main_view` | Trwały stan widoczności tytułów w głównym widoku |
| `github_access_token_encrypted` | Zaszyfrowany token GitHub i jawne parametry AES/KDF; `null` oznacza brak przygotowanego tokenu |
| `model_logs_retention_days` | Liczba dni przechowywania szczegółowych logów błędów modeli; domyślnie `30` |
| `default_branch_prefix` | Prefiks dopisywany, gdy branch podano jako sam numer, np. `644` → `feature/644` |
| `autoresolve_files_list` | Bezpieczne ścieżki względne wobec `workdir` lub wzorce do klasyfikacji `simple conflicts` |
| `automerge_all_models` | Kolejność modeli dla dowolnych konfliktów |
| `automerge_simple_models` | Kolejność modeli dla konfliktów wyłącznie z dozwolonej listy |
| `title_maker_models` | Kolejność fallbacków tworzących krótkie tytuły branchy w interaktywnym `track` |
| `ask_models` | Kolejność fallbacków dla diagnostycznych odpowiedzi komendy `ask` |
| `autorepair_models` | Kolejność fallbacków dla napraw `automerger.sh` wykonywanych przez `autorepair` |
| `models_config_file` | Nazwa osobnego pliku JSON z `models`, komendami startowymi i zamykającymi modeli; ścieżka względna wobec katalogu `config.json` |
| `branches_config_file` | Nazwa osobnego pliku JSON z tytułami, trackingiem i harmonogramami continuous nudge |
| `models.<nazwa>.max_working_time` | Twardy limit pracy modelu w sekundach, zapisany w `models_config.json` |
| `models.<nazwa>.max_attempts` | Łączna liczba prób modelu przed przejściem do fallbacku |
| `models.<nazwa>.ai_automerge_simple.max_working_time` / `.max_attempts` | Nadpisanie limitów tego modelu tylko dla polityki simple |
| `models.<nazwa>.ai_automerge_all.max_working_time` / `.max_attempts` | Nadpisanie limitów tego modelu tylko dla polityki all/full |
| `models.<nazwa>.title_maker.max_working_time` / `.max_attempts` | Nadpisanie limitów tego modelu tylko podczas tworzenia tytułów |
| `models.<nazwa>.ask.max_working_time` / `.max_attempts` | Opcjonalne nadpisanie limitów dla `ask` |
| `models.<nazwa>.autorepair.max_working_time` / `.max_attempts` | Opcjonalne nadpisanie limitów dla `autorepair` |
| `tracked_branches.<branch>.merge_without_conflicts` | Nadpisanie per branch w `branches_config.json`: czy automatycznie merge’ować stan `[mergable]`; brak pola używa wartości globalnej |
| `prompt_file` | Bezpieczna ścieżka względna wobec fizycznego katalogu `automerger.sh` |
| `tracked_branches` | Stan śledzenia w `branches_config.json`, zapisywany automatycznie przez `track` i `untrack` |
| `branch_info` | Rozpoznane tytuły i rozszerzalne metadane branchy w `branches_config.json` |
| `continuous_nudges` | Trwałe harmonogramy cyklicznych nudge w `branches_config.json` |

Rozpoznane tytuły są przechowywane w `branches_config.json`, razem z `tracked_branches` i `continuous_nudges`. Jeden branch oznacza jedno zadanie title makera; jednocześnie działają najwyżej trzy zadania. Każde korzysta z kolejności fallbacków z `config.json` oraz timeoutów, liczby prób, komend startowych i cleanupu zapisanych w `models_config.json`. Raz zapisany tytuł jest używany ponownie bez kolejnego wywołania modelu.

Nowe tytuły mają formę krótkiego hasła — najlepiej 2–6 słów i maksymalnie 60 znaków — zamiast pełnego zdania. Przykładowe formaty to `Cache invalidation` albo `API response types`. Starsze tytuły zapisane już w `branches_config.json` nie są automatycznie zmieniane. Daje to też możliwość ustawienia trwałego tytułu dla danego brancha ręcznie np. jeśli chcemy aby nazwa bezpośrednio odzwierciedlała taska w Jirze lub zawierała krótki zwrot, który od razu będzie nam się kojarzyć z jego zawartością. Tutuły są wyłącznie ułatwieniem w rozeznaniu się co zawiera dany branch. Pełnią jedynie funkcję informacyjną, pomocniczą dla użytkownika.

Wpisy kontekstowe mają pierwszeństwo przed ogólnymi ustawieniami modelu, a te przed `model_max_working_time_s_default` i `model_max_attempts_default`. Limity per model i per kontekst są opcjonalne. Brak timeoutu lub liczby prób używa odpowiedniej wartości domyślnej.

Modele i ich komendy nie są przechowywane w `config.json`. Plik wskazany przez `models_config_file` ma cztery obiekty: `available_models`, `models`, `model_commands` oraz `model_close_commands`. Dzięki temu cały profil modeli można kopiować między użytkownikami lub szybko podmieniać samą nazwą pliku, bez przenoszenia trackingu i pozostałych preferencji. Niepusta komenda startowa pozostaje wymagana dla każdego modelu wybranego na którejkolwiek liście; brak komendy zamykającej oznacza bezpieczny no-op połączony z usunięciem prywatnego katalogu sesji. Dostępne placeholdery:

- `{{PROMPT_FILE}}` — bezpiecznie zacytowana ścieżka bazowego promptu;
- `{{REQUEST_FILE}}` — ścieżka kompletnego promptu bieżącej próby;
- `{{PROMPT}}` — bezpiecznie zacytowana treść kompletnego promptu;
- `{{MODEL_SESSION_DIR}}` — prywatny katalog sesji konkretnej próby;
- `{{MODEL_OUTPUT_FILE}}` — plik stdout/stderr konkretnej próby modelu.

Ścieżki w `autoresolve_files_list` nigdy nie są rozumiane względem katalogu pliku `.sh`. Git zwraca ścieżki konfliktów względem katalogu głównego repozytorium wskazanego przez `workdir` i względem niego są dopasowywane wpisy. Wzorzec:

```json
"folder/inny_folder/*"
```

obejmuje całą zawartość tego poddrzewa, również pliki w dalszych podfolderach. Ścieżki absolutne, puste segmenty oraz segmenty `.` i `..` są odrzucane. Dla `prompt_file` dodatkowo rozwiązywane są symlinki; wskazanie celu poza fizycznym katalogiem skryptu jest zabronione.
