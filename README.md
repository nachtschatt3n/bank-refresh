# MoneyMoney Menu Bar Refresher

MoneyMoney Menu Bar Refresher is a small native macOS menu bar app that opens MoneyMoney and triggers `File > Refresh All Accounts` on a timer.

Instead of relying on `launchd`, the app lives in the menu bar and manages its own schedule. You can refresh on demand, choose a timer interval, and see whether the last run succeeded without opening a terminal.

## What it does

- Runs as a menu bar app with an icon-only tray item
- Opens or activates MoneyMoney when a refresh starts
- Triggers `Refresh All Accounts` through macOS UI scripting
- Supports refresh intervals of `15 min`, `2 h`, `6 h`, and `12 h`
- Shows the current status, the last refresh time, and the next scheduled refresh
- Changes the tray icon for idle, running, success, and failure states

## Requirements

- macOS
- MoneyMoney installed
- Accessibility permission for `/Applications/RefreshMoneyMoney.app`
- MoneyMoney using English menu labels

## Language limitation

Right now, yes: this only works reliably when MoneyMoney is using English menu labels.

The bundled AppleScript clicks these exact UI items:

- `File`
- `Refresh All Accounts`

If MoneyMoney is localized to another language, the script will not find those menu entries and the refresh will fail. To support another language, update the menu titles in [`refresh-moneymoney.applescript`](./refresh-moneymoney.applescript).

## Setup

1. Clone the repository:

```sh
git clone git@github.com:nachtschatt3n/bank-refresh.git
cd bank-refresh
```

2. Build the app:

```sh
./build-native-app.sh
```

3. Install it to `/Applications`:

```sh
mv ./RefreshMoneyMoney.app /Applications/RefreshMoneyMoney.app
```

4. Open macOS System Settings:
   `System Settings > Privacy & Security > Accessibility`

5. Add `/Applications/RefreshMoneyMoney.app` to the Accessibility list and enable it.

6. If macOS shows a permission prompt the first time the app runs, allow it.

7. Launch the app:

```sh
open /Applications/RefreshMoneyMoney.app
```

## macOS security settings

The app uses `System Events` to control the MoneyMoney UI, so macOS will block it unless Accessibility access is enabled.

If refreshes fail with an assistive access error:

1. Go to `System Settings > Privacy & Security > Accessibility`
2. Remove `RefreshMoneyMoney` from the list if it is already there
3. Add `/Applications/RefreshMoneyMoney.app` again
4. Ensure the toggle is enabled
5. Quit and reopen the app

Using `/Applications/RefreshMoneyMoney.app` as the stable install path is important because macOS privacy permissions are tied to the app identity and location.

## How to use it

- Click the menu bar icon
- Choose `Refresh now` for an immediate refresh
- Pick one of the built-in timer intervals
- Check the menu for `Status`, `Last refresh`, and `Next refresh`

The timer runs only while the menu bar app is open.

## Project layout

- `refresh-moneymoney.applescript`: plain-text AppleScript used for the actual refresh
- `native-wrapper/main.swift`: native menu bar app
- `native-wrapper/Info.plist`: app metadata with bundle identifier
- `build-native-app.sh`: build and ad-hoc signing script
- `tests/smoke-test.sh`: bundle smoke test

## Test

```sh
./tests/smoke-test.sh
```

## Notes

- The repo intentionally tracks source files only; the built `.app` bundle is generated.
