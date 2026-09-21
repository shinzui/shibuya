import { describe, expect, test } from "bun:test";
import { analyze, parseCsv } from "./analyze-adapter-soak";

const header = "timestamp,elapsed_secs,produced,processed,failed,queue_depth,retained_bytes,max_live_bytes";

function csv(rows: string[]): string {
  return [header, ...rows.map((row) => `2026-09-21 00:00:00,${row}`)].join("\n");
}

const options = {
  input: "fixture.csv",
  adapter: "fixture",
  scenario: "soak" as const,
  durationSeconds: 1800,
  restartAtSeconds: 900,
  targetRate: 100,
};

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
    const report = analyze(parseCsv(csv(rows)), options);
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
    const report = analyze(parseCsv(csv(rows)), options);
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
    const report = analyze(parseCsv(csv(rows)), sustainableOptions);
    expect(report.status).toBe("pass");
    expect(report.postRestartTrendSampleCount).toBeGreaterThanOrEqual(3);
  });
});
