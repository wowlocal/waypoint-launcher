<div align="center">

# Waypoint

**Крошечный нативный лаунчер для игр Blizzard на маках с Apple Silicon.**<br>
Без Battle.net. Без Rosetta. Просто жмёшь Play.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-111?logo=apple&logoColor=white)](#сборка)
[![Apple Silicon native](https://img.shields.io/badge/Apple%20Silicon-native-2ea44f)](#зачем)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#сборка)
[![Unofficial](https://img.shields.io/badge/Blizzard-unofficial-8a8a8a)](#дисклеймер)

<img src="docs/screenshot.png" width="600" alt="Окно Waypoint со списком игр: Hearthstone и Warcraft III">

[English](README.md) · **Русский**

</div>

---

## Зачем

Battle.net для Mac до сих пор собран только под Intel. Любому маку на Apple Silicon нужна Rosetta, просто чтобы его открыть, хотя Hearthstone и World of Warcraft сами по себе работают нативно.

Скоро это станет настоящей проблемой: **macOS 27 — последняя версия с полной Rosetta**. Начиная с macOS 28, Apple оставит только урезанную версию для старых игр.

Сам лаунчер на деле нужен только для того, чтобы залогинить игру. Waypoint делает ровно это, и нативно.

|  | Battle.net | Waypoint |
|---|---|---|
| Архитектура | Intel (Rosetta) | Apple Silicon |
| Размер на диске | ~1.5 ГБ | **536 КБ** |
| Висит в фоне | приложение + Agent + браузерные хелперы | ничего |

## Возможности

- **Нативный.** Написан на Swift и собран только под arm64.
- **Вход один раз.** Через официальный веб-логин Battle.net. Дальше каждый запуск — в один клик.
- **Сам находит игры.** Читает список установок Battle.net, а если его нет, сканирует папки игр. Поэтому работает и после удаления Battle.net.
- **Ничего не меняет в игре.** Без патчей и внедрения кода: логин передаётся ровно так же, как это делает Battle.net.
- **Быстрый запуск** из строки меню.

## Поддерживаемые игры

| Игра | Статус |
|---|---|
| Hearthstone | ✅ **Работает.** Проверено нативно при полностью закрытых Battle.net и Agent |
| World of Warcraft: Retail, Classic, Classic Era | 🧪 Реализовано, на macOS ещё не проверено |
| Warcraft III: Reforged | ❌ Сама игра только под Intel, без Rosetta не обойтись |

## Сборка

Нужны macOS 14+ и Xcode со Swift 6.

```sh
git clone https://github.com/wowlocal/waypoint-launcher.git
cd waypoint-launcher
./scripts/bundle.sh          # → build/Waypoint.app
open build/Waypoint.app
```

Если хочешь оставить приложение насовсем, перенеси `Waypoint.app` в `/Applications`.

## Как пользоваться

1. Открой Waypoint и нажми **Play**.
2. В первый раз войди в Battle.net в появившемся окне. Двухфакторка работает.
3. Всё. При следующих запусках логин не нужен.

Если игра когда-нибудь не примет логин, нажми правой кнопкой на **Play** и выбери **Sign In Again and Play**.

> [!NOTE]
> Пока что игры по-прежнему ставит и обновляет Battle.net (см. [Планы](#планы)). Waypoint запускает то, что установлено. Когда выходит патч, обнови игру один раз через Battle.net.

## Как это работает

На macOS Battle.net не передаёт игре логин в командной строке. Он записывает зашифрованный токен в preferences-домен `net.battle` и запускает игру, а игра читает токен на старте. Waypoint делает то же самое.

```mermaid
sequenceDiagram
    actor U as Ты
    participant W as Waypoint
    participant L as Веб-логин Battle.net
    participant P as Prefs net.battle
    participant G as Hearthstone
    participant S as Серверы Blizzard

    U->>W: Play
    W->>L: /login?app=WTCG (скрыто, по сохранённой сессии)
    L-->>W: редирект на localhost:0/?ST=US-…
    Note over W,L: нет сессии → прошлый токен<br/>совсем ничего → окно логина
    W->>P: Launch Options/WTCG/WEB_TOKEN (зашифрован)<br/>REGION, LOCALE
    W->>G: Hearthstone -launch -uid hs_beta
    G->>P: читает токен
    G->>S: логинится
```

<details>
<summary><b>Подробности</b></summary>

**Preferences** (`~/Library/Preferences/net.battle.plist`)

| Ключ | Значение |
|---|---|
| `Launch Options/<КОД>/WEB_TOKEN` | зашифрованный токен (data) |
| `Launch Options/<КОД>/REGION` | `EU`, `US`, `KR`, `CN` |
| `Launch Options/<КОД>/LOCALE` | `enUS`, `ruRU`, … |

`<КОД>` равен `WTCG` для Hearthstone и `WoW` для всех версий WoW.

**Шифрование.** AES-128-CBC с нулевым IV и паддингом PKCS#7. Ключ — PBKDF2-HMAC-SHA1 (1000 раундов, соль `someSalt`) от фиксированной 16-байтной энтропии, XOR с именем пользователя macOS. Это повторяет `RegistryDarwin` из Battle.net SDK внутри игры. Проверено на токенах, которые записал настоящий Battle.net (`waypoint-cli check-tokens`).

**Токен.** Веб-логин `https://<region>.battle.net/login/en/?externalChallenge=login&app=<КОД>` в конце редиректит на `http://localhost:0/?ST=<токен>`. Токен выглядит как `US-<32 hex>-<id аккаунта>`.

**Команды запуска**

| Игра | Команда | Рабочая папка |
|---|---|---|
| Hearthstone | `Hearthstone.app/…/Hearthstone -launch -uid hs_beta` | папка установки |
| WoW | `World of Warcraft.app/…/World of Warcraft -launcherlogin -uid wow` | папка версии (`_retail_`, `_classic_`, …) |

Игры запускаются через `posix_spawn` и сами отвечают за себя перед системой, как и при запуске из Battle.net. Поэтому системные запросы разрешений (например, микрофон для голосового чата WoW) приходят от игры, а не от лаунчера.

**Поиск игр.** Список берётся из `/Users/Shared/Battle.net/Agent/product.db` (protobuf) или из `.product.db` в папке каждой игры.

</details>

## Командная строка

```sh
xcrun swift run waypoint-cli list            # установленные игры и работают ли они нативно
xcrun swift run waypoint-cli plan hs_beta    # dry run: как будет запущена игра
xcrun swift run waypoint-cli check-tokens    # проверка шифра на токенах от Battle.net
xcrun swift test
```

## Планы

- [x] Hearthstone
- [x] Вход один раз, запуск в один клик
- [ ] Проверить World of Warcraft на macOS
- [ ] Установка и обновление игр без Battle.net (TACT/NGDP)
- [ ] Внутриигровой магазин Hearthstone без Battle.net (не проверено)
- [ ] Готовые подписанные релизы с нотаризацией
- [ ] Иконка приложения

## Дисклеймер

Waypoint — неофициальный фанатский проект. Он не связан с Blizzard Entertainment и не одобрен ею. Blizzard, Battle.net, Hearthstone, World of Warcraft и Warcraft — торговые марки Blizzard Entertainment, Inc.

Blizzard официально не поддерживает запуск игр в обход Battle.net. Этот подход используют годами (см. Благодарности), но гарантий нет, и Blizzard может в любой момент изменить способ передачи логина. Используй на свой риск.

## Благодарности

- [hearthstone-linux](https://github.com/0xf4b1/hearthstone-linux): шифрование токена и веб-логин
- [BnetTokenator](https://github.com/InvoxiPlayGames/BnetTokenator): структура `Launch Options`
- [TACTLib](https://github.com/overtools/TACTLib): схема `product.db`
