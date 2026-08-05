# Automerger — instrukcja użycia

`automerger.sh` stale monitoruje wybrane branche, klasyfikuje możliwość merge lokalnego snapshotu `target_branch` i — zależnie od polityki — wykonuje merge samodzielnie albo z pomocą kolejnych modeli AI. Pierwsza próba następuje od razu; cooldown zaczyna obowiązywać dopiero po udanym merge.

Automerger jest narzędziem ogólnego przeznaczenia. Nie zakłada konkretnej organizacji, hostowanego repozytorium, nazwy brancha docelowego, prefiksu branchy ani struktury kodu. Wszystkie elementy zależne od repozytorium ustawia się w konfiguracji.

## Wymagania

- Bash 5 lub nowszy;
- Git, `jq`, `flock`, `timeout`, `setsid`, `base64`, `mktemp`, `realpath`, `sha256sum`, `stat`, `find`, `stty`, `awk`, `openssl`, `sed`, `cut`, `sort` i `sleep`;
- `gh` do proponowania branchy w interaktywnym `track`, okresowego wykrywania nowych otwartych PR-ów oraz eksperymentalnych operacji na labelach;
- `bubblewrap` (`bwrap`) z dostępnymi unprivileged user namespaces — wymagany wyłącznie dla operacji AI;
- klient każdego modelu wskazanego w profilu `models_config_file`, np. `claude` albo `openhands`.

## Szybki start

1. Uruchom interaktywny konfigurator:

   ```bash
   ./configurator.sh
   ```

   Konfigurator sprawdzi środowisko, wykryje lokalne klienty i modele, pozwoli ustawić fallbacki, timeouty oraz podstawowe parametry. Inny plik można wskazać przez `--config /ścieżka/config.json` albo `AUTOMERGER_CONFIG`.

2. Przejrzyj w `config.json` co najmniej `autoresolve_files_list`, `remote`, `target_branch`, `prompt_file`, `models_config_file` i `branches_config_file`. Konfiguracja klientów znajduje się domyślnie w `models_config.json`, a trwałe dane branchy w `branches_config.json`.

Późniejsze zmiany istniejącej konfiguracji można wykonywać przez `./reconfigurator.sh`. Narzędzie najpierw waliduje komplet `config.json`, `models_config.json` i `branches_config.json`, a następnie pokazuje menu pojedynczych obszarów do edycji. W każdym ekranie aktualna wartość jest domyślna, dlatego przejście samymi ENTER-ami nie zmienia plików. Można osobno edytować katalog modeli, każdą listę fallbacków, limity konkretnego modelu, ustawienia repozytorium, czasy, merge, Git, logi, token albo uruchomić kontrolę wymaganych poleceń.

Jeżeli któregoś pliku brakuje albo konfiguracja nie przechodzi walidacji automergera, reconfigurator nie udostępnia menu. Pokazuje powód i zaleca ręczną naprawę lub ponowne utworzenie konfiguracji przez `configurator.sh`, po czym kończy działanie po ENTER.

   Po zapisaniu konfiguracji konfigurator przechodzi do obowiązkowego kroku szyfrowania tokenu GitHub i uruchamia `prepare_token.sh`. Token i klucz są odczytywane bez echa. W razie potrzeby szyfrator można uruchomić ponownie przez `./prepare_token.sh --config /ścieżka/config.json`.
3. Sprawdź konfigurację:

   ```bash
   ./automerger.sh --validate-config
   ```

4. Pozostaw `push_after_merge` jako `false` podczas pierwszych prób. Udany wynik będzie dostępny wyłącznie w lokalnym refie `refs/automerger/results/<branch>`.
5. Uruchom ciągły interfejs:

   ```bash
   ./automerger.sh
   ```

   Inny plik konfiguracji można wskazać przez `--config /ścieżka/config.json` albo zmienną `AUTOMERGER_CONFIG`.

6. Dopiero po sprawdzeniu ustawień ustaw `push_after_merge` na `true`, jeśli wyniki mają być automatycznie wysyłane do `origin`.

## Interaktywny konfigurator
[Zobacz instrukcję zawartą w: docs/configurator_manual.md]

## Konfiguracja
[Zobacz instrukcję zawartą w: docs/automerger_config_manual.md]

## Opis dostępnych komend w TUI
[Zobacz instrukcję zawartą w: docs/automerger_commands_manual.md]

## Polityki branchy

- `ai_automerge_all` — merge bezkonfliktowy wykonuje Git, a dowolne konflikty rozwiązują modele z `automerge_all_models`.
- `ai_automerge_simple` — AI dostaje wyłącznie konflikty zaklasyfikowane jako `simple conflicts`; konflikt spoza listy blokuje automerge.
- `basic_automerge` — automatyczny merge tylko bez konfliktów, bez AI.
- `manual` — wyłącznie monitoring; skrypt nigdy nie wykonuje merge tego brancha.

Pierwszy merge po `track` jest podejmowany natychmiast, o ile nie trwa jeszcze globalna przerwa po merge innego brancha. Po udanym merge cooldown brancha jest liczony od czasu tego merge i opóźnia kolejną próbę tego samego brancha wymaganą przez nową zmianę brancha roboczego albo docelowego. Wartość `auto` korzysta z `merge_cooldown_time_m_default`.

Niezależnie od cooldownu per branch, `min_time_between_merges_m` wprowadza globalny odstęp pomiędzy udanymi merge. Przy wartości `5` żaden kolejny branch nie rozpocznie merge wcześniej niż pięć minut po ostatnim sukcesie. Efektywny czas oczekiwania brancha jest późniejszą z dwóch chwil: końcem jego własnego cooldownu oraz końcem globalnej przerwy. Wartość `0` wyłącza globalną przerwę. Ustawienie odpowidniego `min_time_between_merges_m` jest istotne zwłaszcza dla projektów z pełnym CI/CD, gdzie wykonanie merge może równać się z automatycznym triggerem innych operacji np. testów, budowania środowiska, autdytu etc. Ustawienie odpowiedniej wartości w tej właściwości konfiguracji zapobiega przed przeciążeniem automatów odpowiedzialnych za takie akcje u uniemożliwia przykładowo wypushowanie 40 merge branchy w jednej chwili.

## Interfejs terminalowy

Wiersz `> ` jest przypięty do dołu terminala i aktualizowany wyłącznie podczas edycji komendy. Status ma osobny zegar odświeżania i zmienia tylko te wiersze, których treść faktycznie się zmieniła — bez cyklicznego `clear` i ponownego drukowania całego ekranu.

Strzałki poziome są ignorowane, a pionowe przeglądają historię, więc ich sekwencje sterujące nie trafiają do komendy ani nie są echoowane przez terminal. TUI utrzymuje wyłączone echo pomiędzy pojedynczymi odczytami i włącza je tylko na czas pełnych odpowiedzi interaktywnych. Wynik ręcznego `git ...`, `com ...` lub `nudge` jest przechwytywany poza rendererem i po zakończeniu pojawia się na osobnej planszy. Dowolny klawisz zamyka wynik od razu; bez interakcji plansza sama wraca do głównego widoku po 60 sekundach.

Przy dostatecznej szerokości `basic_automerge`, `ai_automerge_simple` i `ai_automerge_all` są wyświetlane w trzech kolumnach. W węższych terminalach etykiety są skracane, a gdy trzy czytelne kolumny nie mieszczą się, sekcje przechodzą do układu pionowego. Sekcja `manual` pozostaje pod nimi.

Powtarzające się bezpośrednio po sobie operacje o tym samym wyniku zajmują jeden wiersz z licznikiem, np. `git fetch --prune origin... DONE (x3)`. Widok logu pokazuje siedem ostatnich wpisów. Udane dodanie, zmiana i usunięcie trackingu również trafiają do tej sekcji.


### Ważne ostrzeżenie dotyczące `git` i `com`

Zgodnie ze specyfikacją tekst po `git` i `com` trafia do `bash -lc`, więc obsługuje `&&`, potoki, przekierowania i inne elementy składni powłoki. Te komendy mają pełne uprawnienia użytkownika uruchamiającego skrypt. Nie wklejaj do nich niezaufanej treści. Przykładowo `git reset --hard && git clean -f -d` naprawdę wykona obie destrukcyjne operacje w `workdir`.


# FAQ oraz technikalia:

## Bezpieczeństwo merge

Po każdym udanym fetchu skrypt kopiuje dokładny commit skonfigurowanego `<remote>/<target_branch>` do lokalnego, prywatnego refa `refs/automerger/target`. Klasyfikacja i późniejszy merge używają tego samego SHA. Tuż przed merge skrypt dodatkowo porównuje zapamiętane SHA brancha roboczego i brancha docelowego z bieżącymi lokalnymi refami; po zmianie któregokolwiek z nich wykonuje klasyfikację ponownie.

Każda kontrola i próba merge działa w osobnym, tymczasowym worktree. Skrypt nie przełącza brancha w głównym katalogu projektu. Przy `push_after_merge=true` zwykły push zostanie odrzucony, jeśli remote zmienił się w międzyczasie. Skrypt nie używa force push.

Commit merge otrzymuje komunikat `Automated merge of <branch> with <target_branch> by Automerger` oraz autora z `git_user_name` i `git_user_email`. Output pusha jest przechwytywany poza terminalem, więc nie narusza układu TUI; remote-tracking ref jest aktualizowany tylko wtedy, gdy push nie zrobił tego wcześniej.

### Czy skrypt przeszkadza w równoległej pracy?

Automatyczny merge nie przełącza aktualnego brancha ani nie modyfikuje plików w głównym `workdir`. Jeżeli użytkownik pracuje na `feature/001`, a skrypt aktualizuje `feature/002`, użytkownik pozostanie na `feature/001`, a push trafi jawnie do `feature/002` przez `HEAD:refs/heads/feature/002`. Merge i AI pracują w osobnym, tymczasowym worktree z własnym `HEAD` oraz indexem.

Izolacja nie jest absolutna: skrypt aktualizuje współdzielone refy `origin/*`, tworzy `refs/automerger/*`, może chwilowo konkurować z innymi operacjami Git o locki, a polecenia wpisane ręcznie przez `git ...` i `com ...` działają bezpośrednio w głównym `workdir`. Równoczesny push do tego samego brancha może zostać odrzucony jako non-fast-forward; skrypt nigdy nie używa force push.

Model AI:

- widzi merge jako `/workspace`, ale zapisuje wyłącznie do jednorazowej warstwy overlay; nie pracuje bezpośrednio w worktree Git;
- nie ma dostępu do prawdziwego `.git`, głównego `workdir`, `.automerger`, configu, skryptu, `README.md` ani testów narzędzia;
- działa w osobnej przestrzeni PID i nowej sesji bez X11, Wayland oraz D-Bus, dlatego nie widzi PID automergera, nie może wysłać mu sygnału ani uruchomić terminala w sesji użytkownika;
- ma bezwzględny `max_working_time`;
- może zmieniać wyłącznie pliki faktycznie konfliktujące w tej konkretnej próbie; sama obecność pliku w `autoresolve_files_list` nie daje prawa do zmiany pliku bez konfliktu;
- monitor overlay przerywa grupę procesu po wykryciu niedozwolonej ścieżki, zapisuje błąd o złośliwym zachowaniu i nie przenosi żadnej zmiany do właściwego worktree;
- po zakończeniu wykonywana jest ponowna kontrola całej warstwy zmian, markerów konfliktu i `git diff --check`; do worktree kopiowane są pojedynczo tylko zweryfikowane rozwiązania konfliktów;
- nie wykonuje `git add`, commita ani push — robi to skrypt po walidacji;
- po błędzie jest wycofywany, a kolejny model zaczyna od nowego, czystego worktree;
- przed przejściem do kolejnego modelu bieżący model jest ponawiany do `max_attempts` razy; każda próba również zaczyna od czystego worktree;
- po każdej próbie — także po błędzie i timeout — ma wykonywane skonfigurowane `model_close_commands`, a jego prywatny katalog sesji jest zawsze usuwany;
- po `CONFLICT_RESOLVE_NEED_ATTENTION` zatrzymuje całą automatyzację i nie uruchamia kolejnego modelu.

Jeżeli `bwrap` nie istnieje albo host blokuje wymagane namespace’y, skrypt nie uruchomi modelu bez izolacji. Operacja AI zakończy się `[FAIL]`; polityki `manual` i `basic_automerge` nie wymagają `bwrap`.

### Whitelista komend i granice ochrony

Ogólna whitelista tekstu wpisywanego przez model nie jest wiarygodną granicą bezpieczeństwa. Polecenie można uruchomić przez ścieżkę absolutną, interpreter, skrypt lub kolejny proces, a tekst odpowiedzi modelu nie mówi pewnie, co naprawdę wykonał klient. Dlatego skrypt egzekwuje rezultat przez namespace’y, mounty tylko do odczytu, overlay i kontrolę zmienionych ścieżek.

Dla Claude dodatkowo wyłączone są `Bash`, narzędzia sieciowe, notebooki i slash commands; pozostają `Read`, `Edit`, `Glob` oraz `Grep`. Codex i OpenHands nie zapewniają równoważnej, niezależnej whitelisty wszystkich podprocesów, więc ich właściwą granicą jest zewnętrzny sandbox `bwrap`. Codex używa wewnątrz niego `--sandbox danger-full-access`, ponieważ zagnieżdżony sandbox Codex wymagałby kolejnego user namespace; „pełny dostęp” dotyczy wyłącznie już odizolowanego systemu plików, nie hosta.

Ograniczenie rezydualne: klient modelu musi otrzymać własne dane uwierzytelniające i dostęp sieciowy do API. Proces modelu może potencjalnie próbować odczytać dane uwierzytelniające skopiowane do jego jednorazowego `$HOME`; całkowite odseparowanie sekretu wymagałoby osobnego brokera API/proxy. Sandbox chroni hostowe pliki przed zapisem i usuwa kopię po próbie, ale nie jest ochroną przed nieuczciwym dostawcą modelu ani exfiltracją danych, które model musi widzieć, aby rozwiązać konflikt.


### Zamykanie sesji modeli

Przykładowa konfiguracja wykorzystuje najbezpieczniejszy mechanizm dostępny w każdym kliencie:

- Codex działa przez `codex exec --ephemeral`, więc nie zapisuje plików sesji; close command to `true`, ponieważ po zakończeniu procesu nie ma sesji do usunięcia;
- Claude działa przez `claude -p --no-session-persistence`; analogicznie close command to `true`;
- OpenHands otrzymuje osobny `OPENHANDS_CONVERSATIONS_DIR={{MODEL_SESSION_DIR}}`, a close command usuwa wyłącznie ten prywatny katalog: `rm -rf -- {{MODEL_SESSION_DIR}}`.

Jeżeli close command jest skonfigurowany, skrypt uruchamia go z timeoutem 30 sekund. Niezależnie od tego dodatkowo usuwa wyłącznie katalog pasujący do prywatnego runtime bieżącej próby. Nie stosuje globalnego `pkill`, `claude project purge` ani kasowania wspólnego katalogu sesji, ponieważ mogłoby to naruszyć inne terminale.

### Walidacja i brak modeli

Skrypt zawsze waliduje konfigurację przed utworzeniem stanu runtime, fetch lub merge. Start kończy się błędem, jeśli między innymi:

- plik nie jest poprawnym JSON-em;
- brakuje wymaganego pola albo ma ono pustą wartość lub błędny typ;
- model wybrany na liście nie ma komendy startowej albo jawnie podany timeout/liczba prób ma niepoprawny typ lub wartość;
- ta sama lista fallback zawiera zduplikowany model;
- śledzony branch używa `ai_automerge_all` przy pustym `automerge_all_models` albo `ai_automerge_simple` przy pustym `automerge_simple_models`;
- `workdir`, remote, skonfigurowany branch docelowy albo `prompt_file` nie istnieją;
- `prompt_file` lub `autoresolve_files_list` próbują użyć path traversal.

Puste listy modeli są dozwolone, jeżeli wszystkie śledzone branche mają politykę `basic_automerge` lub `manual`. Komenda `track` nie pozwoli przypisać polityki AI, dopóki odpowiadająca jej lista modeli pozostaje pusta.

Jeżeli wszystkie próby wszystkich modeli fallback zakończą się błędem, timeoutem albo niepoprawnym wynikiem, skrypt wycofuje ostatnią próbę, oznacza branch `[FAIL]` i zapisuje przyczynę. Ten sam zestaw SHA brancha roboczego i docelowego nie jest automatycznie ponawiany w kolejnych cyklach, co chroni przed ponownym zużywaniem tokenów. Kontrolowaną ponowną próbę odblokowuje:

- nowa zmiana na branchu roboczym lub docelowym;
- ponowne wykonanie `track` po poprawieniu konfiguracji;
- jawne `start` lub `restart`.

Przykład OpenHands powinien działać bez interaktywnego pytania o zgodę:

```json
"qwen36-long": "OPENHANDS_SUPPRESS_BANNER=1 LLM_MODEL=hosted_vllm/qwen36-long openhands --headless --always-approve --exit-without-confirmation --override-with-envs -t {{PROMPT}}"
```


### Zaszyfrowany token GitHub

Token służy wyłącznie eksperymentalnym operacjom GitHub CLI na PR: odczytowi labeli przez `show`, filtrom `poke labeled` / `poke unlabeled` oraz komendom `add_label` / `label` i `remove_label`. Te funkcje są obecnie eksperymentalne. Bez aktywnego tokenu są świadomie blokowane; zwykłe śledzenie, merge i nudge nie używają tokenu.

Token należy utworzyć w GitHub: **Settings → Credentials → Fine-grained personal access tokens → Generate new token**. W formularzu ustaw:

- Reason: krótki opis automatycznych operacji wykonywanych na PR-ach przez Automerger
- Owner: właściciel repozytorium, w którym Automerger ma działać
- Repository access: wyłącznie wybrane repozytorium docelowe
- Permissions: **Issues — Read-Only**, **Metadata — Read-Only**, **Pull requests — Read and Write**.

Jeśli nie zarządzasz w pełni danym repozytorium, możeliwe że zanim token będzie gotowy do użycia będzie on musiał byc wpierwzaakceptowany przez administratora repozytorium/organizacji. Do czasu akceptacji nie należy oczekiwać działania funkcji labeli ani innych akcji wymagających poprawnego tokenu.

`prepare_token.sh` jest jedynym mechanizmem zapisującym token do konfiguracji; konfigurator uruchamia go jako ostatni krok. Skrypt pyta bez echa o token, klucz i powtórzenie klucza, następnie szyfruje oznakowaną wartość przez AES-256-CBC z losową solą oraz PBKDF2-HMAC-SHA256 z 200 000 iteracji. Do `github_access_token_encrypted` trafiają wyłącznie ciphertext i jawne parametry algorytmu. Atomowy plik tymczasowy konfiguracji również nigdy nie zawiera plaintextu. Szyfrowanie ogranicza ryzyko wycieku tokenu z pliku konfiguracyjnego, a osobny klucz nie jest nigdzie zapisywany.

Po uruchomieniu automergera token pozostaje nieaktywny. `decrypt` albo `activate_token` bez argumentu otwiera ukryty prompt na klucz. `activate_token KLUCZ` aktywuje go bez dodatkowego pytania, ale wpisywany argument jest widoczny na ekranie — bezpieczniejszy jest ukryty prompt. Obie komendy są wyłączone z historii `↑`/`↓` i nigdy nie zapisują klucza ani odszyfrowanego tokenu do logu operacji.

Po poprawnym odszyfrowaniu nagłówek pokazuje `[GH TOKEN ACTIVE]`. Plaintext istnieje wyłącznie w zmiennej aktywnego procesu, która jest czyszczona i usuwana przy wyjściu. Funkcje wymagające tej dodatkowej autoryzacji muszą korzystać z chronionego wywołania `run_authenticated_gh`; przed aktywacją kończy się ono błędem. Zmienna z kluczem jest czyszczona po zakończeniu komendy i nie podlega żadnej persystencji. Bash nie zapewnia kryptograficznego nadpisania zwolnionej pamięci procesu, ale żadna jawna ani tymczasowa postać sekretu nie trafia do systemu plików. Siła ochrony pliku konfiguracyjnego zależy od jakości użytego klucza.

`add_label BRANCH LABEL` (alias `label`) dodaje labelkę do PR. `remove_label BRANCH LABEL` usuwa jedną labelkę, a `remove_label BRANCH all` usuwa wszystkie obecnie przypisane. Numery branchy działają tak samo jak w pozostałych komendach, np. `label 122 my_github_label`. Wszystkie te komendy wymagają `decrypt` albo `activate_token` w bieżącej sesji i są eksperymentalne.


## Etykiety

Pierwsza etykieta opisuje klasyfikację Git: `[up to date]`, `[mergable]`, `[simple conflicts]` albo `[conflicts]`. Druga opisuje automat: `[ready]`, `[waiting: ...]`, `[queued]`, animowane `[merging...]`, `[merged]`, `[SKIPPED]`, `[FAIL]` lub `[NEED ATTENTION]`.

Po udanym lokalnym lub zdalnym merge, dopóki SHA brancha roboczego i docelowego się nie zmienią, skrypt pokazuje `[up to date] [merged]`. Po nowej zmianie klasyfikacja wraca do `[mergable]` albo konfliktu, a `[merged]` natychmiast zmienia się w standardowe `[waiting: ...]` z odliczaniem cooldownu na żywo. W chwili osiągnięcia zera stan zmienia się na `[queued]`, nigdy na `[waiting: 0s]`. Scheduler kolejki działa niezależnie od okresowego fetcha: po zwolnieniu workera natychmiast bierze następny zakolejkowany branch, a przyszłe cooldowny kontroluje co sekundę.

`[SKIPPED]` (pomarańczowe) oznacza świadome pominięcie bez próby merge: `basic_automerge` przy dowolnym konflikcie albo `ai_automerge_simple` przy konflikcie spoza `autoresolve_files_list`. `[FAIL]` jest zarezerwowane dla operacji, która faktycznie została rozpoczęta i zakończyła się błędem.

Przy `push_after_merge=false` `[merged]` oznacza poprawny lokalny wynik. Można go obejrzeć poleceniem:

```bash
git show refs/automerger/results/feature/ABC
```

# Testy, logi oraz diagnostyka:
[Zobacz instrukcję zawartą w: docs/automerger_poweruser_manual.md]


Developed and maintained by RamsSoft Andrzej Janczak usługi IT.

## Licencja

Projekt jest udostępniany na licencji MIT. Szczegóły znajdują się w pliku `LICENSE`.

