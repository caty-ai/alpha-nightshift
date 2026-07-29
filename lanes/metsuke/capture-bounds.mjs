export const ELEMENT_TEXT_MAX_CHARS = 500;
export const CONSOLE_ERROR_MAX_ENTRIES = 200;
export const CONSOLE_ERROR_TEXT_MAX_CHARS = 1_000;
export const CONSOLE_ERROR_MAPPING_MAX_ENTRIES = 200;
export const CONSOLE_ERROR_LOCATION_MAX_CHARS = 500;

export function boundedText(value, limit) {
  const text = String(value ?? "");
  if (text.length <= limit) {
    return { text, truncated: false };
  }
  return {
    text: text.slice(0, limit),
    truncated: true,
  };
}

export function createConsoleCollector() {
  const entries = [];
  let observed = 0;
  let textTruncations = 0;
  let locationTruncations = 0;

  return {
    add(entry) {
      observed += 1;
      if (entries.length >= CONSOLE_ERROR_MAX_ENTRIES) {
        return;
      }
      const bounded = boundedText(entry.text, CONSOLE_ERROR_TEXT_MAX_CHARS);
      if (bounded.truncated) {
        textTruncations += 1;
      }
      let location;
      let locationUrlTruncated = false;
      if (entry.location && typeof entry.location === "object") {
        const boundedUrl = boundedText(
          entry.location.url,
          CONSOLE_ERROR_LOCATION_MAX_CHARS,
        );
        location = {
          url: boundedUrl.text,
          lineNumber: Number(entry.location.lineNumber) || 0,
          columnNumber: Number(entry.location.columnNumber) || 0,
        };
        locationUrlTruncated = boundedUrl.truncated;
        if (locationUrlTruncated) {
          locationTruncations += 1;
        }
      }
      entries.push({
        ...entry,
        text: bounded.text,
        textTruncated: bounded.truncated,
        ...(location ? { location, locationUrlTruncated } : {}),
      });
    },
    snapshot() {
      const mappings = entries
        .slice(0, CONSOLE_ERROR_MAPPING_MAX_ENTRIES)
        .map(({ flow, step, viewport }) => ({ flow, step, viewport }));
      return {
        entries: [...entries],
        mappings,
        status: {
          observed,
          captured: entries.length,
          dropped: observed - entries.length,
          textTruncations,
          locationTruncations,
          entryLimit: CONSOLE_ERROR_MAX_ENTRIES,
          textLimit: CONSOLE_ERROR_TEXT_MAX_CHARS,
          locationLimit: CONSOLE_ERROR_LOCATION_MAX_CHARS,
          mappingLimit: CONSOLE_ERROR_MAPPING_MAX_ENTRIES,
          mappingsDropped: observed - mappings.length,
          mappingsTruncated: observed > mappings.length,
        },
      };
    },
  };
}
