# Metsuke lane setup

Metsuke captures a local LP with Playwright and analyzes only the frozen
capture evidence. Dependency installation and browser downloads are daytime
operator steps. They never run during a nightly lane.

Daytime preparation uses the committed lockfile:

```sh
cd lanes/metsuke
npm ci --ignore-scripts
PLAYWRIGHT_BROWSERS_PATH=/absolute/path/to/ms-playwright \
  ./node_modules/.bin/playwright install chromium
```

Before the seven-night calibration begins, check the prepared runtime with
explicit canonical paths:

```sh
./check-readiness.sh \
  --lp-checkout /absolute/path/to/caty-talk-LP \
  --browser-cache /absolute/path/to/ms-playwright \
  --codex-bin /absolute/path/to/codex \
  --state-dir /absolute/path/to/alpha-nightshift/state
```

The checker is credential-free and read-only. It does not source configuration,
run package managers, download or launch a browser, execute Codex, start the LP,
contact a host, or create the prospective state directory. It fails closed on
missing, relative, noncanonical, or symlink-aliased paths and prints one stable
JSON object only after every readiness cell passes. Browser readiness checks
the revision-1187 Chromium headless shell used by the lane's headless capture.

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
or browser cache is missing. Metsuke never installs dependencies or downloads
browsers itself. Readiness prepares or activates neither Phase 1b nor any
credential-bearing capability.
