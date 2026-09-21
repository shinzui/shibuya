#!/usr/bin/env bun

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

type JsonRecord = Record<string, unknown>;
type Options = Record<string, string>;

interface RawSample {
  schemaVersion: number;
  sampleId: string;
  workloadVersion: number;
  scenario: string;
  configuration: {
    messages: number;
    [key: string]: unknown;
  };
  metrics: {
    expected: number;
    completed: number;
    acknowledged: number;
    retried: number;
    deadLettered: number;
    allocatedBytesPerMessage: number;
    maxLiveBytes: number;
    [key: string]: unknown;
  };
}

interface CapturedSample {
  rtsFlags: string;
  capabilities: number;
  messages: number;
  ordinal: number;
  result: RawSample;
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

function positiveIntegers(value: string, label: string): number[] {
  const result = value.split(",").map(Number);
  if (result.length === 0 || result.some((item) => !Number.isSafeInteger(item) || item < 1)) {
    throw new Error(`${label} must be a comma-separated list of positive integers`);
  }
  return result;
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

function parseSample(raw: string, expectedMessages: number): RawSample {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error(`lifecycle-load did not emit one JSON object: ${raw.slice(0, 200)}`);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("lifecycle-load output is not an object");
  }
  const sample = value as RawSample;
  const metrics = sample.metrics;
  if (
    sample.scenario !== "batch-high-cardinality-envelope" ||
    sample.configuration?.messages !== expectedMessages ||
    metrics?.expected !== expectedMessages ||
    metrics.completed !== expectedMessages ||
    metrics.acknowledged !== expectedMessages ||
    metrics.retried !== 0 ||
    metrics.deadLettered !== 0
  ) {
    throw new Error(`invalid terminal counts for ${expectedMessages} messages: ${raw.slice(0, 500)}`);
  }
  if (!Number.isFinite(metrics.maxLiveBytes) || metrics.maxLiveBytes < 0) {
    throw new Error(`invalid maxLiveBytes for ${expectedMessages} messages`);
  }
  return sample;
}

function median(values: number[]): number {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1]! + sorted[middle]!) / 2 : sorted[middle]!;
}

function capabilitiesFor(rts: string): number {
  const match = /^N([1-9][0-9]*)$/.exec(rts);
  if (!match) throw new Error(`RTS cell must have the form N<number>, got ${rts}`);
  return Number(match[1]);
}

function summarize(samples: CapturedSample[], rts: string, messages: number) {
  const selected = samples.filter((sample) => sample.rtsFlags === `-${rts} -T -A32m` && sample.messages === messages);
  const live = selected.map((sample) => sample.result.metrics.maxLiveBytes);
  const allocations = selected.map((sample) => sample.result.metrics.allocatedBytesPerMessage);
  return {
    rtsFlags: `-${rts} -T -A32m`,
    capabilities: capabilitiesFor(rts),
    messages,
    sampleCount: selected.length,
    maxLiveBytes: {
      minimum: Math.min(...live),
      median: median(live),
      maximum: Math.max(...live),
    },
    medianAllocatedBytesPerMessage: median(allocations),
  };
}

function empiricalEnvelope(summaries: ReturnType<typeof summarize>[], rts: string) {
  const selected = summaries
    .filter((summary) => summary.rtsFlags === `-${rts} -T -A32m`)
    .sort((left, right) => left.messages - right.messages);
  let bytesPerAdditionalKey = 0;
  for (let index = 1; index < selected.length; index += 1) {
    const previous = selected[index - 1]!;
    const current = selected[index]!;
    bytesPerAdditionalKey = Math.max(
      bytesPerAdditionalKey,
      (current.maxLiveBytes.maximum - previous.maxLiveBytes.maximum) / (current.messages - previous.messages),
    );
  }
  bytesPerAdditionalKey = Math.max(0, Math.ceil(bytesPerAdditionalKey));
  const fixedBytes = Math.max(0, Math.ceil(
    Math.max(...selected.map((summary) => summary.maxLiveBytes.maximum - bytesPerAdditionalKey * summary.messages)),
  ));
  return {
    rtsFlags: `-${rts} -T -A32m`,
    testedMessageRange: [selected[0]!.messages, selected[selected.length - 1]!.messages],
    observedUpperEnvelope: {
      fixedBytes,
      bytesPerAdditionalKey,
      formula: `maxLiveBytes <= ${fixedBytes} + (${bytesPerAdditionalKey} * distinctInProgressKeys)`,
    },
  };
}

if (import.meta.main) {
  try {
    const options = parseArgs(Bun.argv.slice(2));
    const executable = resolve(requireOption(options, "--executable"));
    const output = resolve(requireOption(options, "--output"));
    const messageCounts = positiveIntegers(requireOption(options, "--message-counts"), "--message-counts")
      .sort((left, right) => left - right);
    const iterations = Number(options["--iterations"] ?? "5");
    if (!Number.isSafeInteger(iterations) || iterations < 1) {
      throw new Error("--iterations must be a positive integer");
    }
    const rtsCells = requireOption(options, "--rts-cells").split(",");
    rtsCells.forEach(capabilitiesFor);
    const samples: CapturedSample[] = [];

    for (const rts of rtsCells) {
      for (const messages of messageCounts) {
        for (let ordinal = 1; ordinal <= iterations; ordinal += 1) {
          const sampleId = `high-cardinality-${rts.toLowerCase()}-${messages}-${String(ordinal).padStart(2, "0")}`;
          const raw = run(executable, [
            "--scenario",
            "batch-high-cardinality-envelope",
            "--sample-id",
            sampleId,
            "--messages",
            String(messages),
            "+RTS",
            `-${rts}`,
            "-T",
            "-A32m",
            "-RTS",
          ]);
          samples.push({
            rtsFlags: `-${rts} -T -A32m`,
            capabilities: capabilitiesFor(rts),
            messages,
            ordinal,
            result: parseSample(raw, messages),
          });
        }
        process.stderr.write(`captured ${iterations} ${rts} samples at ${messages} distinct keys\n`);
      }
    }

    const summaries = rtsCells.flatMap((rts) => messageCounts.map((messages) => summarize(samples, rts, messages)));
    const report: JsonRecord = {
      schemaVersion: 1,
      status: "pass",
      scenario: "batch-high-cardinality-envelope",
      interpretation: "Empirical finite-source bound only; distinct in-progress batch keys remain unbounded by inbox capacity.",
      environment: {
        machineId: requireOption(options, "--machine-id"),
        platform: requireOption(options, "--platform"),
        compiler: requireOption(options, "--compiler"),
        optimization: requireOption(options, "--optimization"),
        rtsCells: rtsCells.map((rts) => `-${rts} -T -A32m`),
      },
      source: {
        productionSha: requireOption(options, "--production-sha"),
        harnessSha: requireOption(options, "--harness-sha"),
        solverPlanHash: requireOption(options, "--solver-plan-hash"),
      },
      messageCounts,
      iterationsPerCell: iterations,
      summaries,
      envelopes: rtsCells.map((rts) => empiricalEnvelope(summaries, rts)),
      samples,
    };
    mkdirSync(dirname(output), { recursive: true });
    writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`);
    process.stdout.write(`wrote ${samples.length} samples to ${output}\n`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
