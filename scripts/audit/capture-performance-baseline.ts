#!/usr/bin/env bun

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

import type { PerformanceDataset, PerformanceSample } from "./compare-performance";

type Options = Record<string, string>;

function parseArgs(args: string[]): Options {
  const options: Options = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined) throw new Error(`invalid arguments near ${key ?? "end"}`);
    options[key] = value;
  }
  return options;
}

function requireOption(options: Options, key: string): string {
  const value = options[key];
  if (!value) throw new Error(`missing ${key}`);
  return value;
}

function run(executable: string, args: string[]): string {
  const process = Bun.spawnSync([executable, ...args], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (process.exitCode !== 0) {
    throw new Error(
      `${executable} ${args.join(" ")} exited ${process.exitCode}\n${process.stderr.toString()}`,
    );
  }
  return process.stdout.toString().trim();
}

function sampleArgs(scenario: string, sampleId: string, rts: string): string[] {
  return [
    "--scenario",
    scenario,
    "--sample-id",
    sampleId,
    "+RTS",
    rts,
    "-T",
    "-A32m",
    "-RTS",
  ];
}

function parseSample(raw: string, scenario: string): Omit<PerformanceSample, "pairId" | "ordinal"> {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error(`${scenario}: lifecycle-load did not emit one JSON object: ${raw.slice(0, 200)}`);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${scenario}: lifecycle-load output is not an object`);
  }
  return value as Omit<PerformanceSample, "pairId" | "ordinal">;
}

if (import.meta.main) {
  try {
    const options = parseArgs(Bun.argv.slice(2));
    const executable = resolve(requireOption(options, "--executable"));
    const output = resolve(requireOption(options, "--output"));
    const label = requireOption(options, "--label");
    const rts = requireOption(options, "--rts");
    const iterations = Number(options["--iterations"] ?? "10");
    if (!Number.isInteger(iterations) || iterations < 1) throw new Error("--iterations must be a positive integer");

    const allScenarios = run(executable, ["--list"]).split("\n").filter(Boolean);
    const scenarios = options["--scenarios"]?.split(",").filter(Boolean) ?? allScenarios;
    const samples: PerformanceSample[] = [];
    for (const scenario of scenarios) {
      run(executable, sampleArgs(scenario, `warmup-${scenario}`, rts));
      for (let ordinal = 1; ordinal <= iterations; ordinal += 1) {
        const sampleId = `${label}-${scenario}-${String(ordinal).padStart(2, "0")}`;
        const sample = parseSample(run(executable, sampleArgs(scenario, sampleId, rts)), scenario);
        samples.push({
          ...sample,
          pairId: `${rts.replace(/[^a-zA-Z0-9]+/g, "")}-${String(ordinal).padStart(2, "0")}`,
          ordinal,
        });
      }
      process.stderr.write(`captured ${iterations} ${rts} samples for ${scenario}\n`);
    }

    const dataset: PerformanceDataset & {
      capture: {
        purpose: string;
        pairedComparisonEligible: boolean;
        warmupsPerScenario: number;
      };
    } = {
      schemaVersion: 1,
      label,
      capture: {
        purpose: "pre-remediation-calibration",
        pairedComparisonEligible: false,
        warmupsPerScenario: 1,
      },
      environment: {
        machineId: requireOption(options, "--machine-id"),
        platform: requireOption(options, "--platform"),
        compiler: requireOption(options, "--compiler"),
        optimization: requireOption(options, "--optimization"),
        rtsFlags: `${rts} -T -A32m`,
        capabilities: Number(requireOption(options, "--capabilities")),
        services: {},
      },
      source: {
        productionSha: requireOption(options, "--production-sha"),
        harnessSha: requireOption(options, "--harness-sha"),
        solverPlanHash: requireOption(options, "--solver-plan-hash"),
      },
      samples,
    };
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, `${JSON.stringify(dataset, null, 2)}\n`);
    process.stdout.write(`wrote ${samples.length} samples to ${output}\n`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
