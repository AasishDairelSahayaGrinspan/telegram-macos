# Paid send-button checks

Run on macOS with Xcode and the pinned `telegram-ios` checkout available:

```
python3 tools/tests/paid-send-button/run.py --scratch-path /tmp/telegram-paid-send-build
```

Optional `--snapshots /tmp/telegram-paid-send-images` captures prices 1, 1K and 12.5K against light and dark fixture backgrounds. This briefly opens a component window and requires macOS screen recording access. Capture the baseline separately with:

```
python3 tools/tests/paid-send-button/run.py --revision 3cacb03e --captures-only --scratch-path /tmp/telegram-paid-send-build --snapshots /tmp/telegram-paid-send-before
```

Baseline capture compiles that revision's production view and methods; it does not run the assertions for the new layout.

The runner compiles the complete production `StarsSendActionView`, the send button's state/update/sizing/layout methods and the composer's send-slot/placement methods against the real TGUIKit package. It uses the app's star asset, native text measurement and native mouse events. Checks cover eight prices, four pane widths, centering, matching button/glass geometry, input-space reservation, clicks on both edges and the label, callback routing, price changes and transitions to recording, ordinary send, slow mode and inline loading.

Account models, theme/localization, loader content and animation hooks are controlled fixtures. Clicks increment a local counter and never send messages. Captures use a plain field background and a real native LiquidGlassView positioned with the production send-slot geometry. They do not show the running client or validate the composer's full Liquid Glass composition. Full ChatUI/Telegram compilation is outside this focused check.
