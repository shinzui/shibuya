#!/usr/bin/env bun

import { readFileSync, writeFileSync } from "node:fs";

export interface Options {
  input: string;
  ledger: string;
  output?: string;
  adapter: string;
  scenario: "sustainable" | "saturation" | "soak";
  durationSeconds: number;
  restartAtSeconds: number;
  targetRate: number;
}

interface Sample {
  elapsedSeconds: number;
  produced: number;
  processed: number;
  failed: number;
  backlog: number;
  retainedBytes: number;
  maxLiveBytes: number;
}

export interface DeliveryLedger {
  schemaVersion: number;
  adapter: string;
  runId: string;
  status: string;
  producedIds: number[];
  processedIds: number[];
  duplicateIds: number[];
  missingIds: number[];
  unexpectedIds: number[];
  malformedDeliveries: number;
}

function parseInteger(value: string, label: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) throw new Error(`${label}: expected a non-negative integer`);
  return parsed;
}

function parseOptions(args: string[]): Options {
  const values = new Map<string, string>();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined) throw new Error(`invalid argument near ${key ?? "end of input"}`);
    values.set(key.slice(2), value);
  }
  const required = (key: string): string => {
    const value = values.get(key);
    if (!value) throw new Error(`missing --${key}`);
    return value;
  };
  const scenario = required("scenario");
  if (scenario !== "sustainable" && scenario !== "saturation" && scenario !== "soak") {
    throw new Error(`--scenario: expected sustainable, saturation, or soak`);
  }
  return {
    input: required("input"),
    ledger: required("ledger"),
    output: values.get("output"),
    adapter: required("adapter"),
    scenario,
    durationSeconds: parseInteger(required("duration-seconds"), "--duration-seconds"),
    restartAtSeconds: parseInteger(required("restart-at-seconds"), "--restart-at-seconds"),
    targetRate: parseInteger(required("target-rate"), "--target-rate"),
  };
}

export function parseDeliveryLedger(input: string): DeliveryLedger {
  const value = JSON.parse(input) as Partial<DeliveryLedger>;
  const integerArray = (field: keyof DeliveryLedger): number[] => {
    const values = value[field];
    if (!Array.isArray(values) || values.some((item) => !Number.isSafeInteger(item) || item < 0)) {
      throw new Error(`ledger.${field}: expected non-negative integer array`);
    }
    if (new Set(values).size !== values.length) throw new Error(`ledger.${field}: duplicate identities`);
    return values;
  };
  if (value.schemaVersion !== 1) throw new Error("ledger.schemaVersion: expected 1");
  if (typeof value.adapter !== "string" || !value.adapter) throw new Error("ledger.adapter: expected nonempty string");
  if (typeof value.runId !== "string" || !value.runId) throw new Error("ledger.runId: expected nonempty string");
  if (value.status !== "pass" && value.status !== "fail") throw new Error("ledger.status: expected pass or fail");
  if (!Number.isSafeInteger(value.malformedDeliveries) || (value.malformedDeliveries ?? -1) < 0) {
    throw new Error("ledger.malformedDeliveries: expected non-negative integer");
  }
  return {
    schemaVersion: 1,
    adapter: value.adapter,
    runId: value.runId,
    status: value.status,
    producedIds: integerArray("producedIds"),
    processedIds: integerArray("processedIds"),
    duplicateIds: integerArray("duplicateIds"),
    missingIds: integerArray("missingIds"),
    unexpectedIds: integerArray("unexpectedIds"),
    malformedDeliveries: value.malformedDeliveries!,
  };
}

export function parseCsv(input: string): Sample[] {
  const lines = input.trim().split(/\r?\n/);
  const expected = [
    "timestamp",
    "elapsed_secs",
    "produced",
    "processed",
    "failed",
    "queue_depth",
    "retained_bytes",
    "max_live_bytes",
  ];
  const header = lines.shift()?.split(",") ?? [];
  if (header.length !== expected.length || header.some((column, index) => column !== expected[index])) {
    throw new Error(`unexpected CSV header: ${header.join(",")}`);
  }
  return lines.filter(Boolean).map((line, rowIndex) => {
    const columns = line.split(",");
    if (columns.length !== expected.length) throw new Error(`row ${rowIndex + 2}: expected ${expected.length} columns`);
    return {
      elapsedSeconds: parseInteger(columns[1]!, `row ${rowIndex + 2} elapsed_secs`),
      produced: parseInteger(columns[2]!, `row ${rowIndex + 2} produced`),
      processed: parseInteger(columns[3]!, `row ${rowIndex + 2} processed`),
      failed: parseInteger(columns[4]!, `row ${rowIndex + 2} failed`),
      backlog: parseInteger(columns[5]!, `row ${rowIndex + 2} queue_depth`),
      retainedBytes: parseInteger(columns[6]!, `row ${rowIndex + 2} retained_bytes`),
      maxLiveBytes: parseInteger(columns[7]!, `row ${rowIndex + 2} max_live_bytes`),
    };
  });
}

function median(values: number[]): number {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1]! + sorted[middle]!) / 2 : sorted[middle]!;
}

function slopePerMinute(samples: Sample[], select: (sample: Sample) => number): number {
  const xs = samples.map((sample) => sample.elapsedSeconds / 60);
  const ys = samples.map(select);
  const xMean = xs.reduce((sum, value) => sum + value, 0) / xs.length;
  const yMean = ys.reduce((sum, value) => sum + value, 0) / ys.length;
  const numerator = xs.reduce((sum, value, index) => sum + (value - xMean) * (ys[index]! - yMean), 0);
  const denominator = xs.reduce((sum, value) => sum + (value - xMean) ** 2, 0);
  return denominator === 0 ? 0 : numerator / denominator;
}

export function analyze(samples: Sample[], options: Options, ledger?: DeliveryLedger) {
  const errors: string[] = [];
  if (samples.length === 0) throw new Error("CSV contains no samples");
  for (let index = 1; index < samples.length; index += 1) {
    if (samples[index]!.elapsedSeconds < samples[index - 1]!.elapsedSeconds) {
      errors.push("sample elapsed times are not monotonic");
      break;
    }
  }

  const final = samples[samples.length - 1]!;
  const scheduled = samples.filter((sample) => sample.elapsedSeconds <= options.durationSeconds);
  const observedInterval = scheduled.length > 1
    ? median(scheduled.slice(1).map((sample, index) => sample.elapsedSeconds - scheduled[index]!.elapsedSeconds))
    : options.durationSeconds;
  const postRestartWarmup = options.scenario === "soak"
    ? Math.max(60, observedInterval * 2)
    : Math.max(observedInterval * 2, Math.min(30, Math.floor((options.durationSeconds - options.restartAtSeconds) / 3)));
  const postRestartStart = options.restartAtSeconds + postRestartWarmup;
  const trendSamples = scheduled.filter((sample) => sample.elapsedSeconds >= postRestartStart);
  const requiredTrendSamples = options.scenario === "soak" ? 8 : 3;

  if (final.elapsedSeconds < options.durationSeconds) errors.push("capture ended before the scheduled duration");
  if (final.failed !== 0) errors.push(`failed count is ${final.failed}, expected 0`);
  if (final.processed !== final.produced) {
    errors.push(`final processed ${final.processed} does not equal produced ${final.produced}`);
  }
  if (final.backlog !== 0) errors.push(`final service backlog is ${final.backlog}, expected 0 after drain`);
  if (!ledger) {
    errors.push("external per-delivery ledger is missing");
  } else {
    if (ledger.adapter !== options.adapter) errors.push(`ledger adapter ${ledger.adapter} does not match ${options.adapter}`);
    if (ledger.status !== "pass") errors.push(`delivery ledger status is ${ledger.status}, expected pass`);
    if (ledger.producedIds.length !== final.produced) {
      errors.push(`ledger produced identity count ${ledger.producedIds.length} does not equal CSV total ${final.produced}`);
    }
    if (ledger.processedIds.length !== final.processed) {
      errors.push(`ledger processed identity count ${ledger.processedIds.length} does not equal CSV total ${final.processed}`);
    }
    if (ledger.duplicateIds.length > 0) errors.push(`delivery ledger contains ${ledger.duplicateIds.length} duplicate identities`);
    if (ledger.missingIds.length > 0) errors.push(`delivery ledger contains ${ledger.missingIds.length} missing identities`);
    if (ledger.unexpectedIds.length > 0) errors.push(`delivery ledger contains ${ledger.unexpectedIds.length} unexpected identities`);
    if (ledger.malformedDeliveries !== 0) {
      errors.push(`delivery ledger contains ${ledger.malformedDeliveries} malformed deliveries`);
    }
    const producedIds = new Set(ledger.producedIds);
    const processedIds = new Set(ledger.processedIds);
    if (producedIds.size !== processedIds.size || [...producedIds].some((id) => !processedIds.has(id))) {
      errors.push("produced and processed delivery identity sets do not match");
    }
  }
  if (options.scenario === "soak" && options.durationSeconds < 1800) {
    errors.push("soak duration is below the mandatory 1,800 seconds");
  }
  if (trendSamples.length < requiredTrendSamples) {
    errors.push(`only ${trendSamples.length} post-restart trend samples, expected at least ${requiredTrendSamples}`);
  }

  const windowSize = Math.max(1, Math.floor(trendSamples.length / 3));
  const firstWindow = trendSamples.slice(0, windowSize);
  const lastWindow = trendSamples.slice(-windowSize);
  const firstRetainedMedian = firstWindow.length ? median(firstWindow.map((sample) => sample.retainedBytes)) : 0;
  const lastRetainedMedian = lastWindow.length ? median(lastWindow.map((sample) => sample.retainedBytes)) : 0;
  const retainedTolerance = Math.max(262_144, firstRetainedMedian * 0.05);
  const retainedGrowth = lastRetainedMedian - firstRetainedMedian;
  const trendSpanMinutes = trendSamples.length > 1
    ? (trendSamples[trendSamples.length - 1]!.elapsedSeconds - trendSamples[0]!.elapsedSeconds) / 60
    : 0;
  const retainedSlope = trendSamples.length > 1 ? slopePerMinute(trendSamples, (sample) => sample.retainedBytes) : 0;
  const slopeAllowance = trendSpanMinutes > 0 ? retainedTolerance / trendSpanMinutes : retainedTolerance;

  if (trendSamples.length >= requiredTrendSamples && retainedGrowth > retainedTolerance) {
    errors.push(`retained heap median grew ${Math.round(retainedGrowth)} bytes; tolerance is ${Math.round(retainedTolerance)}`);
  }
  if (trendSamples.length >= requiredTrendSamples && retainedSlope > slopeAllowance) {
    errors.push(`retained heap slope is ${Math.round(retainedSlope)} bytes/min; allowance is ${Math.round(slopeAllowance)}`);
  }

  const firstBacklogMedian = firstWindow.length ? median(firstWindow.map((sample) => sample.backlog)) : 0;
  const lastBacklogMedian = lastWindow.length ? median(lastWindow.map((sample) => sample.backlog)) : 0;
  const backlogTolerance = Math.max(5, options.targetRate * 2);
  if (options.scenario !== "saturation" && lastBacklogMedian - firstBacklogMedian > backlogTolerance) {
    errors.push(`service backlog median grew ${lastBacklogMedian - firstBacklogMedian}; tolerance is ${backlogTolerance}`);
  }

  return {
    schemaVersion: 1,
    status: errors.length === 0 ? "pass" : "fail",
    adapter: options.adapter,
    scenario: options.scenario,
    input: options.input,
    deliveryLedger: ledger
      ? {
          input: options.ledger,
          runId: ledger.runId,
          producedIdentityCount: ledger.producedIds.length,
          processedIdentityCount: ledger.processedIds.length,
          duplicateIdentityCount: ledger.duplicateIds.length,
          missingIdentityCount: ledger.missingIds.length,
          unexpectedIdentityCount: ledger.unexpectedIds.length,
          malformedDeliveries: ledger.malformedDeliveries,
        }
      : { input: options.ledger, status: "missing" },
    scheduledDurationSeconds: options.durationSeconds,
    restartAtSeconds: options.restartAtSeconds,
    targetRatePerSecond: options.targetRate,
    sampleCount: samples.length,
    postRestartTrendSampleCount: trendSamples.length,
    errors,
    totals: {
      produced: final.produced,
      processed: final.processed,
      failed: final.failed,
      finalBacklog: final.backlog,
      achievedProduceRatePerSecond: final.produced / Math.max(1, options.durationSeconds),
      achievedProcessRatePerSecond: final.processed / Math.max(1, options.durationSeconds),
    },
    backlog: {
      maximum: Math.max(...samples.map((sample) => sample.backlog)),
      firstPostRestartWindowMedian: firstBacklogMedian,
      lastPostRestartWindowMedian: lastBacklogMedian,
      tolerance: backlogTolerance,
      slopePerMinute: trendSamples.length > 1 ? slopePerMinute(trendSamples, (sample) => sample.backlog) : 0,
    },
    retainedMemory: {
      firstPostRestartWindowMedianBytes: firstRetainedMedian,
      lastPostRestartWindowMedianBytes: lastRetainedMedian,
      growthBytes: retainedGrowth,
      toleranceBytes: retainedTolerance,
      slopeBytesPerMinute: retainedSlope,
      slopeAllowanceBytesPerMinute: slopeAllowance,
      maximumLiveBytes: Math.max(...samples.map((sample) => sample.maxLiveBytes)),
    },
  };
}

function main(): void {
  const options = parseOptions(process.argv.slice(2));
  const samples = parseCsv(readFileSync(options.input, "utf8"));
  const ledger = parseDeliveryLedger(readFileSync(options.ledger, "utf8"));
  const report = analyze(samples, options, ledger);
  const output = `${JSON.stringify(report, null, 2)}\n`;
  if (options.output) writeFileSync(options.output, output);
  process.stdout.write(output);
  if (report.status !== "pass") process.exitCode = 1;
}

if (import.meta.main) main();
