## Komendy TUI

Komendy można wpisywać cały czas w dolnym wierszu:

```text
track
track feature/ABC
track feature/ABC basic_automerge
track feature/ABC basic_automerge 15
track feature/ABC basic 15
track feature/ABC,feature/DEF ai_automerge_simple auto
track 644 basic 30
track 644 simple 30 true
644 basic 30
untrack
untrack feature/ABC
untrack feature/ABC,feature/DEF
stop
kill
resume
start
restart
reset
clear
remove_title feature/644
remove_title all
title feature/644
resolve_title 644
retitle all
ask co się dzieje z branchem feature/122?
ask jakie konflikty są w feature/844?
ask jakie modele obecnie są wykorzystywane do simple_merge?
autorepair
autorepair po pushu widok TUI nie wraca poprawnie
show feature/644
show 644
add_label feature/122 my_github_label
label 122 my_github_label
remove_label feature/122 my_github_label
remove_label 122 all
show_titles
hide_titles
nudge feature/644
rush 644
poke 644
poke all
poke labeled
poke unlabeled
continuous_nudge feature/644 60
poke_continuous 644 30
stop_continuous_nudge feature/644
poke_stop_continuous 644
clear_operations_log
remove_log claude-sonnet
clear_logs title
clear_log claude-haiku title
purge
update
update_local_branches
merge feature/122
merge 122
decrypt
activate_token jakis_tam_klucz
help
git status
com ls -la
łubudubu
exit
```

`track` bez argumentów pokazuje multiselect. Najpierw proponuje branche, dla których bieżący użytkownik ma otwarty PR; jeżeli nie można ich pobrać, pokazuje branche z remote. Bezpośrednio po nazwie każdego brancha widnieje jego aktualna grupa: `[manual]`, `[basic_automerge]`, `[ai_automerge_simple]`, `[ai_automerge_full]` albo `[untracked]`. Dopiero dalej wyświetlany jest tytuł z `branches_config.json` lub status `[resolving title]`. Brakujące tytuły są równolegle przygotowywane przez maksymalnie trzy title makery. Lista jest gotowa do wpisywania numerów natychmiast — generowanie tytułów działa w tle i nigdy nie blokuje wyboru. Można wpisać numery po przecinku albo `all`, które wybiera wszystkie widoczne pozycje. To samo działa w interaktywnym `untrack`. Po wybraniu branchy skrypt pyta osobno dla każdego o politykę, a następnie o cooldown. Ponowny `track` aktualizuje istniejącą konfigurację.

`track` jest domniemane, jeżeli pierwsze słowo wygląda jak sam numer albo zaczyna się od `default_branch_prefix`. Dlatego `feature/644 basic 30`, `644 basic 30` i `track feature/644 basic_automerge 30` są równoważne przy prefiksie `feature/`.

Opcjonalny czwarty argument `track` ustawia `merge_without_conflicts` dla brancha, np. `track 644 simple 30 true`. Domyślne `false` oznacza, że stan `[mergable]` otrzyma akcję `[ignored]` i nie zostanie automatycznie zmergeowany. Konflikty nadal są obsługiwane zgodnie z główną polityką. Ponowny `track` bez czwartego argumentu zachowuje dotychczasową subpolitykę brancha albo używa `merge_without_conflicts_default` przy pierwszym dodaniu.

Aliasy polityk:

- `basic_automerge`: `basic`, `automerge`;
- `ai_automerge_simple`: `ai_merge_simple`, `ai_simple`, `automerge_simple`, `merge_simple`, `simple`;
- `ai_automerge_all`: `ai_automerge_full`, `ai_merge_full`, `ai_full`, `automerge_full`, `merge_full`, `full`.

Komenda `help` otwiera modalną planszę dostępnych komend. Widok pozostaje otwarty do naciśnięcia klawisza.

`show BRANCH` zapisuje w sekcji operacji tytuł przechowywany dla brancha w `branches_config.json` oraz przypisane labele PR. Pobranie labeli jest funkcją **eksperymentalną** i wymaga wcześniej aktywowanego tokenu; bez niego `show` nadal pokaże tytuł i wyjaśni, że labele są niedostępne. `show_titles` włącza tytuły bezpośrednio w wierszach branchy głównego widoku, przed etykietami klasyfikacji i akcji; `hide_titles` je ukrywa. Podczas pracy title makera zamiast brakującego tytułu pojawia się animowane `[resolving title...]`, a po wyczerpaniu wszystkich fallbacków `[title resolving failed]`. Statusy te są ukryte razem z tytułami. Ustawienie jest zapisywane w `config.json`.

Przy każdym okresowym fetchu skrypt odpytuje `gh` o otwarte PR-y bieżącego użytkownika. Nowy, jeszcze nieśledzony branch trafia do jednorazowego powiadomienia z wyborem numerów lub `all`; ENTER odrzuca propozycję. Odrzucony PR nie jest proponowany ponownie, dopóki pozostaje otwarty, ale zostanie wykryty ponownie po zamknięciu i ponownym otwarciu.

Dolny wiersz działa znakowo i niezależnie od renderera statusu. `↑` oraz `↓` przechodzą po historii wpisanych komend, `←` i `→` są ignorowane, backspace usuwa znak natychmiast, a pusty ENTER wymusza pełne odtworzenie głównego widoku. Odczyt klawiszy jest próbkowany co 10 ms. Po każdym znaku — również pierwszym — renderer statusu ma 100 ms okresu ciszy, dzięki czemu wpisywanie i szybkie kasowanie nie walczy z odświeżaniem ekranu.

`stop` natychmiast kończy grupę procesu AI, ale pozwala zwykłej operacji Git lub poleceniu powłoki dojść do końca; następnie zatrzymuje automat. `kill` zatrzymuje automat i natychmiast kończy również aktualne polecenie Git/powłoki. `resume` wznawia pracę. `start` i `restart` przerywają bieżącą operację, uruchamiają od nowa worker i ponownie klasyfikują branche.

`reset` i `clear` są równoważne. Po potwierdzeniu zatrzymują automat, usuwają wszystkie lokalne refy spod `refs/automerger/*`, czyszczą tracking, kolejkę i stan runtime. Nie wykonują żadnego push, revertu ani modyfikacji remote. Tytuły w `branches_config.json` pozostają, ponieważ zarządza nimi osobna komenda `remove_title`. Po resecie automat pozostaje zatrzymany do `resume` lub `start`.

`purge` oraz `purge_local_branches` wymagają potwierdzenia i przeglądają wszystkie lokalne branche zaczynające się od `default_branch_prefix`, niezależnie od trackingu automergera. Najpierw wykonywany jest `git fetch --prune`. Branch z nadal istniejącym upstreamem pozostaje bez zmian. Przy brakującym upstreamie skrypt usuwa branch wyłącznie wtedy, gdy jego końcowy commit jest przodkiem aktualnego `<remote>/<target_branch>`; branche niezmergowane oraz aktywne w dowolnym worktree są pomijane. Usuwanie jest atomowe względem sprawdzonego SHA, każdy usunięty branch trafia do logu operacji, a końcowa plansza z podsumowaniem czeka na dowolny klawisz.

`update` oraz `update_local_branches` przechodzą po wszystkich lokalnych branchach zaczynających się od `default_branch_prefix` i dla każdego wykonują `git pull --ff-only`. Branch aktualnie otwarty w istniejącym worktree jest aktualizowany w tym worktree; pozostałe są aktualizowane w jednorazowym, prywatnym worktree, więc skrypt nie przełącza bieżącego brancha użytkownika. Błąd pobrania, brak upstreamu, lokalne zmiany lub nie-fast-forward nie zatrzymują całej operacji: dany branch jest pomijany, trafia do logu operacji oraz do końcowej planszy podsumowania.

`remove_title BRANCH` usuwa zapisany tytuł wskazanego brancha; sam numer korzysta z `default_branch_prefix`. `remove_title all` usuwa wszystkie tytuły. Przy następnym interaktywnym `track` brakujące tytuły mogą zostać wygenerowane ponownie.

`add_title`, `title`, `retitle`, `refresh_title`, `recreate_title` i `resolve_title` są równoważne. Usuwają dotychczasowy tytuł wskazanego brancha i uruchamiają jego generowanie w tle; argument `all` regeneruje tytuły dla sumy śledzonych branchy i wpisów obecnych w `branches_config.json`, o ile branch nadal istnieje na remote.

Żądania title trafiają do wspólnej, trwałej kolejki runtime, więc kolejne komendy wydane podczas pracy resolvera nie są gubione. Równolegle działają najwyżej trzy branche. Każda próba modelu respektuje `title_maker.max_working_time`; timeout kończy proces modelu, oznacza branch pomarańczowym `[!]` i planuje jedną opóźnioną próbę po 60 sekundach. Liczbę prób modelu przed fallbackiem nadal określa `title_maker.max_attempts`.

`ask PYTANIE` przekazuje pytanie do modelu z listy `ask_models`. Model otrzymuje odfiltrowany stan konfiguracji, bieżący status branchy, ostatnie operacje i tytuły branchy, a odpowiedź wyświetla się na osobnej planszy. W TUI analiza działa w tle: widok i input pozostają responsywne, a równocześnie może trwać tylko jedno pytanie `ask`. Nie dostaje tokenu GitHub i nie może zmieniać plików. To wygodna warstwa diagnostyczna dla pytań o cooldown, konflikty, ostatnie merge’e, błędy lub konfigurację modeli.

`autorepair [opis problemu]` uruchamia model z `autorepair_models` na kopii `automerger.sh`, z kontekstem ostatnich logów i zgłoszenia użytkownika. Przed każdą próbą powstaje prywatna kopia bezpieczeństwa w `backups/automerger-<data>.sh`. Model może zmieniać tylko kopię skryptu; poprawka jest stosowana dopiero po przejściu `bash -n`. Nie ma dostępu do tokenu ani do głównego pliku konfiguracyjnego. Gdy żaden fallback nie przygotuje poprawnej zmiany, oryginalny skrypt pozostaje nietknięty, a szczegóły trafiają do logów modeli.

`ask` oraz `autorepair` honorują osobne `models.<model>.ask.*` i `models.<model>.autorepair.*`. `max_working_time` ogranicza pojedynczą próbę, a `max_attempts` określa liczbę prób przed przejściem do następnego modelu z odpowiedniej listy fallbacków. Konfigurator pyta o oba limity dla każdego modelu wybranego do tych kontekstów.

`merge BRANCH` wykonuje jednorazową operację tak, jak polityka `ai_automerge_all`, niezależnie od obecnej polityki oraz subpolityki `merge_without_conflicts`. Nie zmienia wpisu w `tracked_branches`; branch `manual` pozostaje `manual`, a `ai_automerge_simple` pozostaje `ai_automerge_simple`. Wynik jest pokazywany na osobnej planszy.

`nudge BRANCH` oraz aliasy `rush BRANCH` i `poke BRANCH` tworzą w osobnym worktree commit o komunikacie identycznym z pełną nazwą brancha, np. `feature/644`, i pushują go niezależnie od `push_after_merge`. Commit jest weryfikowany przez porównanie drzewa z rodzicem i musi być absolutnie pusty. Polecenie nie używa force-pusha. Argument `all` kolejkuje nudge dla wszystkich śledzonych branchy z polityką inną niż `manual`. Eksperymentalne `poke labeled` wybiera takie branche, których PR ma przynajmniej jedną labelkę, a `poke unlabeled` — tylko PR-y bez labeli. Oba filtry wymagają aktywnego tokenu GitHub. Jeżeli istnieją lokalne commity, wynik merge w `refs/automerger/results/<branch>` albo niezacommitowane zmiany w głównym katalogu danego brancha, TUI pokazuje ostrzeżenie i wymaga potwierdzenia. Niezacommitowane pliki nigdy nie trafiają do commita; rozbieżne lub nie-fast-forward refy blokują operację.

`continuous_nudge`, `continuous_rush`, `continuous_poke` oraz warianty `nudge_continuous`, `rush_continuous`, `poke_continuous` wykonują pierwszy nudge od razu, a kolejne co podaną liczbę minut. Brak liczby otwiera pytanie interaktywne. Harmonogram jest trwały w sekcji `continuous_nudges` pliku `branches_config.json`; argument `all` obejmuje te same niemanualne branche co jednorazowy `poke all`. Zatrzymanie obsługują wszystkie układy aliasów z członami `stop`, `continuous` i `nudge`/`rush`/`poke`, np. `stop_continuous_nudge 644` lub `poke_stop_continuous 644`. Automatyczne powtórzenie wymagające potwierdzenia z powodu lokalnych zmian jest bezpiecznie pomijane i ponawiane dopiero w następnym terminie.

`clear_operations_log` i jego aliasy czyszczą wpisy operacji oraz zapisane wyniki komend we wszystkich należących do użytkownika runtime’ach `/tmp/automerger-<uid>-*`, bez usuwania trackingu i harmonogramów. `remove_log` / `remove_logs` / `clear_log` / `clear_logs` zarządzają trwałą diagnostyką modeli: argument modelu usuwa jego cały katalog, `title` usuwa logi title makerów wszystkich modeli, `MODEL title` tylko title makera danego modelu, a `all` wszystkie szczegółowe logi.
