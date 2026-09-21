#!/usr/bin/env bun

import { mkdirSync, writeFileSync } from "node:fs";
import { basename, dirname, resolve } from "node:path";

type Options = Record<string, string>;

const selectors = [
  "cleans an acquired startup owner",
  "halt wakes idle intake in every queue strategy and batch mode",
  "runs adapter shutdown once for concurrent and repeated stop calls",
  "stops the master when the shutdown caller is cancelled during drain",
  "StopAllOnFailure delivers exhausted finalization exactly once",
  "propagates ticker failure while input remains idle",
  "propagates a keyed worker failure without waiting for infinite input",
  "restores interruptibility inside a supervised child",
];

function parseArgs(args: string[]): Options {
  const options: Options = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error(`invalid arguments near ${key ?? "end"}`);
    }
    options[key] = value;
  }
  return options;
}

function requireOption(options: Options, key: string): string {
  const value = options[key];
  if (!value) throw new Error(`missing ${key}`);
  return value;
}

function positiveInteger(value: string, label: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 1) throw new Error(`${label} must be a positive integer`);
  return parsed;
}

function capabilitiesFor(rts: string): number {
  const match = /^N([1-9][0-9]*)$/.exec(rts);
  if (!match) throw new Error(`RTS cell must have the form N<number>, got ${rts}`);
  return Number(match[1]);
}

if (import.meta.main) {
  try {
    const options = parseArgs(Bun.argv.slice(2));
    const executable = resolve(requireOption(options, "--executable"));
    const output = resolve(requireOption(options, "--output"));
    const repetitions = positiveInteger(options["--repetitions"] ?? "100", "--repetitions");
    const seedStart = positiveInteger(options["--seed-start"] ?? "1", "--seed-start");
    const rtsCells = requireOption(options, "--rts-cells").split(",");
    rtsCells.forEach(capabilitiesFor);
    const results: Array<Record<string, unknown>> = [];
    let status = "pass";
    mkdirSync(dirname(output), { recursive: true });

    for (const rts of rtsCells) {
      for (const selector of selectors) {
        for (let offset = 0; offset < repetitions; offset += 1) {
          const seed = seedStart + offset;
          const started = performance.now();
          const process = Bun.spawnSync([
            executable,
            "--ignore-dot-hspec",
            "--fail-on=empty",
            "--match",
            selector,
            "--seed",
            String(seed),
            "--format=silent",
            "+RTS",
            `-${rts}`,
            "-RTS",
          ], {
            stdout: "pipe",
            stderr: "pipe",
          });
          const exitCode = process.exitCode;
          const result: Record<string, unknown> = {
            selector,
            rtsFlags: `-${rts}`,
            capabilities: capabilitiesFor(rts),
            seed,
            exitCode,
            elapsedMilliseconds: performance.now() - started,
          };
          if (exitCode !== 0) {
            status = "fail";
            result.stdout = process.stdout.toString();
            result.stderr = process.stderr.toString();
          }
          results.push(result);
          if (exitCode !== 0) break;
        }
        writeFileSync(output, `${JSON.stringify({
          schemaVersion: 1,
          status,
          executable: basename(executable),
          sourceSha: requireOption(options, "--source-sha"),
          solverPlanHash: requireOption(options, "--solver-plan-hash"),
          repetitionsPerSelector: repetitions,
          seedRange: [seedStart, seedStart + repetitions - 1],
          rtsCells: rtsCells.map((rts) => `-${rts}`),
          selectors,
          expectedRunCount: selectors.length * rtsCells.length * repetitions,
          completedRunCount: results.length,
          results,
        }, null, 2)}\n`);
        if (status === "fail") break;
      }
      if (status === "fail") break;
    }

    if (status === "pass") {
      process.stdout.write(`passed ${results.length} deterministic schedule repetitions\n`);
    } else {
      process.stderr.write(`schedule repetition failed after ${results.length} runs\n`);
      process.exitCode = 1;
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
