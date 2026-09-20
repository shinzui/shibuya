import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { validateInventory, validateRelease } from "./validate-evidence";

const root = resolve(import.meta.dir, "../..");

function load(path: string): any {
  return JSON.parse(readFileSync(resolve(root, path), "utf8"));
}

function clone<T>(value: T): T {
  return structuredClone(value);
}

function inventoryFixture(): any {
  return load("scripts/audit/fixtures/valid-inventory.json");
}

function releaseFixture(): any {
  return load("scripts/audit/fixtures/valid-release.json");
}

function errorText(report: ReturnType<typeof validateInventory>): string {
  return report.errors.join("\n");
}

describe("inventory validation", () => {
  test("accepts the complete REV-1 through REV-16 inventory", () => {
    const report = validateInventory(load("docs/audits/lifecycle-release/findings.json"), { root });
    expect(report.errors).toEqual([]);
    expect(report.findingCount).toBe(52);
    expect(report.boundaryCount).toBe(15);
    expect(report.mandatoryCellCount).toBe(70);
    expect(report.exclusions).toHaveLength(5);
  });

  test("rejects unknown dispositions", () => {
    const inventory = inventoryFixture();
    inventory.findings[0].disposition.status = "mostly-fixed";
    expect(errorText(validateInventory(inventory, { root }))).toContain("unknown disposition mostly-fixed");
  });

  test("rejects duplicate finding IDs", () => {
    const inventory = inventoryFixture();
    inventory.findings.push(clone(inventory.findings[0]));
    expect(errorText(validateInventory(inventory, { root }))).toContain("duplicate ID REV-1-F1");
  });

  test("rejects missing owners on in-scope work", () => {
    const inventory = inventoryFixture();
    inventory.findings[0].owner = null;
    expect(errorText(validateInventory(inventory, { root }))).toContain("REV-1-F1: missing owner");
  });

  test("rejects nonexistent local evidence", () => {
    const inventory = inventoryFixture();
    inventory.findings[0].evidence = [{ path: "scripts/audit/fixtures/missing.txt" }];
    expect(errorText(validateInventory(inventory, { root }))).toContain("missing.txt does not exist");
  });

  test("rejects fixed findings without regression tests", () => {
    const inventory = inventoryFixture();
    inventory.findings[0].regressionTests = [];
    expect(errorText(validateInventory(inventory, { root }))).toContain(
      "REV-1-F1: fixed finding requires a regression test",
    );
  });

  test("rejects unjustified exclusions", () => {
    const inventory = inventoryFixture();
    delete inventory.findings[1].disposition.decision.by;
    expect(errorText(validateInventory(inventory, { root }))).toContain(
      "out-of-scope disposition requires named human decision",
    );
  });

  test("rejects excluding an in-scope component", () => {
    const inventory = inventoryFixture();
    inventory.releaseScope.excludedComponents.push({
      component: "mori://example/in-scope/packages/core",
      decision: { by: "fixture owner", date: "2026-09-20", reason: "invalid" },
    });
    inventory.findings[0].candidateScope = "out-of-scope";
    inventory.findings[0].owner = null;
    inventory.findings[0].disposition = {
      status: "out-of-scope",
      decision: {
        by: "fixture owner",
        date: "2026-09-20",
        reason: "invalid",
        affectedScope: "mori://example/in-scope",
      },
    };
    expect(errorText(validateInventory(inventory, { root }))).toContain(
      "cannot exclude a component that is in the release candidate",
    );
  });

  test("rejects an orphaned review and missing lifecycle case", () => {
    const inventory = inventoryFixture();
    inventory.auditReviewIds.push("REV-99");
    delete inventory.boundaries[0].cases.timeout;
    const errors = errorText(validateInventory(inventory, { root }));
    expect(errors).toContain("REV-99 has no inventory entry");
    expect(errors).toContain("fixture-core.timeout: missing lifecycle case");
  });
});

describe("release validation", () => {
  test("accepts candidate-matched evidence and surfaces exclusions", () => {
    const report = validateRelease(inventoryFixture(), releaseFixture(), { root });
    expect(report.errors).toEqual([]);
    expect(report.exclusions).toEqual([
      "REV-12-F1: mori://example/excluded/packages/adapter",
    ]);
  });

  test("rejects open and unconfirmed safety work", () => {
    const inventory = inventoryFixture();
    inventory.findings[0].confirmation = "unconfirmed";
    inventory.findings[0].regressionTests = [];
    inventory.findings[0].fixSha = null;
    inventory.findings[0].disposition = { status: "open" };
    const release = releaseFixture();
    release.findingResults = [];
    const errors = errorText(validateRelease(inventory, release, { root }));
    expect(errors).toContain("REV-1-F1: open finding blocks release");
    expect(errors).toContain("REV-1-F1: unconfirmed safety concern");
  });

  test("rejects a missing mandatory matrix run", () => {
    const release = releaseFixture();
    release.matrixRuns = release.matrixRuns.filter((run: any) => run.case !== "timeout");
    expect(errorText(validateRelease(inventoryFixture(), release, { root }))).toContain(
      "fixture-core:timeout: missing mandatory matrix run",
    );
  });

  test("rejects evidence after the candidate source SHA changes", () => {
    const release = releaseFixture();
    release.projects[0].sha = "5555555555555555555555555555555555555555";
    expect(errorText(validateRelease(inventoryFixture(), release, { root }))).toContain(
      "stale candidate SHAs",
    );
  });

  test("rejects evidence after the solver plan changes", () => {
    const release = releaseFixture();
    release.solverPlanHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    expect(errorText(validateRelease(inventoryFixture(), release, { root }))).toContain(
      "stale solver plan hash",
    );
  });

  test("rejects a waiver without named human approval and controls", () => {
    const inventory = inventoryFixture();
    inventory.findings[0].disposition = {
      status: "waived",
      waiver: {
        approverKind: "human",
        approvedBy: "fixture owner",
        rationale: "fixture rationale",
        expiresAt: "2026-10-20",
        affectedScope: "fixture release",
        compensatingControls: ["fixture control"],
      },
    };
    const release = releaseFixture();
    release.findingResults[0].status = "waived";
    release.waivers = [
      {
        findingId: "REV-1-F1",
        approverKind: "model",
        approvedBy: "fixture agent",
        rationale: "not human",
        expiresAt: "2026-10-20",
        affectedScope: "fixture release",
        compensatingControls: [],
      },
    ];
    expect(errorText(validateRelease(inventory, release, { root }))).toContain(
      "release waiver lacks named human approval",
    );
  });

  test("rejects a candidate that includes an excluded component", () => {
    const release = releaseFixture();
    release.projects.push({
      component: "mori://example/excluded/packages/adapter",
      sha: "6666666666666666666666666666666666666666",
      clean: true,
      packageVersions: { fixtureAdapter: "1.0.0" },
    });
    expect(errorText(validateRelease(inventoryFixture(), release, { root }))).toContain(
      "must contain every and only included candidate component",
    );
  });
});
