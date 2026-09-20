#!/usr/bin/env bun

import { existsSync, readFileSync } from "node:fs";
import { isAbsolute, relative, resolve } from "node:path";

type JsonRecord = Record<string, unknown>;

export interface ValidationOptions {
  root?: string;
}

export interface ValidationReport {
  errors: string[];
  exclusions: string[];
  findingCount: number;
  boundaryCount: number;
  mandatoryCellCount: number;
}

const dispositions = new Set([
  "open",
  "fixed",
  "disproved",
  "accepted",
  "waived",
  "out-of-scope",
]);
const kinds = new Set(["defect", "concern", "limitation", "assumption", "verification"]);
const confirmations = new Set(["runtime", "source", "verified", "documented", "unconfirmed"]);
const caseNames = ["normal", "synchronousException", "cancellation", "timeout", "repeatedStop"];

function record(value: unknown): JsonRecord | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonRecord)
    : undefined;
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function string(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0 ? value : undefined;
}

function strings(value: unknown): string[] {
  return array(value).filter((item): item is string => typeof item === "string");
}

function duplicateValues(values: string[]): string[] {
  const seen = new Set<string>();
  const duplicates = new Set<string>();
  for (const value of values) {
    if (seen.has(value)) duplicates.add(value);
    seen.add(value);
  }
  return [...duplicates].sort();
}

function localPathError(root: string, path: string): string | undefined {
  if (isAbsolute(path)) return "must be repository-relative";
  const resolved = resolve(root, path);
  const withinRoot = relative(root, resolved);
  if (withinRoot === ".." || withinRoot.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`)) {
    return "escapes the repository root";
  }
  if (!existsSync(resolved)) return "does not exist";
  return undefined;
}

function requireLocalPath(errors: string[], root: string, label: string, value: unknown): void {
  const path = string(value);
  if (!path) {
    errors.push(`${label}: missing local path`);
    return;
  }
  const error = localPathError(root, path);
  if (error) errors.push(`${label}: ${path} ${error}`);
}

function requireRegressionTest(
  errors: string[],
  root: string,
  label: string,
  value: unknown,
): void {
  if (typeof value === "string") {
    requireLocalPath(errors, root, label, value);
    return;
  }

  const external = record(value);
  const uri = string(external?.uri);
  const path = string(external?.path);
  if (!uri?.startsWith("mori://") || !path) {
    errors.push(`${label}: expected a local path or { uri: canonical mori:// URI, path: project-relative path }`);
    return;
  }
  if (isAbsolute(path)) {
    errors.push(`${label}.path: ${path} must be project-relative`);
  } else if (path.split(/[\\/]/).includes("..")) {
    errors.push(`${label}.path: ${path} escapes the external project root`);
  }
}

function completeDecision(value: unknown): boolean {
  const decision = record(value);
  return Boolean(
    decision &&
      string(decision.by) &&
      /^\d{4}-\d{2}-\d{2}$/.test(string(decision.date) ?? "") &&
      string(decision.reason) &&
      string(decision.affectedScope),
  );
}

function completeWaiver(value: unknown): boolean {
  const waiver = record(value);
  return Boolean(
    waiver &&
      waiver.approverKind === "human" &&
      string(waiver.approvedBy) &&
      string(waiver.rationale) &&
      string(waiver.expiresAt) &&
      string(waiver.affectedScope) &&
      strings(waiver.compensatingControls).length > 0,
  );
}

function sameStringMap(leftValue: unknown, right: Map<string, string>): boolean {
  const left = record(leftValue);
  if (!left) return false;
  const keys = Object.keys(left).sort();
  const expectedKeys = [...right.keys()].sort();
  if (keys.length !== expectedKeys.length || keys.some((key, index) => key !== expectedKeys[index])) {
    return false;
  }
  return keys.every((key) => left[key] === right.get(key));
}

export function validateInventory(value: unknown, options: ValidationOptions = {}): ValidationReport {
  const root = resolve(options.root ?? process.cwd());
  const errors: string[] = [];
  const exclusions: string[] = [];
  const inventory = record(value);
  if (!inventory) {
    return { errors: ["inventory: expected a JSON object"], exclusions, findingCount: 0, boundaryCount: 0, mandatoryCellCount: 0 };
  }

  if (inventory.schemaVersion !== 1) errors.push("inventory.schemaVersion: expected 1");

  const releaseScope = record(inventory.releaseScope);
  const includedComponents = strings(releaseScope?.includedComponents);
  const excludedRecords = array(releaseScope?.excludedComponents).map(record).filter(Boolean) as JsonRecord[];
  const excludedComponents = excludedRecords.map((item) => string(item.component)).filter(Boolean) as string[];
  for (const duplicate of duplicateValues(includedComponents)) {
    errors.push(`releaseScope.includedComponents: duplicate ${duplicate}`);
  }
  for (const duplicate of duplicateValues(excludedComponents)) {
    errors.push(`releaseScope.excludedComponents: duplicate ${duplicate}`);
  }
  for (const component of includedComponents.filter((item) => excludedComponents.includes(item))) {
    errors.push(`releaseScope: component appears as both included and excluded: ${component}`);
  }
  excludedRecords.forEach((item, index) => {
    const decision = record(item.decision);
    if (!string(item.component) || !decision || !string(decision.by) || !string(decision.date) || !string(decision.reason)) {
      errors.push(`releaseScope.excludedComponents[${index}]: exclusion requires component and named, dated reason`);
    }
  });

  const owners = strings(inventory.owners);
  for (const duplicate of duplicateValues(owners)) errors.push(`owners: duplicate ${duplicate}`);
  owners.forEach((owner, index) => requireLocalPath(errors, root, `owners[${index}]`, owner));
  const ownerSet = new Set(owners);

  const auditReviewIds = strings(inventory.auditReviewIds);
  for (const duplicate of duplicateValues(auditReviewIds)) errors.push(`auditReviewIds: duplicate ${duplicate}`);
  if (auditReviewIds.length === 0) errors.push("auditReviewIds: expected at least one review ID");
  const reviewSet = new Set(auditReviewIds);

  const findings = array(inventory.findings).map(record).filter(Boolean) as JsonRecord[];
  if (findings.length === 0) errors.push("findings: expected at least one finding");
  const findingIds = findings.map((item) => string(item.id)).filter(Boolean) as string[];
  for (const duplicate of duplicateValues(findingIds)) errors.push(`findings: duplicate ID ${duplicate}`);

  const representedReviews = new Set<string>();
  findings.forEach((finding, index) => {
    const label = string(finding.id) ?? `findings[${index}]`;
    const reviewId = string(finding.reviewId);
    if (!reviewId) errors.push(`${label}: missing reviewId`);
    else {
      representedReviews.add(reviewId);
      if (!reviewSet.has(reviewId)) errors.push(`${label}: reviewId ${reviewId} is not declared in auditReviewIds`);
    }

    const kind = string(finding.kind);
    if (!kind || !kinds.has(kind)) errors.push(`${label}: unknown kind ${String(finding.kind)}`);
    const confirmation = string(finding.confirmation);
    if (!confirmation || !confirmations.has(confirmation)) {
      errors.push(`${label}: unknown confirmation ${String(finding.confirmation)}`);
    }
    if (!string(finding.component)) errors.push(`${label}: missing component`);
    if (!string(finding.claim)) errors.push(`${label}: missing claim`);
    if (!string(finding.invariant)) errors.push(`${label}: missing invariant`);

    const source = record(finding.source);
    if (!source) errors.push(`${label}: missing source record`);
    else {
      requireLocalPath(errors, root, `${label}.source.path`, source.path);
      if (!/^[0-9a-f]{40}$/.test(string(source.reviewedSha) ?? "")) {
        errors.push(`${label}.source.reviewedSha: expected a full 40-character Git SHA`);
      }
    }

    const disposition = record(finding.disposition);
    const status = string(disposition?.status);
    if (!status || !dispositions.has(status)) {
      errors.push(`${label}: unknown disposition ${String(disposition?.status)}`);
      return;
    }

    const owner = finding.owner === null ? undefined : string(finding.owner);
    if (owner && !ownerSet.has(owner)) errors.push(`${label}: owner is not declared in owners: ${owner}`);
    if (status !== "out-of-scope" && !owner) errors.push(`${label}: missing owner`);

    const regressionTests = array(finding.regressionTests);
    regressionTests.forEach((test, testIndex) =>
      requireRegressionTest(errors, root, `${label}.regressionTests[${testIndex}]`, test),
    );
    array(finding.evidence).forEach((evidenceValue, evidenceIndex) => {
      const evidence = record(evidenceValue);
      if (!evidence) {
        errors.push(`${label}.evidence[${evidenceIndex}]: expected an object`);
        return;
      }
      if (evidence.path !== undefined) {
        requireLocalPath(errors, root, `${label}.evidence[${evidenceIndex}].path`, evidence.path);
      } else if (!string(evidence.uri)?.startsWith("mori://")) {
        errors.push(`${label}.evidence[${evidenceIndex}]: expected local path or canonical mori:// URI`);
      }
    });

    if (status === "fixed") {
      if (!/^[0-9a-f]{40}$/.test(string(finding.fixSha) ?? "")) {
        errors.push(`${label}: fixed finding requires a full 40-character fixSha`);
      }
      if (regressionTests.length === 0) errors.push(`${label}: fixed finding requires a regression test`);
    }
    if (status === "disproved" && confirmation === "unconfirmed") {
      errors.push(`${label}: disproved finding requires confirmation evidence, not unconfirmed status`);
    }
    if (status === "accepted") {
      if (kind === "defect" || kind === "concern") {
        errors.push(`${label}: defects and concerns cannot use accepted; use fixed, disproved, waived, or out-of-scope`);
      }
      if (!string(disposition?.rationale)) errors.push(`${label}: accepted disposition requires rationale`);
    }
    if (status === "waived" && !completeWaiver(disposition?.waiver)) {
      errors.push(`${label}: waiver requires a named human approver, rationale, expiry, scope, and compensating controls`);
    }
    if (status === "out-of-scope") {
      const component = string(finding.component);
      if (finding.candidateScope !== "out-of-scope") errors.push(`${label}: out-of-scope disposition requires candidateScope out-of-scope`);
      if (!component || !excludedComponents.includes(component)) {
        errors.push(`${label}: out-of-scope component is not declared in releaseScope.excludedComponents`);
      }
      if (component && includedComponents.includes(component)) {
        errors.push(`${label}: cannot exclude a component that is in the release candidate`);
      }
      if (!completeDecision(disposition?.decision)) {
        errors.push(`${label}: out-of-scope disposition requires named human decision, date, reason, and affectedScope`);
      }
      exclusions.push(`${label}: ${component ?? "unknown component"}`);
    } else if (finding.candidateScope === "out-of-scope") {
      errors.push(`${label}: candidateScope out-of-scope requires out-of-scope disposition`);
    }
  });

  for (const reviewId of auditReviewIds) {
    if (!representedReviews.has(reviewId)) errors.push(`auditReviewIds: ${reviewId} has no inventory entry`);
  }

  const boundaries = array(inventory.boundaries).map(record).filter(Boolean) as JsonRecord[];
  const boundaryIds = boundaries.map((item) => string(item.id)).filter(Boolean) as string[];
  for (const duplicate of duplicateValues(boundaryIds)) errors.push(`boundaries: duplicate ID ${duplicate}`);
  let mandatoryCellCount = 0;
  boundaries.forEach((boundary, index) => {
    const label = string(boundary.id) ?? `boundaries[${index}]`;
    const owner = boundary.owner === null ? undefined : string(boundary.owner);
    if (owner && !ownerSet.has(owner)) errors.push(`${label}: owner is not declared in owners: ${owner}`);
    const cases = record(boundary.cases);
    if (!cases) {
      errors.push(`${label}: missing cases`);
      return;
    }
    for (const name of caseNames) {
      const cell = record(cases[name]);
      if (!cell) {
        errors.push(`${label}.${name}: missing lifecycle case`);
        continue;
      }
      if (cell.requirement === "mandatory") {
        mandatoryCellCount += 1;
        if (!owner) errors.push(`${label}.${name}: mandatory case requires a boundary owner`);
        if (cell.status !== "open" && cell.status !== "passed") {
          errors.push(`${label}.${name}: mandatory status must be open or passed`);
        }
        if (cell.status === "passed" && strings(cell.evidence).length === 0) {
          errors.push(`${label}.${name}: passed case requires evidence`);
        }
      } else if (cell.requirement === "not-applicable") {
        if (!string(cell.reason)) errors.push(`${label}.${name}: not-applicable case requires a reason`);
      } else {
        errors.push(`${label}.${name}: requirement must be mandatory or not-applicable`);
      }
      strings(cell.evidence).forEach((path, evidenceIndex) =>
        requireLocalPath(errors, root, `${label}.${name}.evidence[${evidenceIndex}]`, path),
      );
    }
    for (const extra of Object.keys(cases).filter((name) => !caseNames.includes(name))) {
      errors.push(`${label}: unknown lifecycle case ${extra}`);
    }
  });

  return {
    errors,
    exclusions: exclusions.sort(),
    findingCount: findings.length,
    boundaryCount: boundaries.length,
    mandatoryCellCount,
  };
}

export function validateRelease(
  inventoryValue: unknown,
  releaseValue: unknown,
  options: ValidationOptions = {},
): ValidationReport {
  const root = resolve(options.root ?? process.cwd());
  const report = validateInventory(inventoryValue, { root });
  const errors = [...report.errors];
  const inventory = record(inventoryValue);
  const release = record(releaseValue);
  if (!inventory || !release) {
    if (!release) errors.push("release: expected a JSON object");
    return { ...report, errors };
  }

  if (release.schemaVersion !== 1) errors.push("release.schemaVersion: expected 1");
  if (!string(release.candidateId)) errors.push("release.candidateId: missing");
  requireLocalPath(errors, root, "release.inventory", release.inventory);
  if (!string(release.compiler)) errors.push("release.compiler: missing");
  if (!string(release.platform)) errors.push("release.platform: missing");
  if (!string(release.createdAt)) errors.push("release.createdAt: missing");
  const solverPlanHash = string(release.solverPlanHash);
  if (!/^[0-9a-f]{64}$/.test(solverPlanHash ?? "")) {
    errors.push("release.solverPlanHash: expected a 64-character SHA-256 hash");
  }
  const commands = array(release.commands).map(record).filter(Boolean) as JsonRecord[];
  if (commands.length === 0) errors.push("release.commands: record at least one command and exit code");
  commands.forEach((command, index) => {
    const label = `release.commands[${index}]`;
    if (!string(command.command)) errors.push(`${label}: missing command`);
    if (typeof command.exitCode !== "number") errors.push(`${label}: missing numeric exitCode`);
    if (!string(command.startedAt) || !string(command.finishedAt)) {
      errors.push(`${label}: missing start or finish timestamp`);
    }
  });
  array(release.services).forEach((serviceValue, index) => {
    const service = record(serviceValue);
    if (!service || !string(service.name) || !string(service.version)) {
      errors.push(`release.services[${index}]: expected service name and version`);
    }
  });

  const releaseScope = record(inventory.releaseScope);
  const includedComponents = strings(releaseScope?.includedComponents).sort();
  const projects = array(release.projects).map(record).filter(Boolean) as JsonRecord[];
  const projectComponents = projects.map((project) => string(project.component)).filter(Boolean) as string[];
  for (const duplicate of duplicateValues(projectComponents)) errors.push(`release.projects: duplicate component ${duplicate}`);
  const sortedProjectComponents = [...projectComponents].sort();
  if (
    sortedProjectComponents.length !== includedComponents.length ||
    sortedProjectComponents.some((component, index) => component !== includedComponents[index])
  ) {
    errors.push("release.projects: must contain every and only included candidate component");
  }

  const candidateShas = new Map<string, string>();
  projects.forEach((project, index) => {
    const label = `release.projects[${index}]`;
    const component = string(project.component);
    const sha = string(project.sha);
    if (!component) errors.push(`${label}: missing component`);
    if (!/^[0-9a-f]{40}$/.test(sha ?? "")) errors.push(`${label}: expected full 40-character Git SHA`);
    if (project.clean !== true) errors.push(`${label}: final release evidence requires clean committed sources`);
    if (!record(project.packageVersions) || Object.keys(record(project.packageVersions) ?? {}).length === 0) {
      errors.push(`${label}: packageVersions must identify at least one package`);
    } else if (Object.values(record(project.packageVersions) ?? {}).some((version) => !string(version))) {
      errors.push(`${label}: every package version must be a nonempty string`);
    }
    if (component && sha) candidateShas.set(component, sha);
  });

  const evidenceRuns = array(release.evidenceRuns).map(record).filter(Boolean) as JsonRecord[];
  const runIds = evidenceRuns.map((run) => string(run.id)).filter(Boolean) as string[];
  for (const duplicate of duplicateValues(runIds)) errors.push(`release.evidenceRuns: duplicate ID ${duplicate}`);
  const runSet = new Set(runIds);
  evidenceRuns.forEach((run, index) => {
    const label = string(run.id) ?? `release.evidenceRuns[${index}]`;
    if (!sameStringMap(run.sourceShas, candidateShas)) {
      errors.push(`${label}: stale candidate SHAs; evidence sourceShas must exactly match release.projects`);
    }
    if (run.solverPlanHash !== solverPlanHash) errors.push(`${label}: stale solver plan hash`);
    if (!string(run.command)) errors.push(`${label}: missing command`);
    if (run.exitCode !== 0) errors.push(`${label}: passing release evidence requires exitCode 0`);
    if (!string(run.timestamp)) errors.push(`${label}: missing timestamp`);
    if (!("seed" in run)) errors.push(`${label}: record a seed or explicit null`);
    const artifacts = strings(run.artifacts);
    if (artifacts.length === 0) errors.push(`${label}: expected at least one artifact`);
    artifacts.forEach((path, artifactIndex) =>
      requireLocalPath(errors, root, `${label}.artifacts[${artifactIndex}]`, path),
    );
  });

  const findings = array(inventory.findings).map(record).filter(Boolean) as JsonRecord[];
  const candidateFindings = findings.filter((finding) => record(finding.disposition)?.status !== "out-of-scope");
  const findingResults = array(release.findingResults).map(record).filter(Boolean) as JsonRecord[];
  const resultIds = findingResults.map((result) => string(result.findingId)).filter(Boolean) as string[];
  for (const duplicate of duplicateValues(resultIds)) errors.push(`release.findingResults: duplicate findingId ${duplicate}`);
  const resultById = new Map(
    findingResults.map((result) => [string(result.findingId) ?? "", result] as const),
  );

  candidateFindings.forEach((finding) => {
    const id = string(finding.id) ?? "unknown finding";
    const disposition = record(finding.disposition);
    const status = string(disposition?.status);
    const confirmation = string(finding.confirmation);
    if (status === "open") errors.push(`${id}: open finding blocks release`);
    if (confirmation === "unconfirmed" && status !== "disproved" && status !== "waived") {
      errors.push(`${id}: unconfirmed safety concern must be reproduced, disproved, or waived`);
    }
    const result = resultById.get(id);
    if (!result) {
      errors.push(`${id}: missing candidate-bound finding result`);
      return;
    }
    const expectedStatus = status === "accepted" ? "acknowledged" : status === "waived" ? "waived" : "passed";
    if (result.status !== expectedStatus) errors.push(`${id}: finding result status must be ${expectedStatus}`);
    const runId = string(result.evidenceRun);
    if (!runId || !runSet.has(runId)) errors.push(`${id}: finding result references unknown evidence run`);
  });
  for (const id of resultIds) {
    if (!candidateFindings.some((finding) => finding.id === id)) {
      errors.push(`release.findingResults: unknown or excluded findingId ${id}`);
    }
  }

  const boundaries = array(inventory.boundaries).map(record).filter(Boolean) as JsonRecord[];
  const mandatoryKeys: string[] = [];
  for (const boundary of boundaries) {
    const boundaryId = string(boundary.id);
    const cases = record(boundary.cases);
    if (!boundaryId || !cases) continue;
    for (const name of caseNames) {
      if (record(cases[name])?.requirement === "mandatory") mandatoryKeys.push(`${boundaryId}:${name}`);
    }
  }
  const matrixRuns = array(release.matrixRuns).map(record).filter(Boolean) as JsonRecord[];
  const matrixKeys = matrixRuns.map((run) => `${string(run.boundaryId) ?? ""}:${string(run.case) ?? ""}`);
  for (const duplicate of duplicateValues(matrixKeys)) errors.push(`release.matrixRuns: duplicate cell ${duplicate}`);
  const matrixByKey = new Map(matrixRuns.map((run, index) => [matrixKeys[index], run] as const));
  for (const key of mandatoryKeys) {
    const run = matrixByKey.get(key);
    if (!run) {
      errors.push(`${key}: missing mandatory matrix run`);
      continue;
    }
    if (run.status !== "passed") errors.push(`${key}: mandatory matrix run did not pass`);
    const evidenceRun = string(run.evidenceRun);
    if (!evidenceRun || !runSet.has(evidenceRun)) errors.push(`${key}: matrix cell references unknown evidence run`);
  }
  for (const key of matrixKeys) {
    if (!mandatoryKeys.includes(key)) errors.push(`release.matrixRuns: unknown or non-mandatory cell ${key}`);
  }

  const waiverRecords = array(release.waivers).map(record).filter(Boolean) as JsonRecord[];
  const waivedFindings = candidateFindings.filter((finding) => record(finding.disposition)?.status === "waived");
  for (const finding of waivedFindings) {
    const id = string(finding.id) ?? "unknown finding";
    const waiver = waiverRecords.find((item) => item.findingId === id);
    if (!waiver || !completeWaiver(waiver)) errors.push(`${id}: release waiver lacks named human approval or required controls`);
  }
  for (const waiver of waiverRecords) {
    const findingId = string(waiver.findingId);
    if (!findingId || !waivedFindings.some((finding) => finding.id === findingId)) {
      errors.push(`release.waivers: waiver does not correspond to a waived finding: ${findingId ?? "missing ID"}`);
    }
  }

  return { ...report, errors };
}

function readJson(path: string): unknown {
  return JSON.parse(readFileSync(path, "utf8"));
}

function printReport(mode: "Inventory" | "Release", report: ValidationReport): void {
  for (const exclusion of report.exclusions) console.log(`UNCERTIFIED: ${exclusion}`);
  if (report.errors.length > 0) {
    console.error(`${mode} invalid: ${report.errors.length} error(s)`);
    for (const error of report.errors) console.error(`- ${error}`);
    process.exitCode = 1;
    return;
  }
  console.log(
    `${mode} valid: ${report.findingCount} findings, ${report.boundaryCount} boundaries, ${report.mandatoryCellCount} mandatory cells, ${report.exclusions.length} exclusions.`,
  );
}

function usage(): never {
  console.error(
    "Usage: bun scripts/audit/validate-evidence.ts --inventory <findings.json> | --release <candidate.json>",
  );
  process.exit(2);
}

if (import.meta.main) {
  const [flag, path, ...rest] = process.argv.slice(2);
  if (rest.length > 0 || !path || (flag !== "--inventory" && flag !== "--release")) usage();
  const root = process.cwd();
  try {
    if (flag === "--inventory") {
      printReport("Inventory", validateInventory(readJson(resolve(root, path)), { root }));
    } else {
      const release = readJson(resolve(root, path));
      const releaseRecord = record(release);
      const inventoryPath = string(releaseRecord?.inventory);
      if (!inventoryPath) {
        printReport("Release", validateRelease({}, release, { root }));
      } else {
        printReport(
          "Release",
          validateRelease(readJson(resolve(root, inventoryPath)), release, { root }),
        );
      }
    }
  } catch (error) {
    console.error(`Validation failed to read input: ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  }
}
