from pathlib import Path
import subprocess,json
root=Path('/tmp/shibuya-ep48-mutants')
art=Path('/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/audits/lifecycle-release/artifacts/ep48-websocket')
queue=root/'shibuya-metrics/src/Shibuya/Metrics/Outbound.hs'
ws=root/'shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs'
original_q=queue.read_text();original_w=ws.read_text()
def run(name,match):
    p=subprocess.run(['cabal','test','shibuya-metrics','--test-show-details=direct','--test-options=--match '+match],cwd=root,capture_output=True,text=True,timeout=180)
    output=p.stdout+p.stderr
    (art/(name+'.log')).write_text(output[output.find('Running 1 test suites...'):])
    if p.returncode==0 or ('examples,' not in output and 'example,' not in output): raise RuntimeError(name+' did not produce a behavioral failure: '+output[-1500:])
    return dict(control=name,exitCode=p.returncode,failingTestMatch=match)
results=[]
try:
    queue.write_text(original_q.replace('fits q =','fits q = any ((== Required) . retention) batch ||', 1))
    results.append(run('unlimited-required','bounded'))
    queue.write_text(original_q)
    ws.write_text(original_w.replace('race_ (writerLoop hooks config cs conn)','race_ (race_ (writerLoop hooks config cs conn) (writerLoop hooks config cs conn))'))
    results.append(run('second-writer','adjacent'))
    mutated=original_w.replace('closing :: !(TVar (Maybe CloseControl))','closing :: !(TVar (Maybe CloseControl)), timerPulse :: !(TVar Int)')
    mutated=mutated.replace('<*> newTVarIO Nothing','<*> newTVarIO Nothing <*> newTVarIO 0')
    mutated=mutated.replace('  msg <- WS.receiveData conn','  msg <- WS.receiveData conn\n  atomically $ modifyTVar\' cs.timerPulse (+ 1)')
    mutated=mutated.replace('shutdown <- hooks.waitForPush config.wsPushIntervalUs state','shutdown <- resettingWait config.wsPushIntervalUs state cs')
    mutated+='''\nresettingWait :: Int -> WebSocketState -> ConnectionState -> IO Bool
resettingWait interval state cs = do
  pulse <- readTVarIO cs.timerPulse
  elapsed <- registerDelay interval
  result <- atomically $
    (readTVar state.shutdownRequested >>= \\ready -> check ready >> pure (Just True))
    `orElse` (readTVar elapsed >>= \\ready -> check ready >> pure (Just False))
    `orElse` (readTVar cs.timerPulse >>= \\n -> check (n /= pulse) >> pure Nothing)
  maybe (resettingWait interval state cs) pure result
'''
    ws.write_text(mutated)
    results.append(run('receive-resets-timer','continuous'))
finally:
    queue.write_text(original_q);ws.write_text(original_w)
(art/'mutation-controls.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results))
