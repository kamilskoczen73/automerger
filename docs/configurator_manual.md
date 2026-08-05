## Interaktywny konfigurator

`configurator.sh` wymaga Bash 5+. Na początku pokazuje kolorową listę dostępnych zależności oraz sprawdza realną możliwość utworzenia przez `bwrap` unprivileged user namespace. Sekcja „Niedostępne” pojawia się tylko wtedy, gdy faktycznie czegoś brakuje; kompletne środowisko otrzymuje zielone potwierdzenie. Brak dowolnej wymaganej komendy zatrzymuje konfigurację przed zapisem i wyświetla informację o konieczności ręcznej instalacji.

Po zapisaniu ustawień modeli konfigurator wyjaśnia sposób przechowywania tokenu GitHub i uruchamia `prepare_token.sh`. Nieudane szyfrowanie nie cofa już zapisanego profilu modeli, ale kończy konfigurator błędem, aby token nie został pominięty przypadkiem. Ważne: Przygotuj token gh przed uruchomieniem konfiguratora jeśli chcesz używać funkcjonalności, które go wymagają. Bez tego automerger będzie działać poprawnie jednak jego możliwości będą limitowane.

Klienty `codex`, `claude` i `openhands` są opcjonalne pojedynczo, ale musi istnieć przynajmniej jeden. Konfigurator nie wysyła promptu i nie rozpoczyna sesji AI:

- Codex — modele widoczne na liście są odczytywane z `${CODEX_HOME:-~/.codex}/models_cache.json`; configurator pobiera poziomy reasoning effort per model, a dla znanych rodzin ma wbudowaną tabelę awaryjną;
- Claude — aliasy `sonnet`, `opus` i `fable` są uwzględniane tylko wtedy, gdy deklaruje je lokalne `claude --help`. Wartości opcji `--effort` są traktowane jako propozycja klienta, ponieważ Claude CLI nie publikuje lokalnie wiarygodnej macierzy per model. Wybrane warianty są uruchamiane z jawnym `claude --effort POZIOM`;
- OpenHands — modele oraz skonfigurowany dla nich effort są odczytywane z `~/.openhands/agent_settings.json`, `cli_config.json`, profili JSON, `LLM_MODEL` i opcjonalnego `LLM_REASONING_EFFORT`. Wybrane warianty otrzymują `LLM_REASONING_EFFORT`, ale zgodność poziomu z konkretnym backendem vLLM pozostaje odpowiedzialnością użytkownika i providera.

Po autodetekcji configurator pokazuje edytor modeli bazowych. `remove NUMER` usuwa pozycję, a `add GRUPA NAZWA` dodaje model do jednej z grup `codex-like`, `claude-like`, `openhands-vllm-like` lub `other`. ENTER zatwierdza listę. Następnie dla każdego modelu poza `other` można zaakceptować wykryte efforty albo wpisać własne po przecinku. Dla nierozpoznanego modelu podanie effortów jest obowiązkowe.

Zaakceptowany katalog trafia do `models_config.json` jako:

```json
"available_models": {
  "codex-like": {"codex-gpt-5.6-sol":["low","medium","high","xhigh","max","ultra"]},
  "claude-like": {"claude-sonnet":["low","medium","high"]},
  "openhands-vllm-like": {"openhands-hosted_vllm-qwen36-long":["high"]},
  "other": {"Qwen-3.6-local":[]}
}
```

Nazwy bazowe nie zawierają effortu. Dopiero kolejny etap rozwija je do wariantów, np. `codex-gpt-5.6-sol-high` i `claude-sonnet-high`, generuje komendy startowe i zamykające, a następnie pozwala używać tych wariantów na listach fallbacków. Modele `other` dostają kontrolowaną komendę informującą, że wymagają ręcznego skonfigurowania w `models_config.json`.

Wszystkie widoki modeli są uporządkowane według typu w stałej kolejności Codex → Claude → OpenHands → Other, a następnie według modelu bazowego; jego warianty effort pozostają obok siebie. Wybór fallbacków dla każdej polityki jest hierarchiczny: najpierw wybiera się typ, potem model, a następnie effort. Wybrany wariant staje się modelem pierwszego wyboru albo kolejnym fallbackiem. Po każdym wyborze configurator pyta, czy dodać następny model; odpowiedź negatywna kończy daną politykę i przechodzi do kolejnej.

Wykryte modele są prezentowane osobno w sekcjach Codex, Claude, OpenHands i Other, wyłącznie pod kodowymi identyfikatorami, bez opisów marketingowych. Konfigurator pyta osobno o `automerge_simple_models`, `automerge_all_models`, `title_maker_models`, `ask_models` i `autorepair_models`. Każda lista ma własną kolejność primary/fallback. Limity `max_working_time` oraz `max_attempts` mogą być ustawiane per model i kontekst. `max_attempts=2` oznacza dwie pełne próby danego modelu na czystych worktree przed przejściem do fallbacku.

Zapis jest atomowy. Konfigurator zachowuje niewymienione ustawienia i istniejące niestandardowe komendy modeli, dodając lub aktualizując wpisy wykrytych klientów. Pole `models` zawiera wyłącznie modele wybrane w `automerge_simple_models` lub `automerge_all_models`.
