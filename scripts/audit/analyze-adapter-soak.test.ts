import { describe, expect, test } from "bun:test";
import { analyze, parseCsv, parseDeliveryLedger } from "./analyze-adapter-soak";

const header = "timestamp,elapsed_secs,produced,processed,failed,queue_depth,retained_bytes,max_live_bytes";

function csv(rows: string[]): string {
  return [header, ...rows.map((row) => `2026-09-21 00:00:00,${row}`)].join("\n");
}

const options = {
  input: "fixture.csv",
  ledger: "fixture.ledger.json",
  adapter: "fixture",
  scenario: "soak" as const,
  durationSeconds: 1800,
  restartAtSeconds: 900,
  targetRate: 100,
};

function deliveryLedger(produced: number, overrides: Record<string, unknown> = {}) {
  const identities = Array.from({ length: produced }, (_, index) => index);
  return parseDeliveryLedger(JSON.stringify({
    schemaVersion: 1,
    adapter: "fixture",
    runId: "fixture-run",
    status: "pass",
    producedIds: identities,
    processedIds: identities,
    duplicateIds: [],
    missingIds: [],
    unexpectedIds: [],
    malformedDeliveries: 0,
    ...overrides,
  }));
}

describe("adapter soak analyzer", () => {
  test("accepts drained work with bounded post-restart heap and backlog", () => {
    const rows = Array.from({ length: 31 }, (_, index) => {
      const elapsed = 900 + index * 30;
      const produced = elapsed * 100;
      const processed = index === 30 ? produced : produced - 10;
      const backlog = index === 30 ? 0 : 10;
      const retained = 1_000_000 + (index % 3) * 1_000;
      return `${elapsed},${produced},${processed},0,${backlog},${retained},1200000`;
    });
    const report = analyze(parseCsv(csv(rows)), options, deliveryLedger(180_000));
    expect(report.status).toBe("pass");
  });

  test("rejects dropped work and sustained retained-heap growth", () => {
    const rows = Array.from({ length: 31 }, (_, index) => {
      const elapsed = 900 + index * 30;
      const produced = elapsed * 100;
      const processed = produced - 1;
      const retained = 1_000_000 + index * 100_000;
      return `${elapsed},${produced},${processed},0,1,${retained},5000000`;
    });
    const report = analyze(parseCsv(csv(rows)), options, deliveryLedger(180_000, {
      status: "fail",
      processedIds: Array.from({ length: 179_999 }, (_, index) => index),
      missingIds: [179_999],
    }));
    expect(report.status).toBe("fail");
    expect(report.errors.join(" ")).toContain("does not equal produced");
    expect(report.errors.join(" ")).toContain("retained heap");
  });

  test("uses a bounded post-restart warmup for a short sustainable capture", () => {
    const sustainableOptions = {
      ...options,
      scenario: "sustainable" as const,
      durationSeconds: 120,
      restartAtSeconds: 60,
      targetRate: 20,
    };
    const rows = Array.from({ length: 25 }, (_, index) => {
      const elapsed = index * 5;
      const produced = elapsed * 20;
      return `${elapsed},${produced},${produced},0,0,1000000,1200000`;
    });
    const report = analyze(parseCsv(csv(rows)), sustainableOptions, deliveryLedger(2_400));
    expect(report.status).toBe("pass");
    expect(report.postRestartTrendSampleCount).toBeGreaterThanOrEqual(3);
  });

  test("rejects a duplicate balancing a missing delivery despite equal aggregate counts", () => {
    const shortOptions = {
      ...options,
      scenario: "sustainable" as const,
      durationSeconds: 10,
      restartAtSeconds: 5,
      targetRate: 1,
    };
    const rows = [
      "0,0,0,0,0,1000000,1200000",
      "5,5,5,0,0,1000000,1200000",
      "8,8,8,0,0,1000000,1200000",
      "9,9,9,0,0,1000000,1200000",
      "10,10,10,0,0,1000000,1200000",
    ];
    const ledger = deliveryLedger(10, {
      status: "fail",
      processedIds: [0, 1, 2, 3, 4, 5, 6, 7, 8],
      duplicateIds: [0],
      missingIds: [9],
    });
    const report = analyze(parseCsv(csv(rows)), shortOptions, ledger);
    expect(report.status).toBe("fail");
    expect(report.errors.join(" ")).toContain("duplicate identities");
    expect(report.errors.join(" ")).toContain("missing identities");
  });
});
