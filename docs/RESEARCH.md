# Исследование: как изолировать инстансы Claude Desktop

Исследована версия **Claude 2.42304.0** (macOS universal, сборка `e7f60e65`, официальный
`https://downloads.claude.ai/releases/darwin/universal/2.42304.0/Claude-e7f60e65….zip`).
Метод — статический анализ бандла: `Info.plist`, подпись и entitlements бинарника,
распакованный `app.asar` (main-процесс: `.vite/build/index.pre.js` и `index.chunk-*.js`, минифицированный JS).

> **Важно.** Выводы ниже сделаны чтением кода приложения в Linux-контейнере без macOS. Позже основное
> подтвердилось на живом Маке (Claude 2.42304.0): изоляция профилей через `--user-data-dir`, имя копии
> в Dock, значок на копии без поломки подписи, страж копий. Выводы о поведении LaunchServices и Electron основаны на
> документированном поведении этих компонентов. Финальная проверка на живой системе —
> `CLONES_E2E_REAL=1 make e2e` и чек-лист в [TECHNICAL.ru.md](TECHNICAL.ru.md#чек-лист-ручной-проверки). Если Anthropic изменит описанные места в коде,
> `clones doctor` предупредит о расхождении версий.

## Итог

| Вопрос | Ответ |
|---|---|
| Механизм изоляции | **`--user-data-dir=<path>`** у оригинального `Claude.app`, запуск через LaunchServices как новый инстанс (`NSWorkspace.openApplication` с `createsNewApplicationInstance`, аналог `open -n -a Claude --args …`) |
| `CLAUDE_USER_DATA_DIR` | не работает в подписанных сборках: переменная удаляется на старте |
| Подмена `HOME` | не нужна (и хуже: ломает Keychain-пути, ~/.ssh, git и всё, что MCP-серверы ищут в домашней папке) |
| Копия бандла с другим `CFBundleIdentifier` | не нужна (и почти невозможна: см. entitlements ниже) |
| Single-instance lock | **отсутствует**. Два процесса на одной папке будут оба работать и портить данные → clones сам не даёт запустить профиль дважды |
| Логин | вход по email-коду, SSO и обычный вход через ASWebAuthenticationSession — изолированы. **Вход через Google** и OAuth MCP-коннекторов идут через `claude://` и могут попасть не в тот инстанс → `clones login <name>` |
| Keychain / `safeStorage` | общий ключ «Claude Safe Storage», это безопасно |

## 1. `--user-data-dir`

**Что делает Electron.** Chromium-переключатель `--user-data-dir` Electron применяет до запуска JS:
он задаёт `DIR_USER_DATA`, на который опираются `app.getPath('userData')` и `sessionData`
(Cookies, Local Storage, IndexedDB, кэш, GPUCache и т.д.). Это тот же приём, которым годами
запускают несколько Slack/Discord/VS Code.

**Перезаписывает ли Claude путь?** Все вызовы `app.setPath('userData', …)` в main-процессе:

```js
// index.pre.js (деминифицировано)
if (process.env.CLAUDE_USER_DATA_DIR) {               // (а) dev/e2e-переменная
  app.setPath("userData", process.env.CLAUDE_USER_DATA_DIR);
  app.setPath("logs", path.resolve(dir, "Logs"));
}
if (!process.env.CLAUDE_USER_DATA_DIR) {
  if (isCustom3pDeployment(config)) {                   // (б) только корпоративный «3p»-режим
    const dir = userDataFor3p();                        //     → …/Claude-3p
    if (app.getPath("userData") !== dir) app.setPath("userData", dir);
  } else if (config.workspace.relocateUncUserData) { … } // (в) только Windows/UNC
}
```

В обычном (не 3p, не Windows) режиме путь из `--user-data-dir` **не перезаписывается**.
Флаг не входит в чёрный список переключателей, с которыми приложение отказывается стартовать
(`remote-debugging-port`, `host-rules`, `disable-web-security`, `ssl-key-log-file`, … — `LZ` в `index.pre.js`).

Конфиг MCP читается от `userData`, а не по жёстко заданному пути:

```js
function Yg() { return path.join(app.getPath("userData"), "claude_desktop_config.json") }
```

**Побочный эффект.** Приложение замечает, что userData не равна `~/Library/Application Support/Claude`,
и выставляет `localPairingDisabledReason = "userData relocated"`: в профилях clones
**не работает локальное сопряжение с расширением Claude in Chrome**. В профиле `default` работает.

**`CLAUDE_USER_DATA_DIR` — не вариант.** В подписанной сборке переменная удаляется до использования:

```js
app.isPackaged && !isDeveloperApprovedCdpToken() && stripEnv(process.env)
// stripEnv: delete env.CLAUDE_USER_DATA_DIR; delete env.SSLKEYLOGFILE …
// позже в логах: "[user-data-dir] CLAUDE_USER_DATA_DIR is set and signed builds ignore it"
```

(Её разрешает только подписанный Anthropic токен `CLAUDE_CDP_AUTH` для внутренних e2e-тестов.)

## 2. Single-instance lock

В main-процессе нет ни `requestSingleInstanceLock`, ни `hasSingleInstanceLock`; событие
`second-instance` используется только в Linux-коде передачи `XDG_ACTIVATION_TOKEN`.
Без вызова `requestSingleInstanceLock` Electron не создаёт Chromium `ProcessSingleton`.

Следствия:
- второй инстанс с **другой** папкой стартует как самостоятельный процесс — изоляция работает;
- второй инстанс с **той же** папкой тоже стартует, и два процесса пишут в одни SQLite/LevelDB → порча
  данных. Поэтому `clones run` сначала ищет запущенный процесс профиля и фокусирует его,
  `clones ls`/`doctor` показывают `CONFLICT`;
- macOS сама «единит» приложения только при запуске через LaunchServices **без** `-n`: `open -a Claude`
  или клик по Claude.app при уже запущенном клоне просто активирует **какой-то** запущенный
  процесс с bundle id `com.anthropic.claudefordesktop`. Поэтому clones всегда запускает с
  `createsNewApplicationInstance`, в том числе `default`.

## 3. Логин и `claude://`

`Info.plist` регистрирует схемы `claude` и `msauth.com.anthropic.claudefordesktop`.
Associated domains (universal links) в entitlements нет.

Как устроен вход (функция `hXn` в `index.chunk-muI2IV6k.js`):

1. Вход по email: письмо с кодом, код вводится **в окне приложения** — никаких внешних редиректов.
   (Ссылку из письма открывать не нужно: она уйдёт в браузер/claude:// — см. п. 3.)
2. Ссылки `https://claude.ai/login/*` и WorkOS SSO (`api.workos.com/sso/*`) открываются через
   **`ASWebAuthenticationSession`** (нативный модуль `AuthRequest`). Колбэк сессия возвращает
   **в тот процесс, который её начал**, минуя LaunchServices, — несколько инстансов друг другу не мешают.
3. **Исключение — Google** (`/login/app-google-auth`):
   ```js
   function cXn(url) {
     return url.pathname === "/login/app-google-auth"
       ? (isDefaultProtocolClient("claude") ? !featureFlag("743194442") : false)  // true → системный браузер
       : false;
   }
   ```
   Если приложение считает себя обработчиком `claude://` (а считают **все** инстансы: проверка на macOS
   идёт по bundle id), вход идёт через системный браузер, и результат возвращается ссылкой
   `claude://login/…?hop_nonce=…`. macOS отдаёт её **одному** процессу с этим bundle id — не обязательно
   тому, кто начинал вход. По коду я ожидал, что чужой инстанс сверит одноразовый `hop_nonce`
   (`dXn`/`pXn`) и молча отбросит ссылку. **На живой системе поведение другое:** чужой инстанс
   показывает код для входа, а нужный профиль так и не входит. Вывод тот же — входить через Google,
   когда открыт только нужный профиль (`clones login`).
4. Запасной путь: если `ASWebAuthenticationSession` упала или 60 с не вернула колбэк при не-Safari браузере
   по умолчанию, приложение тоже уходит в системный браузер → та же проблема, что в п. 3.
5. `claude://…/mcp-auth-callback` — OAuth для MCP-коннекторов — тоже через `claude://` → может прийти
   не в тот инстанс.

**Решение в clones:**
- `clones login <name>`: закрывает остальные инстансы (с подтверждением), запускает нужный единственным,
  после входа по Enter возвращает закрытые. Пока запущен один Claude, `claude://` идёт только ему.
- Рекомендация: входить по **email-коду** — работает при любом числе инстансов.
- Сессия хранится в cookies профиля, поэтому вход нужен один раз на профиль.

## 4. Keychain и `safeStorage`

- `safeStorage` на macOS берёт ключ из Keychain: запись «Claude Safe Storage» (сервис по имени
  приложения). Имя у всех инстансов одно → **ключ общий**. Это нормально: ключ лишь шифрует данные,
  которые лежат в userData каждого профиля; создаётся он один раз и не меняется, поэтому сессии
  друг друга не ломают. Доступ к записи выдан подписи Claude.app, а она у всех инстансов одна, поэтому дополнительных запросов Keychain не будет.
- Аппаратный ключ устройства (`keychain-access-groups`: `Q6L2SF6YDW.com.anthropic.claude.hwkey`,
  Secure Enclave) создаётся с тегом **на аккаунт**, а счётчик поколений ключей хранится в userData.
  Разные аккаунты в разных профилях → разные ключи. Один и тот же аккаунт в двух профилях
  теоретически может перевыпускать общий ключ — не держите один аккаунт в двух профилях.
- Entitlements: `keychain-access-groups` (hwkey, webauthn, Microsoft SSO) + provisioning profile команды
  `Q6L2SF6YDW`. Это ограниченные entitlements: копия бандла с ad-hoc подписью их потеряет
  (иначе macOS не запустит бинарник), и сломаются аппаратный ключ, passkeys и Microsoft SSO.
  Это ещё один довод против варианта «копия бандла с другим bundle id».

## 5. Другие общие места

Из `zap`-секции официальной Homebrew-cask и кода:

| Путь | Что там | Изолировано? |
|---|---|---|
| `~/Library/Application Support/Claude` | userData default | у клонов своя папка |
| `~/Library/Logs/Claude` | `main.log` и др. | **нет**: `--user-data-dir` не меняет `app.getPath('logs')`, все инстансы пишут сюда |
| `~/Library/Preferences/com.anthropic.claudefordesktop.plist` | NSUserDefaults (пара флагов вроде `NSAutoFillHeuristicsEnabled`) | нет, но безвредно |
| `~/Library/Caches/com.anthropic.claudefordesktop`, `…ShipIt`, `~/Library/HTTPStorages/…` | автообновление Squirrel | нет, и не нужно: бандл один |
| `~/Library/Saved Application State/…savedState` | восстановление окон | `NSQuitAlwaysKeepsWindows = false`, не используется |
| `~/.claude` | Claude Code внутри Desktop | нет сам по себе; clones по умолчанию задаёт профилю свой `CLAUDE_CONFIG_DIR` (отключается `--no-isolate-claude-code`) |
| `~/Documents/Claude`, `~/Claude` | файлы Cowork: scheduled tasks, live artifacts | нет |
| Chrome `NativeMessagingHosts` | манифест для расширения Claude in Chrome | нет (и сопряжение в клонах отключено, см. п. 1) |
| Keychain «Claude Safe Storage» | ключ safeStorage | общий, безопасно (п. 4) |

## 6. Почему не запасные варианты

1. **`HOME=<profile>`** — меняет вообще всё: Keychain-пути, `~/.ssh`, `~/.gitconfig`, `~/.npmrc`,
  пути MCP-серверов и файлы, к которым Claude даёт доступ. Изоляции больше, чем просили, и
  ломается окружение MCP. `--user-data-dir` даёт ровно нужное.
2. **Копия бандла с другим `CFBundleIdentifier` + ad-hoc подпись** — ломает автообновление, теряет
  ограниченные entitlements (п. 4). Не нужна.

### Неизменённая копия бандла (используется для имени в Dock)

Изоляцию даёт `--user-data-dir`, но Dock показывает имя и иконку бандла, которым запущен процесс.
Поэтому clones дополнительно делает **побайтовую** копию `Claude.app` под именем профиля
(`Claude Test1.app`, APFS clonefile) и запускает профиль ею. Это не «запасной вариант» выше:

- `Info.plist`, бинарники и ресурсы не меняются, а имя папки бандла в подпись не входит —
  подпись и restricted entitlements остаются действительными (clones проверяет `codesign --verify`
  после копирования и удаляет копию при ошибке);
- bundle id тот же, поэтому Keychain («Claude Safe Storage», hwkey) работает как у оригинала;
- у Claude нет `LSHasLocalizedDisplayName`, поэтому Finder, Dock и ⌘Tab показывают имя файла
  (подтверждено на живой системе: «Claude 1», «Claude 2»);
- иконку с плашкой clones ставит на копию через `NSWorkspace.setIcon` (файл `Icon\r` в корне бандла)
  и оставляет её, только если `codesign --verify` после этого проходит;
- Squirrel обновляет копию на месте, как обычный Claude (подпись та же). Копии расходятся с оригиналом
  после обновления; `clones doctor` это видит, `clones app <name>` пересоздаёт копию.

Цена: копию нельзя открывать напрямую — без аргументов Electron возьмёт userData по имени продукта
(`~/Library/Application Support/Claude`), т.е. данные `default`. И у всех копий один bundle id, поэтому
`claude://` macOS может отдать любой из них.

## 7. Что ещё стоит знать

- **Автообновление.** Бандл один, обновляется как обычно. Но Squirrel.Mac (ShipIt) после установки
  обновления перезапускает приложение по пути бандла **без аргументов** — обновление, применённое
  из клона, скорее всего вернёт вас в `default`. После обновления
  удобнее: `clones kill --all`, затем открыть нужные профили. Уже запущенные инстансы продолжают
  работать на старых файлах до перезапуска.
- **Dock.** Работающий профиль показывается в Dock бандлом, которым запущен: с копией — «Claude <Name>»,
  без копии (`--no-copy`) — обычным «Claude». См. «Неизменённая копия бандла» выше.
- **`app.relaunch()`** (перезапуск из настроек) сохраняет исходные аргументы → профиль остаётся тем же.

## 8. bash вместо Swift?

Ядро (`open -n -a Claude --args --user-data-dir=…`) — одна строка shell, и скрипт справился бы с
`new/rm/dir/config`. Но надёжные `ls/kill/open` требуют точного argv чужих процессов
(пути с пробелами в «Application Support» ломают разбор `ps`), фокуса конкретного PID
(`open -a` выберет произвольный инстанс) и отрисовки иконок. Это естественно делается через
`sysctl(KERN_PROCARGS2)`, `NSRunningApplication` и AppKit, поэтому оставлен Swift.
