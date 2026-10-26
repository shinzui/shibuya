from pathlib import Path
import struct,collections,json,sys

def analyze(path):
 data=Path(path).read_bytes();i=8;types={}
 while data[i:i+4]==b'etb\0':
  i+=4;t,size,n=struct.unpack_from('>HhI',data,i);i+=8;desc=data[i:i+n].decode();i+=n;n=struct.unpack_from('>I',data,i)[0];i+=4+n+4;types[t]=(size,desc)
 assert data[i:i+12]==b'hetehdredatb';i+=12
 events=[];cap=None
 while i<len(data):
  t=struct.unpack_from('>H',data,i)[0];i+=2
  if t==65535:break
  ts=struct.unpack_from('>Q',data,i)[0];i+=8;size=types[t][0]
  if size==-1:size=struct.unpack_from('>H',data,i)[0];i+=2
  if t==18:cap=struct.unpack_from('>IQH',data,i)[2]
  if t in [0,1,2,3,4,8]:
   tid=struct.unpack_from('>I',data,i)[0];status=struct.unpack_from('>H',data,i+4)[0] if t==2 else None
   events.append((ts,t,cap,tid,status))
  i+=size
 del data
 events.sort(key=lambda e:e[0]);running={};parents={};creates=collections.Counter()
 for ts,t,cap,tid,status in events:
  if t==0:parents[tid]=running.get(cap);creates[parents[tid]]+=1
  elif t==1:running[cap]=tid
  elif t==2:running.pop(cap,None)
 dominant=creates.most_common(1)[0][0];children={tid for tid,parent in parents.items() if parent==dominant};records={};active=None
 for event_index,(ts,t,cap,tid,status) in enumerate(events):
  if t==0 and tid in children:
   active=tid;records[tid]={'created':ts,'first_stop':None,'parent_ready':None,'parent_resume':None,'child_yield':None,'parent_migrations':0,'child_migrations':0,'timeline':[]}
  if active is None:continue
  r=records[active]
  if tid==dominant:
   if t==2 and r['first_stop'] is None:r['first_stop']=(ts,status)
   if t in [3,8] and r['first_stop'] is not None and r['parent_ready'] is None:r['parent_ready']=(ts,t,cap,event_index)
   if t==1 and r['first_stop'] is not None and r['parent_resume'] is None:r['parent_resume']=ts
   if t==4:r['parent_migrations']+=1
  if tid==active:
   if t==2 and status==3 and r['child_yield'] is None:r['child_yield']=(ts,cap,event_index)
   if t==4:r['child_migrations']+=1
  if tid in [dominant,active] and len(r['timeline'])<25:r['timeline'].append((ts-r['created'],types[t][1],'parent' if tid==dominant else 'child',cap,status))
 counts=collections.Counter();groups=collections.defaultdict(list)
 for r in records.values():
  stop=r['first_stop'][1] if r['first_stop'] else None
  if stop!=12:key='parent_first_stop_'+str(stop)
  elif r['child_yield'] is None:key='blocked_no_child_yield'
  elif r['parent_ready'] is None:key='blocked_no_ready_event'
  elif r['child_yield'][0]<r['parent_ready'][0]:key='blocked_child_yields_before_parent_ready'
  elif r['child_yield'][0]>r['parent_ready'][0]:key='blocked_parent_ready_before_child_yields'
  elif r['child_yield'][1]==r['parent_ready'][2]:
   key='blocked_child_yields_before_parent_ready' if r['child_yield'][2]<r['parent_ready'][3] else 'blocked_parent_ready_before_child_yields'
  else:key='blocked_tied_different_capabilities'
  counts[key]+=1;groups[key].append(r)
 result={'path':str(path),'parent':dominant,'iterations':len(records),'counts':dict(counts),'groups':{key:{'count':len(rs),'parent_migrations_per_iteration':sum(r['parent_migrations'] for r in rs)/len(rs),'child_migrations_per_iteration':sum(r['child_migrations'] for r in rs)/len(rs),'example_timeline':rs[len(rs)//2]['timeline']} for key,rs in groups.items()}}
 return result
for path in sys.argv[1:]:
 result=analyze(path);out=Path(__file__).parent/(Path(path).stem+'-order.json');out.write_text(json.dumps(result,indent=2));print(json.dumps({k:v for k,v in result.items() if k!='groups'},indent=2),flush=True)
