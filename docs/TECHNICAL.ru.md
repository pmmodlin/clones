<p align="right"><a href="TECHNICAL.md">English</a> · <b>Русский</b></p>

# clones: техническое описание

Для пользователей — [README](../README.ru.md). Почему выбран такой механизм — [RESEARCH.md](RESEARCH.md).

## Как это устроено

Профиль — отдельная userData-папка Electron. clones запускает Claude с флагом
`--user-data-dir=<папка профиля>`; Claude хранит там cookies (вход), Local Storage, IndexedDB,
кэш, настройки и `claude_desktop_config.json`. `app.asar` не патчится, подпись Anthropic не меняется.

Профиль `default` — обычный Claude без флагов (`~/Library/Application Support/Claude`).
Его можно запускать, закрывать и сделать для него лаунчер, но нельзя удалить или переименовать.

Из каждого профиля получаются три вещи:

| Что | Где | Зачем |
|---|---|---|
| Данные | `~/.clones/<name>/` | userData: вход, чаты, настройки, кэш, MCP-конфиг; внутри `claude-code/` — папка Claude Code профиля |
| Лаунчер | `/Applications/Claude <Name>.app` | Крошечный бандл со скриптом `clones run <name>`; значок с цветной плашкой. Для Dock, Spotlight, Raycast |
| Копия Claude.app | `~/.clones/.bundles.noindex/<name>/Claude <Name>.app` | Чтобы запущенный профиль в Dock и ⌘Tab назывался «Claude <Name>» |

### Копии Claude.app

Dock и ⌘Tab показывают имя и значок бандла, которым запущен процесс, поэтому профиль запускается
своей копией Claude.app.

- Копия побайтовая: `Info.plist`, бинарники и ресурсы не меняются, а имя папки `.app` в подпись не
  входит. Подпись и restricted entitlements остаются действительными, Keychain работает как у оригинала.
  После копирования clones проверяет `codesign --verify` и удаляет копию при ошибке.
- На APFS копия делается через `clonefile` — мгновенно и почти без расхода места до первого обновления.
- Значок с плашкой ставится на копию через `NSWorkspace.setIcon` и остаётся, только если
  `codesign --verify` после этого проходит.
- `.noindex` в пути прячет копии от Spotlight.
- Копия обновляется Squirrel'ом сама, независимо от оригинала, и после обновления занимает свои ~500 МБ.
  `clones doctor` видит расхождение версий; `clones update` и `clones app <name>` пересоздают копии.
- `--no-copy` (у `add` и `app`) — запускать профиль оригинальным Claude.app.

### Фоновый страж (`clones agent`)

Копию, закреплённую в Dock (или открытую из Finder), macOS запускает **без аргументов**, и без
`--user-data-dir` она работала бы на данных `default`. Страж — LaunchAgent `dev.clones.agent`
(`~/Library/LaunchAgents/dev.clones.agent.plist`, процесс `clones agent run`):

- реагирует на `NSWorkspace.didLaunchApplicationNotification` для bundle id Claude и раз в 2 с
  на всякий случай опрашивает процессы;
- копию профиля без `--user-data-dir` убивает SIGKILL (пока Electron почти ничего не записал)
  и запускает профиль правильно, или фокусирует его, если он уже запущен;
- ставится автоматически при создании первой копии; лог — `~/Library/Logs/clones-agent.log`.

`clones agent` / `agent status` / `agent install` / `agent uninstall`.

### Процессы

Главный процесс Claude определяется по пути исполняемого файла (оригинал или копия с тем же
bundle id); argv читается через `sysctl(KERN_PROCARGS2)`, а не `ps`, — пути с пробелами
(«Application Support») не склеиваются. Принадлежность профилю — по `--user-data-dir`
(пути сравниваются после раскрытия симлинков); без флага — `default`.

У Claude нет single-instance lock, поэтому два процесса на одной папке оба запустятся и испортят
данные. `clones run` сначала ищет запущенный процесс профиля и фокусирует его (Apple Event
«reopen» + `NSRunningApplication.activate`); `ls`/`doctor` показывают `CONFLICT`.

Запуск — `NSWorkspace.openApplication` с `createsNewApplicationInstance` (запасной путь — `open -n`):
без нового инстанса LaunchServices просто активировал бы любой запущенный Claude с тем же bundle id.

Закрытие (`kill`) — по нарастающей: Apple Event «quit» (как ⌘Q) → SIGTERM → SIGKILL только с `--force`.

## Команды и флаги

| Команда | Описание |
|---|---|
| `add <name> [--color <hex>] [--icon <path>] [--title <s>] [--clone-mcp-from <p>] [--no-isolate-claude-code] [--no-app] [--no-copy]` | Профиль, лаунчер и копия Claude. `--clone-mcp-from` копирует только `mcpServers`. По умолчанию профиль получает свой `CLAUDE_CONFIG_DIR` (`<профиль>/claude-code`) для вкладки Code; `--no-isolate-claude-code` — общий `~/.claude`. Имя: латиница, цифры, `-`, `_`, `.`; до 32 символов |
| `ls [--json] [--no-size]` | Статус, PID, размер, число MCP-серверов, лаунчер. В `--json` ещё `bundleCopy`, `bundleVersion`, `unmanaged`. Цвета — только в терминале; `NO_COLOR` отключает |
| `run <name>` | Запустить профиль или показать окно запущенного |
| `login <name> [-y] [--no-restore]` | Закрыть остальные инстансы, запустить нужный единственным, после Enter вернуть остальные |
| `kill <name> \| --all [--force] [--timeout s]` | Закрыть (по умолчанию ждёт 15 с) |
| `rm <name> [-f]` | Удалить профиль, данные, лаунчер и копию; без `-f` спрашивает подтверждение и не трогает запущенный |
| `rename <old> <new>` | Переименовать; лаунчер и копия пересоздаются |
| `dir <name>` | Путь к данным профиля |
| `config <name> [--path]` | `claude_desktop_config.json` в `$VISUAL`/`$EDITOR` (иначе TextEdit) + проверка JSON |
| `app <name> \| --all [--color] [--icon] [--title] [--no-copy] [--remove] [-f]` | (Пере)создать лаунчер и копию. `--all` включает `default`, только если у него уже есть лаунчер. `--remove` — убрать лаунчер и копию, профиль остаётся |
| `install [-f] [--dir <path>]`, алиас `update` | Скачать и установить/обновить Claude Desktop (см. ниже) |
| `agent [status\|install\|uninstall]` | Фоновый страж копий |
| `doctor` | Диагностика |
| `completion zsh\|bash\|fish` | Автодополнение (имена профилей тоже дополняются) |

### `clones install`

- Список версий: `https://downloads.claude.ai/releases/darwin/universal/RELEASES.json` (тот же источник,
  что у Homebrew-cask `claude`). Ссылка на архив принимается только `https` на `claude.ai`/`anthropic.com`.
- Архив скачивается `curl`, распаковывается `ditto`.
- Перед установкой: `codesign --verify --deep --strict`, Team ID `Q6L2SF6YDW` и bundle id
  `com.anthropic.claudefordesktop` в подписи, `spctl --assess` (нотаризация). Любая ошибка — отказ.
- Старый Claude.app возвращается на место, если замена не удалась.
- Все инстансы должны быть закрыты. После установки копии закрытых профилей пересоздаются; если версия
  уже последняя, пересоздаются только отставшие копии.

## Файлы

| Путь | Что |
|---|---|
| `~/.clones/<name>/` | userData профиля |
| `~/.clones/<name>/claude-code/` | папка Claude Code профиля (`CLAUDE_CONFIG_DIR`) |
| `~/.clones/.bundles.noindex/<name>/` | копия Claude.app |
| `~/.clones/.icons/` | копии картинок из `--icon` |
| `~/.clones/.config.json` | метаданные: цвет, иконка, имя лаунчера, `env` профиля, `claudeApp` |
| `/Applications/Claude <Name>.app` | лаунчеры (bundle id `dev.clones.launcher.<name>`, ключ `ClonesProfile` в Info.plist). Старые лаунчеры из `~/Applications` тоже находятся и переносятся |
| `~/Library/LaunchAgents/dev.clones.agent.plist`, `~/Library/Logs/clones-agent.log` | страж копий |

Служебные имена с точкой не пересекаются с профилями: имя профиля начинается с буквы или цифры.
Ранние сборки для разработки хранили данные в `~/Library/Application Support/clones`, а метаданные в `~/.config/clones`;
первый запуск при закрытых Claude переносит всё в `~/.clones` и правит пути в метаданных
(`LayoutMigration`). Пока какой-то инстанс открыт, работает со старым местом и сообщает об этом.

Переменные окружения: `CLONES_CLAUDE_APP` (путь к Claude.app), `CLONES_HOME` (вместо `~/.clones`),
`CLONES_APPS_DIR` (куда класть лаунчеры), `CLONES_DEFAULT_USER_DATA`, `CLONES_LANG` (`en`/`ru`).
Поле `env` профиля в `config.json` — переменные для процесса Claude (так работает изоляция Claude Code). На CLI `claude` в терминале это не влияет: чтобы он работал с папкой профиля, запускайте `CLAUDE_CONFIG_DIR="<профиль>/claude-code" claude`.

## Ограничения

- **`claude://`.** У всех инстансов один bundle id, поэтому deep link macOS отдаёт любому из них.
  Обычный вход и SSO идут через `ASWebAuthenticationSession` и возвращаются в нужный процесс;
  вход через Google, ссылки из писем, OAuth MCP-коннекторов и «Открыть в приложении» — через `claude://`.
  Если ссылка входа попадёт в чужой инстанс, он покажет код для входа, а нужный профиль не войдёт. Отсюда `clones login`.
- **Не изолируется:** `~/Library/Logs/Claude`; `~/.claude` у обычного Claude, CLI в терминале и профилей с `--no-isolate-claude-code`;
  `~/Documents/Claude` и `~/Claude Projects` (Cowork/Code); ключ Keychain «Claude Safe Storage» (общий,
  безопасно); `com.anthropic.claudefordesktop.plist`.
- **Claude in Chrome.** При userData вне стандартного места Claude сам отключает локальное сопряжение
  (`userData relocated`) — работает только в `default`.
- **Автообновление из профиля** перезапускает приложение без флагов; копию так перезапущенного профиля
  страж вернёт в нужный профиль, оригинальный Claude.app откроется как `default`.
- **Один аккаунт — один профиль:** аппаратный ключ устройства привязан к аккаунту.
- **Claude.app напрямую**, пока работают профили, активирует произвольный запущенный инстанс.
  Поэтому первый `clones add` создаёт и «Claude Default» (лаунчер и копию для `default`);
  `clones app default --remove` убирает его, и последующие `add`/`app --all` его не возвращают.
- MCP-конфиг Claude читает при старте — после `clones config` перезапустите профиль.

## Разработка

```
Sources/ClonesCore/   профили, процессы (sysctl), запуск (NSWorkspace), лаунчеры и иконки,
                      копии Claude.app, страж, установка Claude
Sources/clones/       команды CLI (swift-argument-parser)
Tests/                юнит-тесты
scripts/e2e.sh        сквозной сценарий; scripts/fake-claude — заглушка Claude.app
Formula/clones.rb     формула Homebrew (заполнить url/sha256 после релиза)
.github/workflows/    ci.yml (macOS + Linux), release.yml (тег v* → универсальный бинарник в GitHub Release)
```

```sh
make build          # релизная сборка под текущую архитектуру
make universal      # arm64 + x86_64 (нужен Xcode)
make install        # ~/.local/bin; PREFIX=/usr/local для /usr/local/bin
make uninstall
make test           # юнит-тесты (с одними Command Line Tools XCTest может быть недоступен)
make e2e            # сквозной сценарий на заглушке Claude
CLONES_E2E_REAL=1 make e2e   # то же на настоящем /Applications/Claude.app
```

`e2e.sh` работает во временной папке (`CLONES_*_DIR`). Создаёт профили, одновременно запускает
`default`, `work` и `test`, через `ps`/`lsof` проверяет три процесса с тремя разными userData,
проверяет изоляцию MCP-конфига, `kill`, `rm`, `app`, `rename`, копии, страж и `doctor`.
Заглушка (`scripts/fake-claude/fake-claude.c`) ведёт себя как Electron по отношению к
`--user-data-dir` и без флага пишет в песочницу, а не в настоящий `~/Library/Application Support/Claude`.
В режиме `CLONES_E2E_REAL=1` ваш обычный Claude будет запущен и в конце закрыт.

Язык интерфейса: английский, русский — если язык системы русский (`Locale.preferredLanguages`,
на Linux — `LC_ALL`/`LC_MESSAGES`/`LANG`). Явно: `CLONES_LANG=en|ru`. Строки задаются парами
`tr("English", "Русский")` (`Sources/ClonesCore/L10n.swift`). Картинки терминала для README рисует
`scripts/render-terminal.py`.

Ядро собирается и на Linux: macOS-специфика закрыта `#if os(macOS)`, чтобы гонять тесты и e2e без Mac.
CI (`.github/workflows/ci.yml`, на pull request и по кнопке): macOS (universal-сборка, тесты, e2e) и Linux. Релизы проверяет сам `release.yml`.

### Релизы

Поднимите `Clones.version` в `Sources/clones/Clones.swift`, добавьте раздел в `CHANGELOG.md`, затем
`git tag v0.2.0 && git push origin v0.2.0`. `release.yml` проверит, что тег совпадает с версией,
прогонит тесты и e2e на macOS, соберёт универсальный бинарник (ad-hoc подпись) и опубликует
`clones-macos.tar.gz` с SHA-256 в GitHub Release.

### Чек-лист ручной проверки

- [ ] `clones doctor`: Claude.app найден, ошибок ✗ нет, страж запущен.
- [ ] `clones add work && clones add test`: в /Applications «Claude Work» и «Claude Test» с плашками, Spotlight их находит.
- [ ] `clones login work`, `clones login test`: вход в разные аккаунты; после Enter остальные профили вернулись.
- [ ] `clones run default`, `run work`, `run test`: в каждом окне свой аккаунт и свои чаты; в Dock — «Claude Work», «Claude Test».
- [ ] `clones ls`: три `running`, разные PID, нет `CONFLICT`.
- [ ] `clones config work` + перезапуск: MCP-сервер есть только у `work`.
- [ ] Закрыть окна `work` (⌘W) и `clones run work`: окно появилось у того же процесса.
- [ ] Закрепить запущенный профиль в Dock, закрыть, кликнуть: после короткого мигания открыт нужный профиль, в логе стража запись.
- [ ] `clones kill --all`, затем `clones run work`: вход сохранился.
- [ ] После обновления Claude: `clones update`, профили открываются, вход на месте.
- [ ] `clones rm test`: подтверждение, данные, лаунчер и копия удалены.
