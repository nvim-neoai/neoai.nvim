#!/usr/bin/env node

/**
 * Headless AI backend for NeoAI.
 *
 * Usage:
 *   node backend/ai_backend.ts <url> <apiKeyHeader> <apiKeyValue>
 *
 * Reads JSON payload from stdin, forwards it to the provider, and mirrors the
 * provider response to stdout. For SSE streams, raw chunks are forwarded as-is.
 * For non-stream responses, the body is printed as text.
 *
 * Always appends a status trailer line:
 *   HTTPSTATUS:<code>
 */

const [,, url, apiKeyHeader, apiKeyValue] = process.argv;

if (!url) {
  process.stderr.write("Missing URL argument\n");
  process.exit(2);
}

const stdinChunks = [];

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => stdinChunks.push(chunk));
process.stdin.on("error", (err) => {
  process.stderr.write(`stdin error: ${String(err)}\n`);
  process.exit(1);
});

process.stdin.on("end", async () => {
  const payload = stdinChunks.join("");

  const headers = {
    "Content-Type": "application/json",
  };

  if (apiKeyHeader && apiKeyValue) {
    headers[apiKeyHeader] = apiKeyValue;
  }

  try {
    const response = await fetch(url, {
      method: "POST",
      headers,
      body: payload,
      redirect: "follow",
    });

    const contentType = (response.headers.get("content-type") || "").toLowerCase();
    const isSse = contentType.includes("text/event-stream");

    if (isSse && response.body) {
      const decoder = new TextDecoder("utf-8");
      const reader = response.body.getReader();

      while (true) {
        const { value, done } = await reader.read();
        if (done) {
          break;
        }
        if (value) {
          process.stdout.write(decoder.decode(value, { stream: true }));
        }
      }

      process.stdout.write(decoder.decode());
      process.stdout.write(`\nHTTPSTATUS:${response.status}\n`);
      return;
    }

    const bodyText = await response.text();
    if (bodyText) {
      process.stdout.write(bodyText);
      if (!bodyText.endsWith("\n")) {
        process.stdout.write("\n");
      }
    }
    process.stdout.write(`HTTPSTATUS:${response.status}\n`);
  } catch (err) {
    process.stderr.write(`request error: ${String(err)}\n`);
    process.exit(1);
  }
});

process.stdin.resume();
