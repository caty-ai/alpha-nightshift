# Metsuke lane setup

Metsuke captures a local LP with Playwright and analyzes only the frozen
capture evidence. The lane does not install dependencies during a night run.

One-time setup:

```sh
cd lanes/metsuke
npm install
PLAYWRIGHT_BROWSERS_PATH=/absolute/path/to/ms-playwright \
  npx playwright install chromium
```

Configure `config/nightshift.conf` with:

- `LANE_HOME_LINKS="$HOME/.codex"` so the isolated lane HOME can use existing
  Codex authentication. The dispatcher still supplies credential-neutral Git
  configuration and no GitHub credentials.
- `PLAYWRIGHT_BROWSERS_PATH_REAL` as the absolute, existing browser cache used
  during the install command.
- `METSUKE_LP_CHECKOUT` as the absolute caty-talk-LP checkout path, with its own
  `node_modules` already installed.
- `METSUKE_TARGET_URL` only when intentionally observing an already-served
  target instead of building the configured checkout.
- `METSUKE_PORT`, `METSUKE_PERSONAS`, and `METSUKE_CODEX_BIN` if their defaults
  need to change.

The preflight fails before capture when the lane-local Playwright dependency
or browser cache is missing. Metsuke never runs `npm install` itself.
