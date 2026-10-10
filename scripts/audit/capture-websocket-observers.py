#!/usr/bin/env python3
"""Capture alternating, identical-harness sustained real WebSocket observer pairs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', type=Path, required=True)
parser.add_argument('--candidate', type=Path, default=Path.cwd())
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--pairs', type=int, default=10)
parser.add_argument('--clients', type=int, nargs='+', choices=[1, 16, 64], default=[1, 16, 64])
parser.add_argument('--rts-flags', default='-N4 -T -A32m')
parser.add_argument('--resume', action='store_true')
parser.add_argument('--constraint', action='append', default=[])
parser.add_argument('--messages', type=int, default=2_000_000)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
if not args.resume and any((args.output / (name + '.json')).exists() for name in ['baseline', 'candidate']):
    raise SystemExit('Use a fresh output directory or --resume; existing datasets are not overwritten')
rts_flags = shlex.split(args.rts_flags)
capability_flags = [flag[2:] for flag in rts_flags if flag.startswith('-N')]
if len(capability_flags) != 1 or not capability_flags[0].isdigit() or int(capability_flags[0]) <= 0:
    raise SystemExit('Specify exactly one explicit positive -N capability count')
roots = {'baseline': args.baseline.resolve(), 'candidate': args.candidate.resolve()}

def command(root, *argv):
    return subprocess.check_output(argv, cwd=root, text=True).strip()

def sha(data):
    return hashlib.sha256(data).hexdigest()

for root in roots.values():
    if command(root, 'git', 'status', '--porcelain', '--untracked-files=all', '--', 'shibuya-core/src', 'shibuya-metrics/src'):
        raise SystemExit('Commit production source changes before capturing: ' + str(root))
    subprocess.run(['cabal', 'build', 'metrics-observer-load'] + ['--constraint=' + value for value in args.constraint], cwd=root, check=True, stdout=subprocess.DEVNULL)

harnesses = {name: sha((root / 'shibuya-metrics/bench/ObserverLoad.hs').read_bytes()) for name, root in roots.items()}
if len(set(harnesses.values())) != 1:
    raise SystemExit('Observer harness differs between checkouts')
solvers = {}
for name, root in roots.items():
    plan = json.loads((root / 'dist-newstyle/cache/plan.json').read_text())
    # Ignore checkout paths, local component IDs and source hashes. Match every
    # selected package/version, not merely the WebSocket subset.
    solvers[name] = sorted(set((item['pkg-name'], item['pkg-version']) for item in plan['install-plan']))
if solvers['baseline'] != solvers['candidate']:
    raise SystemExit('Selected package/version sets differ')
(args.output / 'selected-packages.json').write_text(json.dumps(solvers['baseline'], indent=2) + '\n')
solver_hash = sha(json.dumps(solvers['baseline'], separators=(',', ':')).encode())
environment = dict(machineId=command(args.candidate, 'sysctl', '-n', 'hw.model'),
                   platform=platform.system() + '-' + platform.machine(),
                   compiler=command(args.candidate, 'ghc', '--numeric-version'),
                   optimization='O1 libraries / O2 harness', rtsFlags=args.rts_flags,
                   capabilities=int(capability_flags[0]), services={})
datasets = {name: dict(schemaVersion=1, label='ep48-' + name,
                       capture=dict(purpose='sustained-real-observers', pairedComparisonEligible=True,
                                    warmupsPerScenario=1, ordering='baseline first on odd pairs; candidate first on even pairs'),
                       environment=environment,
                       source=dict(productionSha=command(root, 'git', 'rev-parse', 'HEAD'),
                                   harnessSha=harnesses[name], solverPlanHash=solver_hash), samples=[])
            for name, root in roots.items()}
if args.resume:
    for name, expected in datasets.items():
        previous = json.loads((args.output / (name + '.json')).read_text())
        if previous['source'] != expected['source'] or previous['environment'] != expected['environment']:
            raise SystemExit('Resume source or controlled environment differs')
        if any(sample['configuration']['messages'] != args.messages for sample in previous['samples']):
            raise SystemExit('Resume message count differs')
        capture = previous['capture']
        capture.setdefault('phaseEndPairCounts', [max(s['ordinal'] for s in previous['samples'])]).append(args.pairs)
        warmups = capture.setdefault('warmupsByScenario', {
            'websocket-observers-' + str(clients): capture['warmupsPerScenario'] for clients in [1, 16, 64]})
        for clients in args.clients:
            scenario = 'websocket-observers-' + str(clients)
            if sum(sample['scenario'] == scenario for sample in previous['samples']) < args.pairs:
                warmups[scenario] += 1
        capture['warmupsPerScenario'] = min(warmups.values())
        capture.setdefault('extensions', []).append(dict(clients=args.clients, targetPairs=args.pairs))
        datasets[name] = previous
binaries = {name: command(root, 'cabal', 'list-bin', 'metrics-observer-load') for name, root in roots.items()}
metrics = ['throughputPerSecond', 'latencyP95Ms', 'latencyP99Ms', 'allocatedBytesPerMessage', 'maxLiveBytes', 'shutdownLatencyMs']
for clients in args.clients:
    scenario = 'websocket-observers-' + str(clients)
    def run(name, suffix):
        path = (args.output / (name + '-' + str(clients) + '-' + suffix + '.json')).resolve()
        env = dict(os.environ, CLIENTS=str(clients), MESSAGES=str(args.messages), OUTPUT_JSON=str(path))
        subprocess.run([binaries[name], '+RTS', *rts_flags, '-RTS'],
                       cwd=roots[name], env=env, stdout=subprocess.DEVNULL, check=True, timeout=60)
        return json.loads(path.read_text())
    counts = [sum(sample['scenario'] == scenario for sample in datasets[name]['samples']) for name in roots]
    if counts[0] != counts[1]:
        raise SystemExit('Resume has an unmatched pair')
    if counts[0] >= args.pairs:
        continue
    for name in roots:
        run(name, 'warmup' if not args.resume else 'resume-warmup')
    for ordinal in range(counts[0] + 1, args.pairs + 1):
        for name in (['baseline', 'candidate'] if ordinal % 2 else ['candidate', 'baseline']):
            raw = run(name, f'{ordinal:02}')
            if raw['observerFrames'] <= 0:
                raise SystemExit('No sustained application frames were observed')
            if raw['finalWebSocketConnections'] != 0 or raw['shutdownLatencyMs'] > 5100:
                raise SystemExit('Connection accounting or shutdown deadline failed')
            datasets[name]['samples'].append(dict(
                pairId=f'{scenario}-{ordinal:02}', ordinal=ordinal,
                sampleId=f'{name}-{scenario}-{ordinal:02}', scenario=scenario, workloadVersion=1,
                configuration=dict(clients=clients, slowReaders=(clients+3)//4, readerIntervalUs=100000,
                                   pushIntervalUs=10000, inboxSize=16, messages=args.messages,
                                   ordering='Unordered', concurrency='Serial', observerFidelity='real-websocket'),
                metrics=dict(expected=args.messages, completed=raw['completed'], acknowledged=raw['completed'],
                             **{metric: raw[metric] for metric in metrics})))
        for name, data in datasets.items():
            (args.output / (name + '.json')).write_text(json.dumps(data, indent=2) + '\n')
        print(f'{scenario}: pair {ordinal}/{args.pairs} captured', flush=True)
