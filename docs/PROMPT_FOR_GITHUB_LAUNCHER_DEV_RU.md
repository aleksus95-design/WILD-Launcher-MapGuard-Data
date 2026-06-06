# Prompt для разработчика лаунчера / GitHub

Ты разрабатываешь лаунчер для SCUM-сервера WILD / SanyaWarden.

Твоя задача: создать в GitHub понятную структуру для клиентских модулей лаунчера и подключить текущий клиентский мод `ScumWardenMapGuard`, который позволяет открывать карту только при наличии нужного предмета в руках.

## Контекст

На сервере карта должна быть выключена:

```ini
scum.AllowMapScreen=False
```

Без клиентского мода обычный игрок при нажатии `M` видит стандартное сообщение SCUM, что карта выключена.

Клиентский мод `ScumWardenMapGuard` должен быть установлен лаунчером в клиентскую папку игры:

```text
SCUM\Binaries\Win64\
```

После этого мод перехватывает `M`, проверяет предмет в руках и открывает карту только если предмет подходит.

Подходящие item id:

```text
Magnifying_Glass
Magnifying_Glass1
```

## Готовый payload

Используй архив:

```text
SanyaWarden_Client_MapGuard_LauncherPayload_20260606_v2.zip
```

Внутри архива есть папка:

```text
payload\UPLOAD_TO_SCUM_BINARIES_WIN64\
```

Содержимое этой папки надо копировать в:

```text
SCUM\Binaries\Win64\
```

## Структура GitHub-репозитория

Создай или приведи репозиторий к такой структуре:

```text
repo-root/
  README.md

  docs/
    client-install.md
    client-mod-contract.md
    mods-txt-merge-policy.md
    qa-checklist.md

  manifests/
    scumwarden-client-mapguard-20260606-v2.json

  payloads/
    scumwarden-client-mapguard/
      20260606-v2/
        UPLOAD_TO_SCUM_BINARIES_WIN64/
          UE4SS.dll
          version.dll
          UE4SS-settings.ini
          Mods/
            mods.txt
            ScumWardenMapGuard/
              enabled.txt
              scripts/
                main.lua
          ScumWarden/
            configs/
              map-guard.json

  scripts/
    build-client-payload.ps1
    verify-client-payload.ps1

  src/
    launcher/
      ...
```

## Файлы и целевые пути установки

Копировать в клиентский `SCUM\Binaries\Win64`:

```text
UE4SS.dll
version.dll
UE4SS-settings.ini
Mods\ScumWardenMapGuard\enabled.txt
Mods\ScumWardenMapGuard\scripts\main.lua
ScumWarden\configs\map-guard.json
```

Файл:

```text
Mods\mods.txt
```

нельзя тупо перезаписывать как единственный источник истины, если у игрока уже есть другие моды.

Лаунчер должен аккуратно гарантировать строку:

```text
ScumWardenMapGuard : 1
```

Правило:

1. Если `Mods\mods.txt` отсутствует, создать его.
2. Если строка `ScumWardenMapGuard` отсутствует, добавить `ScumWardenMapGuard : 1`.
3. Если строка есть, заменить её на `ScumWardenMapGuard : 1`.
4. Другие строки не удалять.
5. Не добавлять серверные строки `ScumWardenBridge`, `scum_rcon`, `SCUMTraderManager` в клиентский пакет, если они не являются отдельными клиентскими модулями.

## Manifest

Используй manifest:

```text
manifests\scumwarden-client-mapguard-20260606-v2.json
```

Лаунчер должен сверять:

```text
relativePath
size
sha256
action
```

Для `action = copy-overwrite-if-hash-diff`:

1. Проверить существование файла.
2. Проверить SHA256.
3. Если файла нет или хэш отличается, скопировать файл из payload.

Для `action = merge-mods-txt-ensure-line`:

1. Не заменять весь файл слепо.
2. Выполнить merge-правило для строки `ScumWardenMapGuard : 1`.

## Проверка после установки

После установки у игрока должны существовать:

```text
SCUM\Binaries\Win64\UE4SS.dll
SCUM\Binaries\Win64\version.dll
SCUM\Binaries\Win64\UE4SS-settings.ini
SCUM\Binaries\Win64\Mods\mods.txt
SCUM\Binaries\Win64\Mods\ScumWardenMapGuard\enabled.txt
SCUM\Binaries\Win64\Mods\ScumWardenMapGuard\scripts\main.lua
SCUM\Binaries\Win64\ScumWarden\configs\map-guard.json
```

В `Mods\mods.txt` должна быть строка:

```text
ScumWardenMapGuard : 1
```

После запуска игры в UE4SS-логе клиента должна быть строка:

```text
[ScumWardenMapGuard] loaded. Required item in hands: Magnifying_Glass, Magnifying_Glass1
```

Проверять оба возможных места лога:

```text
SCUM\Binaries\Win64\UE4SS.log
SCUM\Binaries\Win64\UE4SS\UE4SS.log
```

Если этой строки нет, значит UE4SS или `ScumWardenMapGuard` не загрузился.

## Что нельзя делать

Не копировать payload в папку dedicated-сервера. Это клиентский payload.

Не ставить файлы рядом с `SCUM.exe`; нужен именно:

```text
SCUM\Binaries\Win64\
```

Не раздавать клиентам серверный rollback-релиз:

```text
SanyaWarden_ROLLBACK_RELEASE_20260604_213628
```

В нём нет `ScumWardenMapGuard`.

Не раздавать клиентам старый `CLEAN_RELEASE_20260603` как пакет карты. В нём тоже нет MapGuard.

Не включать на сервере:

```ini
scum.AllowMapScreen=True
```

Иначе карта станет доступна всем и логика “карта только с предметом” потеряет смысл.

## Как сделать удобно на будущее

Текущий пакет можно подключить как standalone:

```text
Mods\ScumWardenMapGuard
```

Но для следующих клиентских модов лучше заложить архитектуру `ScumWardenClientCore`.

Будущая структура:

```text
SCUM\Binaries\Win64\
  Mods\
    mods.txt
    ScumWardenClientCore\
      enabled.txt
      scripts\
        main.lua
  ScumWarden\
    client\
      manifest.json
      modules\
        map-guard.lua
        another-client-module.lua
    configs\
      client-map-guard.json
```

В будущем в `Mods\mods.txt` должна быть одна строка:

```text
ScumWardenClientCore : 1
```

А модули будут включаться через:

```text
ScumWarden\client\manifest.json
```

Но текущий релиз пока ставь как `ScumWardenMapGuard`, чтобы быстро починить карту игрокам.

## Критерий готовности

Работа считается готовой, когда:

1. GitHub содержит структуру `docs`, `manifests`, `payloads`, `scripts`, `src/launcher`.
2. Лаунчер умеет находить `SCUM\Binaries\Win64`.
3. Лаунчер копирует payload по manifest.
4. Лаунчер merge-ит `Mods\mods.txt`, не стирая другие строки.
5. После запуска игры в UE4SS-логе есть `[ScumWardenMapGuard] loaded`.
6. На сервере `scum.AllowMapScreen=False`.
7. Игрок без предмета видит запрет карты.
8. Игрок с `Magnifying_Glass` или `Magnifying_Glass1` в руках может открыть карту.
