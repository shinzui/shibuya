#!/usr/bin/env bun

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

import {
  comparePerformance,
  type PerformanceBudgets,
  type PerformanceDataset,
  type PerformanceSample,
} from "./compare-performance";

type Options = Record<string, string>;

interface Variant {
  name: "baseline" | "candidate";
  executable: string;
  output: string;
  label: string;
  productionSha: string;
  samples: PerformanceSample[];
}

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

function scenarioList(executable: string): string[] {
  return run(executable, ["--list"]).split("\n").filter(Boolean);
}

function equalLists(left: string[], right: string[]): boolean {
  return left.length === right.length && left.every((item, index) => item === right[index]);
}

function dataset(
  variant: Variant,
  options: Options,
  rts: string,
  capabilities: number,
  services: Record<string, string>,
): PerformanceDataset & {
  capture: {
    purpose: string;
    pairedComparisonEligible: boolean;
    warmupsPerScenario: number;
    ordering: string;
  };
} {
  return {
    schemaVersion: 1,
    label: variant.label,
    capture: {
      purpose: "final-paired-comparison",
      pairedComparisonEligible: true,
      warmupsPerScenario: 1,
      ordering: "alternating; baseline first on odd pairs, candidate first on even pairs",
    },
    environment: {
      machineId: requireOption(options, "--machine-id"),
      platform: requireOption(options, "--platform"),
      compiler: requireOption(options, "--compiler"),
      optimization: requireOption(options, "--optimization"),
      rtsFlags: `${rts} -T -A32m`,
      capabilities,
      services,
    },
    source: {
      productionSha: variant.productionSha,
      harnessSha: requireOption(options, "--harness-sha"),
      solverPlanHash: requireOption(options, "--solver-plan-hash"),
    },
    samples: variant.samples,
  };
}

function writeDataset(variant: Variant, value: PerformanceDataset): void {
  mkdirSync(dirname(variant.output), { recursive: true });
  writeFileSync(variant.output, `${JSON.stringify(value, null, 2)}\n`);
}

function capture(baseline: Variant, candidate: Variant, scenarios: string[], iterations: number, rts: string): void {
  for (const scenario of scenarios) {
    run(baseline.executable, sampleArgs(scenario, `warmup-baseline-${scenario}`, rts));
    run(candidate.executable, sampleArgs(scenario, `warmup-candidate-${scenario}`, rts));
    for (let ordinal = 1; ordinal <= iterations; ordinal += 1) {
      const order = ordinal % 2 === 1 ? [baseline, candidate] : [candidate, baseline];
      const pairId = `${rts.replace(/[^a-zA-Z0-9]+/g, "")}-${String(ordinal).padStart(2, "0")}`;
      for (const variant of order) {
        const sampleId = `${variant.label}-${scenario}-${String(ordinal).padStart(2, "0")}`;
        const raw = run(variant.executable, sampleArgs(scenario, sampleId, rts));
        variant.samples.push({ ...parseSample(raw, scenario), pairId, ordinal });
      }
    }
    process.stderr.write(`captured ${iterations} paired ${rts} samples for ${scenario}\n`);
  }
}

if (import.meta.main) {
  try {
    const options = parseArgs(Bun.argv.slice(2));
    const baseline: Variant = {
      name: "baseline",
      executable: resolve(requireOption(options, "--baseline-executable")),
      output: resolve(requireOption(options, "--baseline-output")),
      label: requireOption(options, "--baseline-label"),
      productionSha: requireOption(options, "--baseline-production-sha"),
      samples: [],
    };
    const candidate: Variant = {
      name: "candidate",
      executable: resolve(requireOption(options, "--candidate-executable")),
      output: resolve(requireOption(options, "--candidate-output")),
      label: requireOption(options, "--candidate-label"),
      productionSha: requireOption(options, "--candidate-production-sha"),
      samples: [],
    };
    const rts = requireOption(options, "--rts");
    const iterations = Number(options["--iterations"] ?? "10");
    const capabilities = Number(requireOption(options, "--capabilities"));
    if (!Number.isInteger(iterations) || iterations < 1) {
      throw new Error("--iterations must be a positive integer");
    }
    if (!Number.isInteger(capabilities) || capabilities < 1) {
      throw new Error("--capabilities must be a positive integer");
    }
    const baselineScenarios = scenarioList(baseline.executable);
    const candidateScenarios = scenarioList(candidate.executable);
    if (!equalLists(baselineScenarios, candidateScenarios)) {
      throw new Error("baseline and candidate scenario catalogs differ");
    }
    const scenarios = options["--scenarios"]?.split(",").filter(Boolean) ?? baselineScenarios;
    for (const scenario of scenarios) {
      if (!baselineScenarios.includes(scenario)) throw new Error(`unknown scenario: ${scenario}`);
    }
    let services: Record<string, string> = {};
    if (options["--services-json"]) {
      const parsed = JSON.parse(options["--services-json"]);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        throw new Error("--services-json must be a JSON object");
      }
      services = parsed as Record<string, string>;
    }

    // A busy host or unstable fixture can fail the budget against itself.
    // Check that before spending time collecting candidate measurements.
    if (options["--stability-budgets"]) {
      const budgets: PerformanceBudgets = JSON.parse(readFileSync(resolve(options["--stability-budgets"]), "utf8"));
      if (!Number.isInteger(budgets.minimumPairs) || budgets.minimumPairs < 2) {
        throw new Error("stability budgets minimumPairs must be an integer of at least 2");
      }
      const left: Variant = { ...baseline, output: `${baseline.output}.control-left.json`, label: `${baseline.label}-control-left`, samples: [] };
      const right: Variant = { ...baseline, name: "candidate", output: `${baseline.output}.control-right.json`, label: `${baseline.label}-control-right`, samples: [] };
      capture(left, right, scenarios, budgets.minimumPairs, rts);
      const leftDataset = dataset(left, options, rts, capabilities, services);
      const rightDataset = dataset(right, options, rts, capabilities, services);
      const controlBudgets = { ...budgets, requiredScenarios: scenarios };
      const forward = comparePerformance(leftDataset, rightDataset, controlBudgets);
      const reverse = comparePerformance(rightDataset, leftDataset, controlBudgets);
      leftDataset.capture.purpose = rightDataset.capture.purpose = "baseline-stability-control";
      leftDataset.capture.pairedComparisonEligible = rightDataset.capture.pairedComparisonEligible = false;
      writeDataset(left, leftDataset);
      writeDataset(right, rightDataset);
      writeFileSync(`${baseline.output}.control-verdict.json`, `${JSON.stringify({ forward, reverse }, null, 2)}\n`);
      if (forward.status !== "pass" || reverse.status !== "pass") {
        process.stderr.write("Baseline stability check did not pass; candidate capture skipped. No candidate performance verdict is available.\n");
        process.exit(2);
      }
    }

    capture(baseline, candidate, scenarios, iterations, rts);
    writeDataset(baseline, dataset(baseline, options, rts, capabilities, services));
    writeDataset(candidate, dataset(candidate, options, rts, capabilities, services));
    process.stdout.write(
      `wrote ${baseline.samples.length} baseline and ${candidate.samples.length} candidate samples\n`,
    );
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
