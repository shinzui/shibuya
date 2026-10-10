#!/usr/bin/env python3
"""Run three behavioral controls in a disposable checkout; restore every mutation."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--checkout', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
root = args.checkout.resolve()
art = args.output.resolve()
if root == Path(__file__).resolve().parents[2]:
    raise SystemExit('Use a disposable worktree, not the working project checkout')
art.mkdir(parents=True, exist_ok=True)
queue = root / 'shibuya-metrics/src/Shibuya/Metrics/Outbound.hs'
ws = root / 'shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs'
original_q = queue.read_text()
original_w = ws.read_text()

def replace_once(source, before, after):
    if before not in source:
        raise RuntimeError('Mutation anchor missing: ' + before)
    return source.replace(before, after, 1)

def run(name, match):
    result = subprocess.run(
        ['cabal', 'test', 'shibuya-metrics', '--test-show-details=direct', '--test-options=--match ' + match],
        cwd=root, capture_output=True, text=True, timeout=180)
    output = result.stdout + result.stderr
    start = output.find('Running 1 test suites...')
    (art / (name + '.txt')).write_text(output[max(0, start):])
    if result.returncode == 0 or ('examples,' not in output and 'example,' not in output):
        raise RuntimeError(name + ' did not produce a behavioral failure: ' + output[-1500:])
    return dict(control=name, exitCode=result.returncode, failingTestMatch=match)

results = []
try:
    queue.write_text(replace_once(original_q, '    fits q =',
        '    fits q = any ((== Required) . retention) batch ||'))
    results.append(run('unlimited-required', 'bounded'))
    queue.write_text(original_q)
    ws.write_text(replace_once(original_w, '(writerLoop hooks config cs conn)',
        '(race_ (writerLoop hooks config cs conn) (writerLoop hooks config cs conn))'))
    results.append(run('second-writer', 'adjacent'))
    mutated = replace_once(original_w, 'closing :: !(TVar (Maybe CloseControl))',
        'closing :: !(TVar (Maybe CloseControl)), timerPulse :: !(TVar Int)')
    mutated = replace_once(mutated, '<*> newTVarIO Nothing', '<*> newTVarIO Nothing <*> newTVarIO 0')
    mutated = replace_once(mutated, '  msg <- WS.receiveData conn',
        "  msg <- WS.receiveData conn\n  atomically $ modifyTVar' cs.timerPulse (+ 1)")
    mutated = replace_once(mutated, 'shutdown <- hooks.waitForPush config.wsPushIntervalUs state',
        'shutdown <- resettingWait config.wsPushIntervalUs state cs')
    mutated += r'''
resettingWait :: Int -> WebSocketState -> ConnectionState -> IO Bool
resettingWait interval state cs = do
  pulse <- readTVarIO cs.timerPulse
  elapsed <- registerDelay interval
  result <- atomically $
    (readTVar state.shutdownRequested >>= \ready -> check ready >> pure (Just True))
    `orElse` (readTVar elapsed >>= \ready -> check ready >> pure (Just False))
    `orElse` (readTVar cs.timerPulse >>= \n -> check (n /= pulse) >> pure Nothing)
  maybe (resettingWait interval state cs) pure result
'''
    ws.write_text(mutated)
    results.append(run('receive-resets-timer', 'continuous'))
finally:
    queue.write_text(original_q)
    ws.write_text(original_w)
report = dict(productionSha=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
              queueSourceSha256=hashlib.sha256(original_q.encode()).hexdigest(),
              websocketSourceSha256=hashlib.sha256(original_w.encode()).hexdigest(), controls=results)
(art / 'mutation-controls.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report))
