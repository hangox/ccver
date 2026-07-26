#!/usr/bin/env node

import { execute } from "../lib/downloader.ts";

const mode = process.env.CCVER_TEST_SIGNATURE_MODE ?? "pass";
process.exitCode = await execute({
  signatureError: () => mode === "fail" ? "代码签名验证失败: 测试注入" : undefined,
});
