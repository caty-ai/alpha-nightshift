import { chromium } from "playwright";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  ELEMENT_TEXT_MAX_CHARS,
  boundedText,
  createConsoleCollector,
} from "./capture-bounds.mjs";

const VIEWPORTS = [
  { id: "mobile", width: 390, height: 844 },
  { id: "tablet", width: 768, height: 1024 },
  { id: "desktop", width: 1440, height: 900 },
];
const FIXED_WAIT_MS = 500;

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (!flag?.startsWith("--") || value === undefined) {
      throw new Error(`invalid argument near ${flag ?? "<end>"}`);
    }
    values[flag.slice(2)] = value;
  }
  for (const required of ["base-url", "flows", "out"]) {
    if (!values[required]) {
      throw new Error(`--${required} is required`);
    }
  }
  return values;
}

function safeName(value) {
  return value.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-|-$/g, "");
}

function evidenceRef(outDir, fileName) {
  return `${path.basename(path.resolve(outDir))}/${fileName}`;
}

function makeLocator(page, definition) {
  if (!definition) {
    return null;
  }
  if (definition.role) {
    return page.getByRole(definition.role, {
      name: definition.name ? new RegExp(definition.name, "i") : undefined,
    }).first();
  }
  if (definition.text) {
    return page.getByText(new RegExp(definition.text, "i")).first();
  }
  if (definition.css) {
    return page.locator(definition.css).first();
  }
  return null;
}

async function settle(page) {
  await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});
  await page.waitForTimeout(FIXED_WAIT_MS);
}

async function runStep(page, step, baseOrigin) {
  if (step.action === "scroll-full-page") {
    await page.evaluate(async () => {
      const increment = Math.max(240, Math.floor(window.innerHeight * 0.75));
      for (let y = 0; y < document.documentElement.scrollHeight; y += increment) {
        window.scrollTo(0, y);
        await new Promise((resolve) => setTimeout(resolve, 120));
      }
      window.scrollTo(0, document.documentElement.scrollHeight);
    });
    await settle(page);
    return { result: "completed", observation: "full page scroll completed" };
  }

  const locator = makeLocator(page, step.locator);
  if (!locator || await locator.count() === 0) {
    return { result: "not-found", observation: "flow step not found" };
  }
  const visible = await locator.isVisible().catch(() => false);
  if (!visible) {
    return { result: "not-visible", observation: "flow step element exists but is not visible" };
  }
  const box = await locator.boundingBox().catch(() => null);
  const rawElementText = (await locator.innerText().catch(() => "")).trim();
  const boundedElementText = boundedText(rawElementText, ELEMENT_TEXT_MAX_CHARS);
  const elementProjection = {
    elementText: boundedElementText.text,
    elementTextTruncated: boundedElementText.truncated,
  };

  if (step.action === "observe") {
    return {
      result: "observed",
      observation: "flow step element is visible",
      ...elementProjection,
      box,
    };
  }

  if (step.action === "click") {
    const href = await locator.getAttribute("href").catch(() => null);
    if (href) {
      const destination = new URL(href, page.url());
      if (destination.origin !== baseOrigin) {
        return {
          result: "outbound-not-followed",
          observation: "outbound link was detected and not followed",
          href: destination.href,
          ...elementProjection,
          box,
        };
      }
    }
    await locator.click({ timeout: 5_000 });
    await settle(page);
    return {
      result: "clicked",
      observation: "flow step element was clicked",
      href,
      ...elementProjection,
      box,
      resultingUrl: page.url(),
    };
  }

  return { result: "unsupported", observation: `unsupported action: ${step.action}` };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const baseUrl = new URL(args["base-url"]);
  const flowDocument = JSON.parse(await readFile(args.flows, "utf8"));
  if (!Array.isArray(flowDocument.flows)) {
    throw new Error("flows.json must contain a flows array");
  }
  await mkdir(args.out, { recursive: true });

  const manifest = {
    generatedAt: new Date().toISOString(),
    baseUrl: baseUrl.href,
    viewports: VIEWPORTS,
    files: {},
    steps: [],
  };
  const consoleCollector = createConsoleCollector();
  let sequence = 1;
  let captureFailures = 0;
  const browser = await chromium.launch({ headless: true });

  try {
    for (const viewport of VIEWPORTS) {
      for (const flow of flowDocument.flows) {
        const context = await browser.newContext({
          viewport: { width: viewport.width, height: viewport.height },
        });
        let activeStep = "navigation";
        await context.route("**/*", async (route) => {
          const request = route.request();
          if (request.resourceType() === "document") {
            const requested = new URL(request.url());
            if (requested.origin !== baseUrl.origin) {
              consoleCollector.add({
                flow: flow.id,
                step: activeStep,
                viewport: viewport.id,
                type: "outbound-navigation-blocked",
                text: requested.href,
              });
              await route.abort();
              return;
            }
          }
          await route.continue();
        });
        const page = await context.newPage();
        context.on("page", (openedPage) => {
          if (openedPage === page) {
            return;
          }
          consoleCollector.add({
            flow: flow.id,
            step: activeStep,
            viewport: viewport.id,
            type: "unexpected-popup",
            text: openedPage.url(),
          });
          void openedPage.close().catch(() => {});
        });
        page.on("console", (message) => {
          if (message.type() === "error") {
            consoleCollector.add({
              flow: flow.id,
              step: activeStep,
              viewport: viewport.id,
              type: "console",
              text: message.text(),
              location: message.location(),
            });
          }
        });
        page.on("pageerror", (error) => {
          consoleCollector.add({
            flow: flow.id,
            step: activeStep,
            viewport: viewport.id,
            type: "pageerror",
            text: error.message,
          });
        });
        try {
          await page.goto(baseUrl.href, { waitUntil: "networkidle", timeout: 30_000 });
          await page.waitForTimeout(FIXED_WAIT_MS);
          for (const step of flow.steps) {
            activeStep = step.id;
            let outcome;
            try {
              outcome = await runStep(page, step, baseUrl.origin);
            } catch (error) {
              captureFailures += 1;
              outcome = {
                result: "step-error",
                observation: "flow step raised a mechanical capture error",
                error: error.message,
              };
            }

            const number = String(sequence).padStart(2, "0");
            const stem = `${number}-${safeName(flow.id)}-${viewport.id}`;
            const screenshotName = `${stem}.png`;
            const textName = `${stem}.txt`;
            await page.screenshot({
              path: path.join(args.out, screenshotName),
              fullPage: true,
            });
            const visibleText = await page.locator("body").innerText().catch(() => "");
            await writeFile(path.join(args.out, textName), visibleText, "utf8");

            const screenshotRef = evidenceRef(args.out, screenshotName);
            const textRef = evidenceRef(args.out, textName);
            const mapping = {
              flow: flow.id,
              step: step.id,
              viewport: viewport.id,
              outcome,
              url: page.url(),
            };
            manifest.files[screenshotRef] = { ...mapping, type: "screenshot" };
            manifest.files[textRef] = { ...mapping, type: "visible-text" };
            manifest.steps.push({ ...mapping, files: [screenshotRef, textRef] });
            sequence += 1;
          }
        } catch (error) {
          captureFailures += 1;
          manifest.steps.push({
            flow: flow.id,
            step: activeStep,
            viewport: viewport.id,
            result: "flow-error",
            observation: "flow navigation or capture failed",
            error: error.message,
          });
        } finally {
          await context.close();
        }
      }
    }
  } finally {
    await browser.close();
  }

  const consoleSnapshot = consoleCollector.snapshot();
  const consoleName = "console-errors.jsonl";
  const consoleRecords = [...consoleSnapshot.entries];
  if (consoleSnapshot.status.dropped > 0) {
    consoleRecords.push({
      type: "console-errors-truncated",
      text: `${consoleSnapshot.status.dropped} additional console records were omitted`,
      ...consoleSnapshot.status,
    });
  }
  const consoleBody = consoleRecords.map((entry) => JSON.stringify(entry)).join("\n");
  await writeFile(
    path.join(args.out, consoleName),
    consoleBody.length > 0 ? `${consoleBody}\n` : "",
    "utf8",
  );
  manifest.files[evidenceRef(args.out, consoleName)] = {
    type: "console-errors",
    flow: "*",
    step: "*",
    mappings: consoleSnapshot.mappings,
    truncation: consoleSnapshot.status,
  };
  manifest.consoleErrors = consoleSnapshot.status;
  await writeFile(
    path.join(args.out, "manifest.json"),
    `${JSON.stringify(manifest, null, 2)}\n`,
    "utf8",
  );
  if (captureFailures > 0) {
    throw new Error(`${captureFailures} flow capture(s) failed`);
  }
}

main().catch((error) => {
  process.stderr.write(`metsuke capture: ${error.stack ?? error.message}\n`);
  process.exitCode = 1;
});
