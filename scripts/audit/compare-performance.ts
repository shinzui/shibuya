#!/usr/bin/env bun

import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

type JsonRecord = Record<string, unknown>;

export type VerdictStatus = "pass" | "fail" | "inconclusive";
export type MetricDirection = "higher-is-better" | "lower-is-better";

export interface PerformanceSample {
  pairId: string;
  ordinal: number;
  sampleId: string;
  scenario: string;
  workloadVersion: number;
  configuration: JsonRecord;
  metrics: Record<string, number | null> & {
    expected: number;
    completed: number;
    acknowledged: number;
  };
}

export interface PerformanceDataset {
  schemaVersion: number;
  label: string;
  environment: {
    machineId: string;
    platform: string;
    compiler: string;
    optimization: string;
    rtsFlags: string;
    capabilities: number;
    services: Record<string, string>;
  };
  source: {
    productionSha: string;
    harnessSha: string;
    solverPlanHash: string;
  };
  samples: PerformanceSample[];
}

export interface MetricPolicy {
  direction: MetricDirection;
  relativeLimit?: number;
  absoluteMaximum?: number;
  absoluteDelta?: number;
  nearZeroThreshold?: number;
}

export interface PerformanceBudgets {
  schemaVersion: number;
  minimumPairs: number;
  confidenceLevel: number;
  bootstrapIterations: number;
  resamplingSeed: number;
  metrics: Record<string, MetricPolicy>;
  scenarioMetrics?: Record<string, Record<string, MetricPolicy>>;
  scenarioExclusions?: Record<string, string[]>;
}

export interface MetricVerdict {
  scenario: string;
  metric: string;
  status: VerdictStatus;
  pairCount: number;
  method: "paired-ratio" | "paired-absolute";
  estimate: number;
  lower95: number;
  upper95: number;
  threshold: number;
  message: string;
}

export interface PerformanceVerdict {
  schemaVersion: number;
  status: VerdictStatus;
  baselineLabel: string;
  candidateLabel: string;
  confidenceLevel: number;
  resamplingSeed: number;
  errors: string[];
  results: MetricVerdict[];
}

interface Pair {
  baseline: PerformanceSample;
  candidate: PerformanceSample;
}

function record(value: unknown): JsonRecord | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonRecord)
    : undefined;
}

function finiteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function stableJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(stableJson).join(",")}]`;
  const item = record(value);
  if (item) {
    return `{${Object.keys(item)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${stableJson(item[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

function sameEnvironment(left: PerformanceDataset, right: PerformanceDataset): boolean {
  return stableJson(left.environment) === stableJson(right.environment);
}

function validateDataset(dataset: PerformanceDataset, label: string): string[] {
  const errors: string[] = [];
  if (dataset.schemaVersion !== 1) errors.push(`${label}.schemaVersion: expected 1`);
  if (!dataset.label) errors.push(`${label}.label: missing`);
  if (!record(dataset.environment)) errors.push(`${label}.environment: missing`);
  if (!record(dataset.source)) errors.push(`${label}.source: missing`);
  if (!Array.isArray(dataset.samples) || dataset.samples.length === 0) {
    errors.push(`${label}.samples: expected at least one sample`);
    return errors;
  }

  const sampleIds = new Set<string>();
  const pairKeys = new Set<string>();
  dataset.samples.forEach((sample, index) => {
    const prefix = `${label}.samples[${index}]`;
    if (!sample.sampleId) errors.push(`${prefix}.sampleId: missing`);
    else if (sampleIds.has(sample.sampleId)) errors.push(`${label}.samples: duplicate sampleId ${sample.sampleId}`);
    sampleIds.add(sample.sampleId);
    if (!sample.pairId) errors.push(`${prefix}.pairId: missing`);
    if (!Number.isInteger(sample.ordinal) || sample.ordinal < 1) errors.push(`${prefix}.ordinal: expected positive integer`);
    if (!sample.scenario) errors.push(`${prefix}.scenario: missing`);
    const pairKey = `${sample.scenario}\u0000${sample.pairId}`;
    if (pairKeys.has(pairKey)) errors.push(`${label}.samples: duplicate pair ${sample.scenario}/${sample.pairId}`);
    pairKeys.add(pairKey);
    const expected = finiteNumber(sample.metrics?.expected);
    const completed = finiteNumber(sample.metrics?.completed);
    const acknowledged = finiteNumber(sample.metrics?.acknowledged);
    if (expected === undefined || completed === undefined || acknowledged === undefined) {
      errors.push(`${prefix}.metrics: expected/completed/acknowledged must be finite numbers`);
    } else if (completed !== expected || acknowledged !== expected) {
      errors.push(
        `${prefix}.metrics: dropped work (expected ${expected}, completed ${completed}, acknowledged ${acknowledged})`,
      );
    }
  });
  return errors;
}

function pairSamples(
  baseline: PerformanceDataset,
  candidate: PerformanceDataset,
  minimumPairs: number,
  errors: string[],
): Map<string, Pair[]> {
  const baselineByKey = new Map<string, PerformanceSample>();
  const candidateByKey = new Map<string, PerformanceSample>();
  for (const sample of baseline.samples) baselineByKey.set(`${sample.scenario}\u0000${sample.pairId}`, sample);
  for (const sample of candidate.samples) candidateByKey.set(`${sample.scenario}\u0000${sample.pairId}`, sample);

  for (const key of baselineByKey.keys()) {
    if (!candidateByKey.has(key)) errors.push(`candidate: missing matched sample ${key.replace("\u0000", "/")}`);
  }
  for (const key of candidateByKey.keys()) {
    if (!baselineByKey.has(key)) errors.push(`baseline: missing matched sample ${key.replace("\u0000", "/")}`);
  }

  const byScenario = new Map<string, Pair[]>();
  for (const [key, baselineSample] of baselineByKey) {
    const candidateSample = candidateByKey.get(key);
    if (!candidateSample) continue;
    if (stableJson(baselineSample.configuration) !== stableJson(candidateSample.configuration)) {
      errors.push(`${baselineSample.scenario}/${baselineSample.pairId}: workload configuration differs`);
      continue;
    }
    if (baselineSample.workloadVersion !== candidateSample.workloadVersion) {
      errors.push(`${baselineSample.scenario}/${baselineSample.pairId}: workload version differs`);
      continue;
    }
    const pairs = byScenario.get(baselineSample.scenario) ?? [];
    pairs.push({ baseline: baselineSample, candidate: candidateSample });
    byScenario.set(baselineSample.scenario, pairs);
  }

  for (const [scenario, pairs] of byScenario) {
    pairs.sort((left, right) => left.baseline.ordinal - right.baseline.ordinal);
    if (pairs.length < minimumPairs) {
      errors.push(`${scenario}: requires at least ${minimumPairs} matched pairs, found ${pairs.length}`);
    }
    for (let index = 0; index < pairs.length; index += 1) {
      const pair = pairs[index];
      if (pair.baseline.ordinal !== pair.candidate.ordinal) {
        errors.push(`${scenario}/${pair.baseline.pairId}: alternating-run ordinal differs`);
      }
      if (index > 0 && pair.baseline.ordinal <= pairs[index - 1].baseline.ordinal) {
        errors.push(`${scenario}: ordinals must be unique and increasing`);
      }
    }
  }
  return byScenario;
}

function mulberry32(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

function quantile(sorted: number[], probability: number): number {
  if (sorted.length === 0) return Number.NaN;
  const position = (sorted.length - 1) * probability;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  if (lower === upper) return sorted[lower];
  const weight = position - lower;
  return sorted[lower] * (1 - weight) + sorted[upper] * weight;
}

function geometricMean(values: number[]): number {
  return Math.exp(values.reduce((sum, value) => sum + Math.log(value), 0) / values.length);
}

function arithmeticMean(values: number[]): number {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function bootstrapInterval(
  values: number[],
  statistic: (samples: number[]) => number,
  iterations: number,
  confidenceLevel: number,
  seed: number,
): [number, number, number] {
  const estimate = statistic(values);
  const random = mulberry32(seed);
  const estimates: number[] = [];
  for (let iteration = 0; iteration < iterations; iteration += 1) {
    const sample: number[] = [];
    for (let index = 0; index < values.length; index += 1) {
      sample.push(values[Math.floor(random() * values.length)]);
    }
    estimates.push(statistic(sample));
  }
  estimates.sort((left, right) => left - right);
  const tail = (1 - confidenceLevel) / 2;
  return [estimate, quantile(estimates, tail), quantile(estimates, 1 - tail)];
}

function statusForBounds(lower: number, upper: number, threshold: number): VerdictStatus {
  if (lower > threshold) return "fail";
  if (upper > threshold) return "inconclusive";
  return "pass";
}

function metricValue(sample: PerformanceSample, metric: string): number | undefined {
  return finiteNumber(sample.metrics[metric]);
}

function compareMetric(
  scenario: string,
  metric: string,
  policy: MetricPolicy,
  pairs: Pair[],
  budgets: PerformanceBudgets,
  seedOffset: number,
  errors: string[],
): MetricVerdict | undefined {
  const values: Array<{ baseline: number; candidate: number }> = [];
  for (const pair of pairs) {
    const baselineValue = metricValue(pair.baseline, metric);
    const candidateValue = metricValue(pair.candidate, metric);
    if (baselineValue === undefined || candidateValue === undefined) {
      errors.push(`${scenario}/${pair.baseline.pairId}: missing finite metric ${metric}`);
      continue;
    }
    values.push({ baseline: baselineValue, candidate: candidateValue });
  }
  if (values.length !== pairs.length || values.length === 0) return undefined;

  const nearZero = policy.nearZeroThreshold ?? 1e-9;
  const hasNearZeroBaseline = values.some((value) => Math.abs(value.baseline) <= nearZero);
  if (!hasNearZeroBaseline && policy.relativeLimit !== undefined) {
    const adverseRatios = values.map(({ baseline, candidate }) =>
      policy.direction === "higher-is-better" ? baseline / candidate : candidate / baseline,
    );
    if (adverseRatios.some((ratio) => !Number.isFinite(ratio) || ratio <= 0)) {
      errors.push(`${scenario}/${metric}: paired ratios must be finite and positive`);
      return undefined;
    }
    const [estimate, lower95, upper95] = bootstrapInterval(
      adverseRatios,
      geometricMean,
      budgets.bootstrapIterations,
      budgets.confidenceLevel,
      budgets.resamplingSeed + seedOffset,
    );
    const threshold = 1 + policy.relativeLimit;
    const status = statusForBounds(lower95, upper95, threshold);
    return {
      scenario,
      metric,
      status,
      pairCount: values.length,
      method: "paired-ratio",
      estimate,
      lower95,
      upper95,
      threshold,
      message: `${metric} adverse ratio ${estimate.toFixed(4)} (CI ${lower95.toFixed(4)}..${upper95.toFixed(4)}, limit ${threshold.toFixed(4)})`,
    };
  }

  if (policy.absoluteDelta === undefined && policy.absoluteMaximum === undefined) {
    errors.push(`${scenario}/${metric}: near-zero baseline requires an absoluteDelta or absoluteMaximum budget`);
    return undefined;
  }
  const adverseDeltas = values.map(({ baseline, candidate }) =>
    policy.direction === "higher-is-better" ? baseline - candidate : candidate - baseline,
  );
  const [estimate, lower95, upper95] = bootstrapInterval(
    adverseDeltas,
    arithmeticMean,
    budgets.bootstrapIterations,
    budgets.confidenceLevel,
    budgets.resamplingSeed + seedOffset,
  );
  let threshold = policy.absoluteDelta ?? Number.POSITIVE_INFINITY;
  let status = statusForBounds(lower95, upper95, threshold);
  let message = `${metric} adverse delta ${estimate.toFixed(4)} (CI ${lower95.toFixed(4)}..${upper95.toFixed(4)}, limit ${threshold.toFixed(4)})`;
  if (policy.absoluteMaximum !== undefined) {
    const candidateValues = values.map((value) => value.candidate);
    const [candidateEstimate, candidateLower, candidateUpper] = bootstrapInterval(
      candidateValues,
      arithmeticMean,
      budgets.bootstrapIterations,
      budgets.confidenceLevel,
      budgets.resamplingSeed + seedOffset + 1_000_003,
    );
    const maximumStatus = statusForBounds(candidateLower, candidateUpper, policy.absoluteMaximum);
    if (maximumStatus === "fail" || (maximumStatus === "inconclusive" && status === "pass")) status = maximumStatus;
    threshold = Math.min(threshold, policy.absoluteMaximum);
    message += `; candidate mean ${candidateEstimate.toFixed(4)} (CI ${candidateLower.toFixed(4)}..${candidateUpper.toFixed(4)}, max ${policy.absoluteMaximum.toFixed(4)})`;
  }
  return {
    scenario,
    metric,
    status,
    pairCount: values.length,
    method: "paired-absolute",
    estimate,
    lower95,
    upper95,
    threshold,
    message,
  };
}

export function comparePerformance(
  baseline: PerformanceDataset,
  candidate: PerformanceDataset,
  budgets: PerformanceBudgets,
): PerformanceVerdict {
  const errors = [...validateDataset(baseline, "baseline"), ...validateDataset(candidate, "candidate")];
  if (budgets.schemaVersion !== 1) errors.push("budgets.schemaVersion: expected 1");
  if (budgets.minimumPairs < 2) errors.push("budgets.minimumPairs: expected at least 2");
  if (!(budgets.confidenceLevel > 0 && budgets.confidenceLevel < 1)) {
    errors.push("budgets.confidenceLevel: expected a value between 0 and 1");
  }
  if (budgets.bootstrapIterations < 100) errors.push("budgets.bootstrapIterations: expected at least 100");
  if (!sameEnvironment(baseline, candidate)) errors.push("environment mismatch: baseline and candidate must use identical controlled settings");
  if (baseline.source.harnessSha !== candidate.source.harnessSha) errors.push("harness SHA mismatch");
  if (baseline.source.solverPlanHash !== candidate.source.solverPlanHash) errors.push("solver plan hash mismatch");

  const pairsByScenario = pairSamples(baseline, candidate, budgets.minimumPairs, errors);
  const results: MetricVerdict[] = [];
  let seedOffset = 0;
  for (const [scenario, pairs] of [...pairsByScenario.entries()].sort(([left], [right]) => left.localeCompare(right))) {
    const exclusions = new Set(budgets.scenarioExclusions?.[scenario] ?? []);
    const policies = { ...budgets.metrics, ...(budgets.scenarioMetrics?.[scenario] ?? {}) };
    for (const [metric, policy] of Object.entries(policies).sort(([left], [right]) => left.localeCompare(right))) {
      if (exclusions.has(metric)) continue;
      const verdict = compareMetric(scenario, metric, policy, pairs, budgets, seedOffset, errors);
      seedOffset += 17;
      if (verdict) results.push(verdict);
    }
  }

  const status: VerdictStatus =
    errors.length > 0 || results.some((result) => result.status === "fail")
      ? "fail"
      : results.some((result) => result.status === "inconclusive")
        ? "inconclusive"
        : "pass";
  return {
    schemaVersion: 1,
    status,
    baselineLabel: baseline.label,
    candidateLabel: candidate.label,
    confidenceLevel: budgets.confidenceLevel,
    resamplingSeed: budgets.resamplingSeed,
    errors,
    results,
  };
}

function parseArgs(args: string[]): Record<string, string> {
  const options: Record<string, string> = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined) throw new Error(`invalid arguments near ${key ?? "end"}`);
    options[key] = value;
  }
  return options;
}

function loadJson<T>(path: string): T {
  return JSON.parse(readFileSync(resolve(path), "utf8")) as T;
}

if (import.meta.main) {
  try {
    const options = parseArgs(Bun.argv.slice(2));
    for (const required of ["--baseline", "--candidate", "--budgets"]) {
      if (!options[required]) throw new Error(`missing ${required}`);
    }
    const verdict = comparePerformance(
      loadJson<PerformanceDataset>(options["--baseline"]),
      loadJson<PerformanceDataset>(options["--candidate"]),
      loadJson<PerformanceBudgets>(options["--budgets"]),
    );
    const output = `${JSON.stringify(verdict, null, 2)}\n`;
    if (options["--output"]) writeFileSync(resolve(options["--output"]), output);
    process.stdout.write(output);
    process.exitCode = verdict.status === "pass" ? 0 : verdict.status === "inconclusive" ? 2 : 1;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
