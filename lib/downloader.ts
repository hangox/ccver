#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  chmod,
  link,
  mkdir,
  open,
  readFile,
  readdir,
  rename,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import { createReadStream } from "node:fs";
import { basename, join } from "node:path";
import { spawnSync } from "node:child_process";

const EXIT_DATA = 65;
const EXIT_CONFLICT = 73;
const EXIT_FALLBACK = 75;
const EXPECTED_IDENTIFIER = process.env.CCVER_CODESIGN_IDENTIFIER ?? "com.anthropic.claude-code";
const EXPECTED_TEAM_ID = process.env.CCVER_CODESIGN_TEAM_ID ?? "Q6L2SF6YDW";

class CcverError extends Error {
  readonly exitCode: number;

  constructor(message: string, exitCode: number) {
    super(message);
    this.exitCode = exitCode;
  }
}

const failClosed = (message: string): never => {
  throw new CcverError(message, EXIT_DATA);
};
const conflict = (message: string): never => {
  throw new CcverError(message, EXIT_CONFLICT);
};
const fallback = (message: string): never => {
  throw new CcverError(message, EXIT_FALLBACK);
};

type ManifestEntry = { binary: string; checksum: string; size: number };
type ResumeState = {
  schemaVersion: 1;
  version: string;
  platform: string;
  url: string;
  size: number;
  checksum: string;
  etag: string;
  chunkSize: number;
  completed: number[];
};

const target = process.argv[2] ?? "";
const releasesUrl = process.env.CCVER_RELEASES_URL ?? "https://downloads.claude.ai/claude-code-releases";
const cacheHome = process.env.CCVER_CACHE_HOME ?? join(process.env.HOME ?? "", ".cache");
const versionsDir = process.env.CCVER_VERSIONS_DIR ?? join(process.env.HOME ?? "", ".local/share/claude/versions");
const downloadsDir = process.env.CCVER_DOWNLOADS_DIR ?? join(cacheHome, "ccver/downloads");
const assemblyDir = process.env.CCVER_ASSEMBLY_DIR ?? join(versionsDir, ".ccver-staging");
const workerCount = boundedInteger(process.env.CCVER_DOWNLOAD_WORKERS, 6, 1, 8);
const chunkSize = boundedInteger(process.env.CCVER_CHUNK_SIZE, 16 * 1024 * 1024, 64 * 1024, 64 * 1024 * 1024);
const requestTimeoutMs = boundedInteger(process.env.CCVER_REQUEST_TIMEOUT_MS, 120_000, 1_000, 300_000);
const isTTY = Boolean(process.stderr.isTTY) && process.env.TERM !== "dumb";
const operationAbort = new AbortController();
let cancellationCode = 0;
let progress: Progress | undefined;
let activeDownloadDirectory: string | undefined;

function boundedInteger(value: string | undefined, defaultValue: number, min: number, max: number): number {
  if (value === undefined || value === "") return defaultValue;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min || parsed > max) failClosed(`配置值超出范围: ${value}`);
  return parsed;
}

function platformName(): string {
  if (process.platform === "darwin" && process.arch === "arm64") return "darwin-arm64";
  if (process.platform === "darwin" && process.arch === "x64") return "darwin-x64";
  fallback(`当前平台没有自研安装实现: ${process.platform}-${process.arch}`);
}

function isTransientStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

function isNetworkError(error: unknown): boolean {
  if (error instanceof CcverError) return false;
  if (error instanceof DOMException && error.name === "AbortError") return cancellationCode === 0;
  if (!(error instanceof Error)) return false;
  if (error.name === "TimeoutError") return true;
  const cause = (error as Error & { cause?: { code?: string; message?: string } }).cause;
  const code = cause?.code ?? "";
  const message = `${error.message} ${cause?.message ?? ""}`;
  return /^(ECONN|ENET|EHOST|EAI_AGAIN|ETIMEDOUT|UND_ERR_CONNECT_TIMEOUT|UND_ERR_SOCKET)/.test(code)
    || /socket|network|timed out|connection refused|connection reset|dns/i.test(message);
}

function throwIfCancelled(): void {
  if (cancellationCode !== 0) throw new CcverError("安装已取消", cancellationCode);
}

function combinedSignal(): AbortSignal {
  return AbortSignal.any([operationAbort.signal, AbortSignal.timeout(requestTimeoutMs)]);
}

async function fetchChecked(url: string, init: RequestInit, context: string): Promise<Response> {
  try {
    return await fetch(url, { ...init, signal: combinedSignal(), redirect: "error" });
  } catch (error) {
    if (cancellationCode !== 0) throw error;
    if (isNetworkError(error)) fallback(`${context}发生网络错误: ${error instanceof Error ? error.message : String(error)}`);
    throw error;
  }
}

function safeBinaryName(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9._+-]+$/.test(value) || basename(value) !== value || value === "." || value.includes("..")) {
    failClosed("manifest binary 字段不安全");
  }
  return value;
}

async function fetchManifest(platform: string): Promise<ManifestEntry> {
  const url = `${releasesUrl}/${target}/manifest.json`;
  const response = await fetchChecked(url, {}, "获取 manifest 时");
  if (!response.ok) {
    if (isTransientStatus(response.status)) fallback(`manifest 暂时不可用: HTTP ${response.status}`);
    failClosed(`manifest 请求失败: HTTP ${response.status}`);
  }
  let manifest: any;
  try {
    manifest = await response.json();
  } catch {
    failClosed("manifest 不是合法 JSON");
  }
  if (manifest?.version !== target) failClosed(`manifest 版本不匹配: ${String(manifest?.version)}`);
  const raw = manifest?.platforms?.[platform];
  if (!raw) failClosed(`manifest 不包含平台 ${platform}`);
  const binary = safeBinaryName(raw.binary);
  if (!Number.isSafeInteger(raw.size) || raw.size <= 0) failClosed("manifest size 字段不合法");
  if (typeof raw.checksum !== "string" || !/^[0-9a-f]{64}$/.test(raw.checksum)) failClosed("manifest checksum 字段不合法");
  return { binary, size: raw.size, checksum: raw.checksum };
}

async function probeRange(url: string, size: number): Promise<string> {
  const response = await fetchChecked(url, { headers: { Range: "bytes=0-0" } }, "探测 Range 时");
  if (response.status === 200) fallback("官方 CDN 未响应 Range，切换官方安装器");
  if (response.status !== 206) {
    if (isTransientStatus(response.status)) fallback(`Range 探测暂时失败: HTTP ${response.status}`);
    failClosed(`Range 探测协议异常: HTTP ${response.status}`);
  }
  const contentRange = response.headers.get("content-range") ?? "";
  if (contentRange !== `bytes 0-0/${size}`) failClosed(`Range 探测 Content-Range 不匹配: ${contentRange}`);
  const etag = response.headers.get("etag");
  if (!etag) failClosed("Range 响应缺少 ETag，拒绝无身份分块下载");
  const body = await response.arrayBuffer();
  throwIfCancelled();
  if (body.byteLength !== 1) failClosed(`Range 探测长度异常: ${body.byteLength}`);
  return etag;
}

function identityFor(state: Omit<ResumeState, "schemaVersion" | "completed">): string {
  return createHash("sha256").update(JSON.stringify(state)).digest("hex").slice(0, 24);
}

async function atomicWriteJson(path: string, value: unknown): Promise<void> {
  const temporary = `${path}.tmp.${process.pid}`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
}

async function loadResumeState(path: string, expected: ResumeState): Promise<ResumeState> {
  try {
    const parsed = JSON.parse(await readFile(path, "utf8")) as ResumeState;
    const comparable = ["schemaVersion", "version", "platform", "url", "size", "checksum", "etag", "chunkSize"] as const;
    for (const key of comparable) {
      if (parsed[key] !== expected[key]) failClosed(`断点状态身份不匹配: ${key}`);
    }
    if (!Array.isArray(parsed.completed) || parsed.completed.some((item) => !Number.isSafeInteger(item) || item < 0)) {
      failClosed("断点状态 completed 字段不合法");
    }
    parsed.completed = [...new Set(parsed.completed)].sort((a, b) => a - b);
    return parsed;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return expected;
    if (error instanceof CcverError) throw error;
    failClosed(`断点状态损坏: ${error instanceof Error ? error.message : String(error)}`);
  }
}

async function verifyCompletedChunks(directory: string, state: ResumeState): Promise<void> {
  const count = Math.ceil(state.size / state.chunkSize);
  for (const index of state.completed) {
    if (index >= count) failClosed(`断点状态包含越界分块: ${index}`);
    const expected = Math.min(state.chunkSize, state.size - index * state.chunkSize);
    let actual: number;
    try {
      actual = (await stat(join(directory, `chunk-${index}`))).size;
    } catch {
      failClosed(`断点状态引用缺失分块: ${index}`);
    }
    if (actual !== expected) failClosed(`已完成分块长度异常: ${index}`);
  }
}

class Progress {
  private readonly total: number;
  private interval?: NodeJS.Timeout;
  private readonly active = new Map<number, number>();
  private completedBytes = 0;
  private previousBytes = 0;
  private previousTime = Date.now();
  private speed = 0;
  private frame = 0;
  private phase = "准备下载";
  private activeDisplay = false;

  constructor(total: number, initialBytes: number) {
    this.total = total;
    this.completedBytes = initialBytes;
  }

  begin(): void {
    if (!isTTY) return;
    this.activeDisplay = true;
    process.stderr.write("[?25l");
    this.draw();
    this.interval = setInterval(() => this.draw(), 1000);
  }

  setPhase(value: string): void {
    this.phase = value;
    if (!isTTY) process.stderr.write(`${value}\n`);
  }

  setActive(index: number, bytes: number): void {
    this.active.set(index, bytes);
  }

  complete(index: number, bytes: number): void {
    this.active.delete(index);
    this.completedBytes += bytes;
  }

  finish(message?: string): void {
    if (this.interval) clearInterval(this.interval);
    this.interval = undefined;
    if (this.activeDisplay) {
      process.stderr.write("\r[2K[?25h");
      if (message) process.stderr.write(`${message}\n`);
      else process.stderr.write("\n");
    } else if (message) {
      process.stderr.write(`${message}\n`);
    }
    this.activeDisplay = false;
  }

  private draw(): void {
    if (!this.activeDisplay) return;
    const bytes = Math.min(this.total, this.completedBytes + [...this.active.values()].reduce((sum, value) => sum + value, 0));
    const now = Date.now();
    const elapsedSeconds = Math.max(0.001, (now - this.previousTime) / 1000);
    this.speed = Math.max(0, (bytes - this.previousBytes) / elapsedSeconds);
    this.previousBytes = bytes;
    this.previousTime = now;
    const percent = Math.floor((bytes * 100) / this.total);
    const width = 20;
    const filled = Math.floor((percent * width) / 100);
    const frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    const line = `${frames[this.frame++ % frames.length]} [${"=".repeat(filled)}${"-".repeat(width - filled)}] ${String(percent).padStart(3)}%  ${humanBytes(bytes)}/${humanBytes(this.total)}  ${humanBytes(this.speed)}/s  ${this.phase}`;
    process.stderr.write(`\r[2K${line}`);
  }
}

function humanBytes(value: number): string {
  if (value >= 1024 ** 3) return `${(value / 1024 ** 3).toFixed(1)} GiB`;
  if (value >= 1024 ** 2) return `${(value / 1024 ** 2).toFixed(1)} MiB`;
  if (value >= 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${Math.floor(value)} B`;
}

async function downloadChunks(url: string, directory: string, state: ResumeState, statePath: string): Promise<void> {
  activeDownloadDirectory = directory;
  const totalChunks = Math.ceil(state.size / state.chunkSize);
  const completed = new Set(state.completed);
  const missing = Array.from({ length: totalChunks }, (_, index) => index).filter((index) => !completed.has(index));
  let completedBytes = state.completed.reduce((sum, index) => sum + Math.min(state.chunkSize, state.size - index * state.chunkSize), 0);
  progress = new Progress(state.size, completedBytes);
  progress.setPhase(missing.length === totalChunks ? "并行下载" : `断点恢复 ${completed.size}/${totalChunks}`);
  progress.begin();

  let next = 0;
  let stateWrite: Promise<void> = Promise.resolve();
  let firstError: unknown;
  const workersAbort = new AbortController();
  const onOperationAbort = () => workersAbort.abort(operationAbort.signal.reason);
  operationAbort.signal.addEventListener("abort", onOperationAbort, { once: true });

  async function saveCompletion(index: number): Promise<void> {
    completed.add(index);
    state.completed = [...completed].sort((a, b) => a - b);
    stateWrite = stateWrite.then(() => atomicWriteJson(statePath, state));
    await stateWrite;
  }

  async function worker(): Promise<void> {
    while (!workersAbort.signal.aborted) {
      const position = next++;
      if (position >= missing.length) return;
      const index = missing[position];
      const start = index * state.chunkSize;
      const end = Math.min(state.size - 1, start + state.chunkSize - 1);
      const expectedLength = end - start + 1;
      const temporary = join(directory, `chunk-${index}.tmp.${process.pid}`);
      const final = join(directory, `chunk-${index}`);
      let file;
      try {
        const response = await fetch(url, {
          headers: { Range: `bytes=${start}-${end}`, "If-Range": state.etag },
          signal: AbortSignal.any([workersAbort.signal, AbortSignal.timeout(requestTimeoutMs)]),
          redirect: "error",
        });
        if (response.status === 200) failClosed(`分块 ${index} 返回 200，远端身份可能已变化`);
        if (response.status !== 206) {
          if (isTransientStatus(response.status)) fallback(`分块 ${index} 暂时失败: HTTP ${response.status}`);
          failClosed(`分块 ${index} 协议异常: HTTP ${response.status}`);
        }
        const expectedRange = `bytes ${start}-${end}/${state.size}`;
        if (response.headers.get("content-range") !== expectedRange) failClosed(`分块 ${index} Content-Range 不匹配`);
        if (response.headers.get("etag") !== state.etag) failClosed(`分块 ${index} ETag 漂移`);
        if (!response.body) fallback(`分块 ${index} 没有响应体`);

        file = await open(temporary, "wx", 0o600);
        const reader = response.body.getReader();
        let received = 0;
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          if (!value) continue;
          received += value.byteLength;
          if (received > expectedLength) failClosed(`分块 ${index} 超过预期长度`);
          await file.write(value);
          progress?.setActive(index, received);
        }
        await file.sync();
        await file.close();
        file = undefined;
        if (received !== expectedLength) failClosed(`分块 ${index} 长度不匹配: ${received}/${expectedLength}`);
        await rename(temporary, final);
        await saveCompletion(index);
        progress?.complete(index, expectedLength);
      } catch (error) {
        try { await file?.close(); } catch {}
        try { await unlink(temporary); } catch {}
        if (!firstError && !(workersAbort.signal.aborted && error instanceof DOMException && error.name === "AbortError")) firstError = error;
        workersAbort.abort(error);
        return;
      }
    }
  }

  await Promise.all(Array.from({ length: Math.min(workerCount, Math.max(1, missing.length)) }, () => worker()));
  operationAbort.signal.removeEventListener("abort", onOperationAbort);
  await stateWrite;
  if (cancellationCode !== 0) throw new CcverError("安装已取消", cancellationCode);
  if (firstError) {
    if (firstError instanceof CcverError) throw firstError;
    if (isNetworkError(firstError)) fallback(`分块下载发生网络错误: ${firstError instanceof Error ? firstError.message : String(firstError)}`);
    throw firstError;
  }
  if (completed.size !== totalChunks) fallback("分块下载未完整完成");
  progress.setPhase("下载完成");
}

async function assemble(directory: string, state: ResumeState): Promise<string> {
  await mkdir(assemblyDir, { recursive: true });
  const path = join(assemblyDir, `${target}.${process.pid}.${Date.now()}`);
  const output = await open(path, "wx", 0o600);
  try {
    const totalChunks = Math.ceil(state.size / state.chunkSize);
    for (let index = 0; index < totalChunks; index++) {
      for await (const data of createReadStream(join(directory, `chunk-${index}`))) await output.write(data as Buffer);
    }
    await output.sync();
  } finally {
    await output.close();
  }
  const actual = (await stat(path)).size;
  if (actual !== state.size) {
    try { await unlink(path); } catch {}
    failClosed(`合并文件大小不匹配: ${actual}/${state.size}`);
  }
  return path;
}

async function sha256File(path: string): Promise<string> {
  const hash = createHash("sha256");
  for await (const data of createReadStream(path)) hash.update(data as Buffer);
  return hash.digest("hex");
}

function verifySignature(path: string): void {
  if (process.env.CCVER_TEST_CODESIGN === "pass") return;
  if (process.env.CCVER_TEST_CODESIGN === "fail") failClosed("代码签名验证失败: 测试注入");
  const verify = spawnSync("codesign", ["--verify", "--strict", "--verbose=2", path], { encoding: "utf8" });
  if (verify.error && (verify.error as NodeJS.ErrnoException).code === "ENOENT") fallback("缺少 codesign，切换官方安装器");
  if (verify.status !== 0) failClosed(`代码签名验证失败: ${(verify.stderr || verify.stdout).trim()}`);
  const details = spawnSync("codesign", ["-d", "--verbose=4", path], { encoding: "utf8" });
  if (details.status !== 0) failClosed(`无法读取代码签名详情: ${(details.stderr || details.stdout).trim()}`);
  const output = `${details.stdout}\n${details.stderr}`;
  const identifier = /^Identifier=(.+)$/m.exec(output)?.[1]?.trim();
  const teamId = /^TeamIdentifier=(.+)$/m.exec(output)?.[1]?.trim();
  if (identifier !== EXPECTED_IDENTIFIER) failClosed(`签名 Identifier 不匹配: ${identifier ?? "缺失"}`);
  if (teamId !== EXPECTED_TEAM_ID) failClosed(`签名 TeamIdentifier 不匹配: ${teamId ?? "缺失"}`);
}

async function verifyBinary(path: string, expectedSize: number, expectedChecksum: string): Promise<void> {
  const metadata = await stat(path);
  if (metadata.size !== expectedSize) failClosed(`二进制大小不匹配: ${metadata.size}/${expectedSize}`);
  const checksum = await sha256File(path);
  if (checksum !== expectedChecksum) failClosed(`SHA-256 不匹配: ${checksum}`);
  verifySignature(path);
}

async function atomicCommit(staging: string, final: string, state: ResumeState): Promise<void> {
  await chmod(staging, 0o755);
  try {
    await link(staging, final);
    await unlink(staging);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    try {
      await verifyBinary(final, state.size, state.checksum);
    } catch (verificationError) {
      conflict(`最终版本路径冲突且内容不可信: ${verificationError instanceof Error ? verificationError.message : String(verificationError)}`);
    }
    await unlink(staging).catch(() => {});
  }
}

async function cleanupOwnTemporaries(directory?: string): Promise<void> {
  if (!directory) return;
  try {
    const entries = await readdir(directory);
    await Promise.all(entries.filter((name) => name.endsWith(`.tmp.${process.pid}`)).map((name) => unlink(join(directory, name)).catch(() => {})));
  } catch {}
}

function installSignalHandlers(): void {
  const handlers: Array<[NodeJS.Signals, number]> = [["SIGINT", 130], ["SIGTERM", 143], ["SIGHUP", 129]];
  for (const [signal, code] of handlers) {
    process.on(signal, () => {
      if (cancellationCode !== 0) return;
      cancellationCode = code;
      progress?.finish("安装已取消，已验证分块将保留供下次恢复");
      operationAbort.abort(new Error(signal));
    });
  }
}

async function main(): Promise<void> {
  if (!/^[A-Za-z0-9._+-]+$/.test(target) || target.includes("..") || target === ".") failClosed(`目标版本不安全: ${target}`);
  installSignalHandlers();
  const platform = platformName();
  progress?.setPhase("读取 manifest");
  const manifest = await fetchManifest(platform);
  const binaryUrl = `${releasesUrl}/${target}/${platform}/${manifest.binary}`;
  const etag = await probeRange(binaryUrl, manifest.size);
  const identityBase = { version: target, platform, url: binaryUrl, size: manifest.size, checksum: manifest.checksum, etag, chunkSize };
  const identity = identityFor(identityBase);
  const directory = join(downloadsDir, target, platform, identity);
  activeDownloadDirectory = directory;
  await mkdir(directory, { recursive: true });
  const statePath = join(directory, "state.json");
  const initial: ResumeState = { schemaVersion: 1, ...identityBase, completed: [] };
  const state = await loadResumeState(statePath, initial);
  await verifyCompletedChunks(directory, state);
  throwIfCancelled();
  await atomicWriteJson(statePath, state);
  await downloadChunks(binaryUrl, directory, state, statePath);
  throwIfCancelled();
  progress?.setPhase("合并并验证");
  const staging = await assemble(directory, state);
  try {
    throwIfCancelled();
    await verifyBinary(staging, state.size, state.checksum);
    throwIfCancelled();
    progress?.setPhase("原子安装");
    await mkdir(versionsDir, { recursive: true });
    await atomicCommit(staging, join(versionsDir, target), state);
  } catch (error) {
    try { await unlink(staging); } catch {}
    throw error;
  }
  progress?.finish(`已安全安装 ${target}`);
}

try {
  await main();
} catch (error) {
  progress?.finish();
  await cleanupOwnTemporaries(activeDownloadDirectory);
  if (cancellationCode !== 0) process.exit(cancellationCode);
  if (error instanceof CcverError) {
    process.stderr.write(`ccver: ${error.message}\n`);
    process.exit(error.exitCode);
  }
  if (isNetworkError(error)) {
    process.stderr.write(`ccver: 网络错误，可切换官方安装器: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(EXIT_FALLBACK);
  }
  process.stderr.write(`ccver: 自研安装器内部错误: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
  process.exit(70);
}
