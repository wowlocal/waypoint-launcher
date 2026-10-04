# Waypoint

Лёгкий нативный (arm64) лаунчер для игр Blizzard на macOS. Без Battle.net и без Rosetta: только найти игру, залогиниться и запустить.

| Игра | Статус |
|---|---|
| Hearthstone | собрано, ждёт живой проверки |
| World of Warcraft (retail / classic / era) | экспериментально, на macOS ещё не проверено |
| Warcraft III | не поддерживается: сама игра только под Intel |

## Как это работает

Battle.net на macOS передаёт логин игре через preferences-домен `net.battle`
(`~/Library/Preferences/net.battle.plist`):

```
Launch Options/<КОД>/WEB_TOKEN   data, зашифрованный токен
Launch Options/<КОД>/REGION      EU / US / KR / CN
Launch Options/<КОД>/LOCALE      enUS, ruRU, ...
```

`<КОД>` равен `WTCG` для Hearthstone и `WoW` для всех версий WoW. Игра читает эти ключи
на старте (класс `RegistryDarwin` в игровом SDK). Waypoint пишет туда ровно то же самое и
запускает игру так же, как Battle.net:

- Hearthstone: `Hearthstone.app/Contents/MacOS/Hearthstone -launch -uid hs_beta`, рабочая директория `/Applications/Hearthstone`
- WoW: `World of Warcraft.app/.../World of Warcraft -launcherlogin -uid wow`, рабочая директория `_retail_` (аргументы взяты из Windows-логов; на macOS ещё не проверено)

Шифрование: AES-128-CBC, нулевой IV, ключ PBKDF2-HMAC-SHA1 (1000 итераций, соль
`someSalt`) от фиксированной энтропии, XOR с именем пользователя macOS. Это проверено
на токенах, которые записал настоящий Battle.net: `waypoint-cli check-tokens`.

Токен (`US-<32 hex>-<account id>`) выдаёт веб-логин
`https://<region>.battle.net/login/en/?externalChallenge=login&app=<КОД>`, который в
конце редиректит на `http://localhost:0/?ST=<токен>`. Перед каждым запуском Waypoint
получает свежий токен в скрытом WebView по сохранённой сессии, как это делает Battle.net.
Окно логина появляется, только если сессии нет или она истекла.

Игры находятся через `/Users/Shared/Battle.net/Agent/product.db`, а если его нет, по
`.product.db` в папке игры. Поэтому список игр не пропадёт и после удаления Battle.net.

## Сборка

Нужен Xcode (open-source toolchain из swiftly не видит Foundation в SDK macOS 27).

```sh
./scripts/bundle.sh                         # build/Waypoint.app
xcrun swift test
xcrun swift run waypoint-cli list           # найденные игры
xcrun swift run waypoint-cli plan hs_beta   # как будет запущена игра (dry run)
xcrun swift run waypoint-cli check-tokens   # проверка шифра на токенах Battle.net
```

## Ограничения

- **Обновления.** Патчи пока ставит Battle.net (через Rosetta). Если клиент устарел,
  сервер его не пустит. Следующий шаг: свой загрузчик по протоколу TACT/NGDP.
- **Установка WoW** пока тоже идёт через Battle.net.
- **Внутриигровой магазин** Hearthstone может требовать запущенный Battle.net (не проверено).
- **Неофициально.** Blizzard рекомендует запускать игры через Battle.net. Риск санкций
  кажется низким (так годами работает hearthstone-linux), но гарантий нет.

## Источники

- [hearthstone-linux](https://github.com/0xf4b1/hearthstone-linux): шифрование токена и веб-логин
- [BnetTokenator](https://github.com/InvoxiPlayGames/BnetTokenator): структура `Launch Options` (Windows)
- [TACTLib](https://github.com/overtools/TACTLib): схема `product.db`
