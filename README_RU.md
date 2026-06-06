# SanyaWarden Client MapGuard handoff

Дата: 2026-06-06

## Что это

Это комплект для разработчика лаунчера, чтобы игрокам автоматически ставился клиентский `ScumWardenMapGuard`.

Он нужен потому, что серверная настройка:

```ini
scum.AllowMapScreen=False
```

выключает карту глобально. Чтобы игрок с нужным предметом в руках всё равно мог открыть карту, клиент должен получить UE4SS + `ScumWardenMapGuard` через лаунчер.

## Что скинуть разработчику лаунчера

Скинь ему весь архив:

```text
SanyaWarden_Client_MapGuard_LauncherPayload_20260606_v2.zip
```

И отдельно текстовый prompt:

```text
docs\PROMPT_FOR_GITHUB_LAUNCHER_DEV_RU.md
```

## Главные правила

Лаунчер должен распаковать содержимое:

```text
payload\UPLOAD_TO_SCUM_BINARIES_WIN64\
```

в клиентскую папку:

```text
SCUM\Binaries\Win64\
```

Файл:

```text
Mods\mods.txt
```

надо не перетирать полностью, а аккуратно добавить/обновить строку:

```text
ScumWardenMapGuard : 1
```

## Проверка

После установки и запуска игры в UE4SS-логе клиента должна появиться строка:

```text
[ScumWardenMapGuard] loaded. Required item in hands: Magnifying_Glass, Magnifying_Glass1
```

Если строки нет, клиентский мод не загрузился.
