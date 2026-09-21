import { describe, expect, test } from "bun:test";

import {
  comparePerformance,
  type PerformanceBudgets,
  type PerformanceDataset,
  type PerformanceSample,
} from "./compare-performance";

const budgets: PerformanceBudgets = {
  schemaVersion: 1,
  minimumPairs: 10,
  confidenceLevel: 0.95,
  bootstrapIterations: 2_000,
  resamplingSeed: 20260920,
  metrics: {
    throughputPerSecond: { direction: "higher-is-better", relativeLimit: 0.05 },
    latencyP95Ms: { direction: "lower-is-better", relativeLimit: 0.1 },
    latencyP99Ms: { direction: "lower-is-better", relativeLimit: 0.1 },
    shutdownLatencyMs: { direction: "lower-is-better", relativeLimit: 0.1 },
    allocatedBytesPerMessage: { direction: "lower-is-better", relativeLimit: 0.05 },
    maxLiveBytes: { direction: "lower-is-better", relativeLimit: 0.05 },
  },
};

function sample(pair: number, overrides: Partial<Record<string, number>> = {}): PerformanceSample {
  return {
    pairId: `pair-${pair}`,
    ordinal: pair,
    sampleId: `sample-${pair}`,
    scenario: "serial-small-inbox",
    workloadVersion: 1,
    configuration: { messages: 5_000, rts: "-N1" },
    metrics: {
      expected: 5_000,
      completed: 5_000,
      acknowledged: 5_000,
      throughputPerSecond: 100_000,
      latencyP95Ms: 10,
      latencyP99Ms: 12,
      shutdownLatencyMs: 2,
      allocatedBytesPerMessage: 1_000,
      maxLiveBytes: 1_000_000,
      ...overrides,
    },
  };
}

function dataset(label: string, transform: (value: PerformanceSample) => PerformanceSample = (value) => value): PerformanceDataset {
  return {
    schemaVersion: 1,
    label,
    environment: {
      machineId: "fixture-machine",
      platform: "fixture-platform",
      compiler: "ghc-9.12.4",
      optimization: "O2",
      rtsFlags: "-N1 -T -A32m",
      capabilities: 1,
      services: {},
    },
    source: {
      productionSha: label === "baseline" ? "a".repeat(40) : "b".repeat(40),
      harnessSha: "c".repeat(40),
      solverPlanHash: "d".repeat(64),
    },
    samples: Array.from({ length: 10 }, (_, index) => transform(sample(index + 1))),
  };
}

describe("paired performance comparator", () => {
  test("passes a matched candidate inside every confidence-bound budget", () => {
    const verdict = comparePerformance(dataset("baseline"), dataset("candidate"), budgets);
    expect(verdict.status).toBe("pass");
    expect(verdict.errors).toEqual([]);
    expect(verdict.results).toHaveLength(6);
    expect(verdict.results.every((result) => result.status === "pass")).toBe(true);
  });

  test("fails a confident throughput regression", () => {
    const candidate = dataset("candidate", (value) => ({
      ...value,
      metrics: { ...value.metrics, throughputPerSecond: 90_000 },
    }));
    const verdict = comparePerformance(dataset("baseline"), candidate, budgets);
    expect(verdict.status).toBe("fail");
    expect(verdict.results.find((result) => result.metric === "throughputPerSecond")?.status).toBe("fail");
  });

  test("reports noisy evidence that crosses the limit as inconclusive", () => {
    const candidate = dataset("candidate", (value) => ({
      ...value,
      metrics: {
        ...value.metrics,
        throughputPerSecond: Number(value.pairId.split("-")[1]) % 2 === 0 ? 80_000 : 120_000,
      },
    }));
    const verdict = comparePerformance(dataset("baseline"), candidate, budgets);
    expect(verdict.status).toBe("inconclusive");
    expect(verdict.results.find((result) => result.metric === "throughputPerSecond")?.status).toBe("inconclusive");
  });

  test("rejects missing pairs, mismatched environments, and dropped work", () => {
    const candidate = dataset("candidate");
    candidate.environment.machineId = "another-machine";
    candidate.samples.pop();
    candidate.samples[0].metrics.acknowledged = 4_999;
    const verdict = comparePerformance(dataset("baseline"), candidate, budgets);
    expect(verdict.status).toBe("fail");
    expect(verdict.errors.join("\n")).toContain("environment mismatch");
    expect(verdict.errors.join("\n")).toContain("missing matched sample");
    expect(verdict.errors.join("\n")).toContain("dropped work");
  });

  test("rejects a dataset that omits a mandatory scenario from both variants", () => {
    const requiredBudgets: PerformanceBudgets = {
      ...budgets,
      requiredScenarios: ["serial-small-inbox", "graceful-shutdown-drain"],
    };
    const verdict = comparePerformance(dataset("baseline"), dataset("candidate"), requiredBudgets);
    expect(verdict.status).toBe("fail");
    expect(verdict.errors).toContain("required scenario missing: graceful-shutdown-drain");
  });

  test("uses calibrated absolute limits when a baseline is near zero", () => {
    const absoluteBudgets: PerformanceBudgets = {
      ...budgets,
      metrics: {
        idleCpuPercent: {
          direction: "lower-is-better",
          relativeLimit: 0.05,
          nearZeroThreshold: 0.1,
          absoluteDelta: 1,
          absoluteMaximum: 2,
        },
      },
    };
    const baseline = dataset("baseline", (value) => ({
      ...value,
      metrics: { ...value.metrics, idleCpuPercent: 0.05 },
    }));
    const candidate = dataset("candidate", (value) => ({
      ...value,
      metrics: { ...value.metrics, idleCpuPercent: 1.5 },
    }));
    const verdict = comparePerformance(baseline, candidate, absoluteBudgets);
    expect(verdict.status).toBe("fail");
    expect(verdict.results[0].method).toBe("paired-absolute");
  });

  test("is reproducible for a fixed bootstrap seed", () => {
    const first = comparePerformance(dataset("baseline"), dataset("candidate"), budgets);
    const second = comparePerformance(dataset("baseline"), dataset("candidate"), budgets);
    expect(second).toEqual(first);
  });

  test("rejects baseline-only calibration artifacts as final paired evidence", () => {
    const baseline = dataset("baseline");
    baseline.capture = {
      purpose: "pre-remediation-calibration",
      pairedComparisonEligible: false,
      warmupsPerScenario: 1,
    };
    const verdict = comparePerformance(baseline, dataset("candidate"), budgets);
    expect(verdict.status).toBe("fail");
    expect(verdict.errors.join("\n")).toContain("not eligible for a final paired comparison");
  });
});
