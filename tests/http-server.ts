#!/usr/bin/env node

import { createHash } from "node:crypto";
import { appendFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";

const portFile = process.argv[2];
const eventFile = process.argv[3];
if (!portFile || !eventFile) throw new Error("用法: http-server.ts <port-file> <event-file>");

const size = 512 * 1024;
const data = Buffer.allocUnsafe(size);
for (let index = 0; index < data.length; index++) data[index] = index % 251;
const checksum = createHash("sha256").update(data).digest("hex");
const etag = '"ccver-test-etag"';
let activeRanges = 0;
let maxActiveRanges = 0;

function event(value: string): void {
  appendFileSync(eventFile, `${value}\n`);
}

const server = createServer((request, response) => {
  const match = /^\/([^/]+)\/(manifest\.json|darwin-(?:arm64|x64)\/claude)$/.exec(request.url ?? "");
  if (!match) {
    response.writeHead(404).end();
    return;
  }
  const version = match[1];
  const resource = match[2];
  event(`${version} ${resource} ${request.headers.range ?? "full"}`);

  if (version === "9.9.9") {
    response.writeHead(503).end("temporary");
    return;
  }

  if (resource === "manifest.json") {
    const badManifest = version === "9.9.3";
    const badChecksum = version === "9.9.6";
    const body = JSON.stringify({
      version,
      platforms: {
        "darwin-arm64": { binary: "claude", size, checksum: badManifest ? "bad" : badChecksum ? "0".repeat(64) : checksum },
        "darwin-x64": { binary: "claude", size, checksum: badManifest ? "bad" : badChecksum ? "0".repeat(64) : checksum },
      },
    });
    response.writeHead(200, { "content-type": "application/json", "content-length": Buffer.byteLength(body) });
    response.end(body);
    return;
  }

  const range = request.headers.range;
  if (version === "9.9.2" || !range) {
    response.writeHead(200, { "content-length": data.length, etag });
    response.end(data);
    return;
  }
  const rangeMatch = /^bytes=(\d+)-(\d+)$/.exec(range);
  if (!rangeMatch) {
    response.writeHead(416).end();
    return;
  }
  const start = Number(rangeMatch[1]);
  const end = Math.min(Number(rangeMatch[2]), data.length - 1);
  const chunk = data.subarray(start, end + 1);
  const contentRange = version === "9.9.4" ? `bytes ${start}-${end}/${data.length + 1}` : `bytes ${start}-${end}/${data.length}`;
  const responseEtag = version === "9.9.5" && start > 0
    ? '"changed-etag"'
    : version === "9.9.10"
      ? 'W/"weak-etag"'
      : etag;
  activeRanges++;
  maxActiveRanges = Math.max(maxActiveRanges, activeRanges);
  event(`active=${activeRanges} max=${maxActiveRanges}`);
  response.writeHead(206, {
    "accept-ranges": "bytes",
    "content-range": contentRange,
    "content-length": chunk.length,
    etag: responseEtag,
  });

  const delay = version === "9.9.7" ? 600 : 35;
  setTimeout(() => {
    response.end(chunk);
    activeRanges--;
    event(`complete ${version} ${start}-${end}`);
  }, delay);
});

server.listen(0, "127.0.0.1", () => {
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("无法获取测试端口");
  writeFileSync(portFile, String(address.port));
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
