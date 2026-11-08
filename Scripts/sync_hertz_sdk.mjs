#!/usr/bin/env node
// 把 NetSDKstudy 里的 Dart SDK 同步到本仓库 packages/hertz_sdk。
//
// 为什么要有这一步：
//   pubspec 里如果直接写 `path: ../../NetSDKstudy/sdk/dart`，那是**跨仓库相对路径**，
//   CI（GitHub Actions）上没有 E:\NetSDKstudy，`pub get` 会失败。
//   所以本仓库持有一份 vendored 副本；SDK 的**主副本仍在 NetSDKstudy/sdk/dart**，
//   改完 SDK 跑一下这个脚本即可。
//
// 用法：
//   node Scripts/sync_hertz_sdk.mjs
//   HERTZ_SDK_SRC=D:/somewhere/sdk/dart node Scripts/sync_hertz_sdk.mjs

import { cpSync, existsSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const src = resolve(
  process.env.HERTZ_SDK_SRC ?? join(root, '..', '..', 'NetSDKstudy', 'sdk', 'dart'),
);
const dst = join(root, 'packages', 'hertz_sdk');

if (!existsSync(join(src, 'pubspec.yaml'))) {
  console.error(`找不到 SDK 源目录: ${src}`);
  console.error('用 HERTZ_SDK_SRC 指定，例如：');
  console.error('  HERTZ_SDK_SRC=E:/NetSDKstudy/sdk/dart node Scripts/sync_hertz_sdk.mjs');
  process.exit(1);
}

// 只同步源码与文档。pubspec.lock / .dart_tool / build 是本地产物，
// 带过来只会在两边各自解析时打架。
const SKIP = new Set(['pubspec.lock', '.dart_tool', '.packages', 'build']);

rmSync(dst, { recursive: true, force: true });
mkdirSync(dst, { recursive: true });
cpSync(src, dst, {
  recursive: true,
  filter: (p) => !SKIP.has(p.split(/[\\/]/).pop()),
});

console.log(`已同步 ${src}`);
console.log(`     -> ${dst}`);
