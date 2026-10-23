import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const joints = ['nose','neck','root',...['left','right'].flatMap(s=>['Shoulder','Elbow','Wrist','Hip','Knee','Ankle'].map(j=>s+j))];
const groups = {
  leftArm:['leftShoulder','leftElbow','leftWrist'],rightArm:['rightShoulder','rightElbow','rightWrist'],
  bothArms:['leftShoulder','leftElbow','leftWrist','rightShoulder','rightElbow','rightWrist'],
  leftTrunk:['leftShoulder','leftHip','leftKnee'],rightTrunk:['rightShoulder','rightHip','rightKnee'],
  neckRoot:['neck','root'],leftShoulderKnee:['leftShoulder','leftKnee'],rightShoulderKnee:['rightShoulder','rightKnee']
};
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const median = values => { const sorted=[...values].sort((a,b)=>a-b); return sorted.length ? sorted[Math.floor(sorted.length/2)] : null; };
export function angleDegrees(a,b,c,width,height) {
  if (!a || !b || !c) return null;
  const u=[(a.x-b.x)*width,(a.y-b.y)*height],v=[(c.x-b.x)*width,(c.y-b.y)*height];
  const length=Math.hypot(...u)*Math.hypot(...v);
  return length < 1e-6 ? null : Math.acos(Math.max(-1,Math.min(1,(u[0]*v[0]+u[1]*v[1])/length)))*180/Math.PI;
}

// Audio locates annotation candidates only; no downstream pose or count is filled from sound.
export function detectClickCandidates(samples,sampleRate) {
  if (!(sampleRate>0) || !samples.every(Number.isFinite)) throw Error('Invalid audio');
  const size=Math.max(1,Math.round(sampleRate*0.01)), envelope=[];
  for (let start=0;start<samples.length;start+=size) {
    let power=0; const end=Math.min(samples.length,start+size);
    for(let i=start;i<end;i++) power+=samples[i]*samples[i];
    envelope.push(Math.sqrt(power/(end-start)));
  }
  const baseline=median(envelope) ?? 0, mad=median(envelope.map(v=>Math.abs(v-baseline))) ?? 0;
  const max=envelope.reduce((a,b)=>Math.max(a,b),0), threshold=Math.max(0.005,baseline+12*mad,max*0.12);
  const candidates=[];
  for(let i=0;i<envelope.length;i++) {
    if(envelope[i]<threshold || envelope[i]<(envelope[i-1] ?? 0) || envelope[i]<(envelope[i+1] ?? 0)) continue;
    const candidate={seconds:i*size/sampleRate,strength:envelope[i]};
    const last=candidates.at(-1);
    if(last && candidate.seconds-last.seconds<0.45) { if(candidate.strength>last.strength) candidates[candidates.length-1]=candidate; }
    else candidates.push(candidate);
  }
  return {method:'10ms-rms-impulse-candidates-v1',threshold,baseline,mad,candidates,annotationOnly:true};
}

function checkInput(header,rows,labels) {
  if(header.schema!=='fox.pose_comparison_cache.v1' || header.visionRevision!=='1' || header.sampledHz!=='10'
      || header.timebase!=='asset-seconds' || !/^[a-f0-9]{64}$/.test(header.videoSHA256 ?? '')
      || labels.schema!=='fox.pose_observability_labels.v1' || labels.videoSHA256!==header.videoSHA256
      || labels.markerSource!=='post-production-human-clicks' || !Number.isFinite(labels.durationSeconds)
      || labels.durationSeconds<=0 || !Array.isArray(labels.windows) || !labels.windows.length || !Array.isArray(labels.peaks)
      || rows.length<2 || rows[0].seconds>0.2 || rows.at(-1).seconds<labels.durationSeconds-0.2) throw Error('Invalid source/timeline');
  let previous=-1;
  for(const row of rows) {
    if(!Number.isFinite(row.seconds) || row.seconds<0 || row.seconds<=previous || row.seconds-Math.max(0,previous)>0.4
        || row.seconds>labels.durationSeconds || !Number.isFinite(row.width) || !Number.isFinite(row.height)
        || row.width<=0 || row.height<=0 || !Array.isArray(row.people)) throw Error('Invalid frame/timeline');
    previous=row.seconds;
    for(const person of row.people) {
      if(!Array.isArray(person) || new Set(person.map(p=>p.joint)).size!==person.length) throw Error('Invalid person');
      for(const p of person) if(!joints.includes(p.joint) || ![p.x,p.y,p.confidence].every(v=>Number.isFinite(v)&&v>=0&&v<=1)) throw Error('Invalid point');
    }
  }
  const interval=window=>Array.isArray(window)&&window.length===2&&window.every(Number.isFinite)&&window[0]>=0&&window[0]<=window[1]&&window[1]<=labels.durationSeconds;
  if(new Set(labels.windows.map(w=>w.id)).size!==labels.windows.length || new Set(labels.peaks.map(p=>p.id)).size!==labels.peaks.length) throw Error('Duplicate labels');
  if(labels.subjectRegion) {
    const {minX,maxX,minY,maxY}=labels.subjectRegion;
    if(![minX,maxX,minY,maxY].every(v=>Number.isFinite(v)&&v>=0&&v<=1)||minX>=maxX||minY>=maxY) throw Error('Invalid subject region');
  }
  for(const w of labels.windows) if(!w.id || !['active','negative','full'].includes(w.kind) || !interval([w.start,w.end]) || w.end<=w.start) throw Error('Invalid window');
  for(const p of labels.peaks) if(!p.id || !interval(p.window) || !Number.isFinite(p.clickSeconds) || p.clickSeconds<0
      || p.clickSeconds>labels.durationSeconds || !['visually-reviewed','unreviewed'].includes(p.reviewStatus)
      || (p.startEndpoint!=null&&(!interval(p.startEndpoint)||p.startEndpoint[1]>p.window[0]))
      || (p.returnEndpoint!=null&&(!interval(p.returnEndpoint)||p.returnEndpoint[0]<p.window[1]))) throw Error('Invalid peak label');
}

function coverage(rows,keyList,threshold,end) {
  const valid=rows.map(row=>keyList.every(k=>row.points[k]?.confidence>=threshold));
  const gaps=[]; let start=null;
  for(let i=0;i<rows.length;i++) {
    if(!valid[i] && start===null) start=rows[i].seconds;
    if(start!==null && (valid[i] || i===rows.length-1)) {
      const stop=valid[i] ? rows[i].seconds : Math.min(end,rows[i].seconds+0.1);
      gaps.push({start,end:stop,seconds:stop-start}); start=null;
    }
  }
  return {validFrames:valid.filter(Boolean).length,totalFrames:rows.length,coverage:rows.length ? valid.filter(Boolean).length/rows.length : null,
    maxGapSeconds:gaps.reduce((max,g)=>Math.max(max,g.seconds),0),gapsOver03:gaps.filter(g=>g.seconds>0.3+1e-6),gapsOver1:gaps.filter(g=>g.seconds>1+1e-6)};
}

export function analyzeObservability(header,frames,labels) {
  checkInput(header,frames,labels);
  const selected=frames.map(row=>{
    const eligible=row.people.map((person,index)=>({person,index})).filter(({person})=>{
      if(!labels.subjectRegion) return true;
      const points=person.filter(p=>p.confidence>=0.3);
      if(points.length<3) return false;
      const x=median(points.map(p=>p.x)),y=median(points.map(p=>p.y)),region=labels.subjectRegion;
      return x>=region.minX&&x<=region.maxX&&y>=region.minY&&y<=region.maxY;
    });
    const index=eligible.length===1 ? eligible[0].index : null;
    return {...row,selectedIndex:index,points:index===null ? {} : Object.fromEntries(row.people[index].map(p=>[p.joint,p]))};
  });
  const windows=labels.windows.map(window=>{
    const rows=selected.filter(r=>r.seconds>=window.start&&r.seconds<window.end);
    if(!rows.length) throw Error('Empty observation window');
    return {...window,frames:rows.length,noCandidateFrames:rows.filter(r=>r.people.length===0).length,
      ambiguousFrames:rows.filter(r=>r.people.length>1).length,
      thresholds:Object.fromEntries([0.1,0.3,0.5].map(t=>[String(t),{
        joints:Object.fromEntries(joints.map(j=>[j,coverage(rows,[j],t,window.end)])),
        groups:Object.fromEntries(Object.entries(groups).map(([k,v])=>[k,coverage(rows,v,t,window.end)]))}]))};
  });
  const series=selected.map(row=>{
    const points=Object.fromEntries(Object.entries(row.points).filter(([,p])=>p.confidence>=0.3));
    const result={seconds:row.seconds,people:row.people.length,selectedIndex:row.selectedIndex};
    for(const s of ['left','right']) {
      const shoulder=points[s+'Shoulder'],elbow=points[s+'Elbow'],wrist=points[s+'Wrist'],hip=points[s+'Hip'],knee=points[s+'Knee'];
      result[s+'ElbowDegrees']=angleDegrees(shoulder,elbow,wrist,row.width,row.height);
      result[s+'HipDegrees']=angleDegrees(shoulder,hip,knee,row.width,row.height);
      result[s+'WristRelativeY']=wrist&&shoulder ? wrist.y-shoulder.y : null;
      result[s+'TorsoDegrees']=shoulder&&hip ? Math.atan2((shoulder.y-hip.y)*row.height,(shoulder.x-hip.x)*row.width)*180/Math.PI : null;
      result[s+'ShoulderRelativeKneeY']=shoulder&&knee ? shoulder.y-knee.y : null;
    }
    return result;
  });
  const jumps=[],swapCandidates=[];
  for(let i=1;i<selected.length;i++) {
    const a=selected[i-1],b=selected[i]; if(b.seconds-a.seconds>0.21 || a.selectedIndex===null || b.selectedIndex===null) continue;
    const distance=(p,q)=>Math.hypot((p.x-q.x)*b.width,(p.y-q.y)*b.height)/Math.max(b.width,b.height);
    for(const j of joints) if(a.points[j]?.confidence>=0.3&&b.points[j]?.confidence>=0.3) {
      const delta=distance(a.points[j],b.points[j]); if(delta>0.12) jumps.push({seconds:b.seconds,joint:j,displacementFrameFraction:delta});
    }
    for(const j of ['Shoulder','Elbow','Wrist','Hip']) {
      const [al,ar,bl,br]=[a.points['left'+j],a.points['right'+j],b.points['left'+j],b.points['right'+j]];
      if(![al,ar,bl,br].every(p=>p?.confidence>=0.3)) continue;
      const same=distance(al,bl)+distance(ar,br),swapped=distance(al,br)+distance(ar,bl);
      if(same>0.1&&swapped<same*0.5) swapCandidates.push({seconds:b.seconds,joints:j,same,swapped});
    }
  }
  const peaks=labels.peaks.map(p=>{
    const rows=selected.filter(r=>r.seconds>=p.window[0]&&r.seconds<=p.window[1]);
    const signals=window=>{
      if(!window) return null;
      const samples=series.filter(r=>r.seconds>=window[0]&&r.seconds<=window[1]);
      return Object.fromEntries(['leftElbowDegrees','rightElbowDegrees','leftHipDegrees','rightHipDegrees','leftTorsoDegrees','rightTorsoDegrees','leftWristRelativeY','rightWristRelativeY','leftShoulderRelativeKneeY','rightShoulderRelativeKneeY'].map(key=>{
        const values=samples.map(r=>r[key]).filter(v=>v!=null);
        return [key,{validFrames:values.length,frames:samples.length,median:median(values),min:values.length?Math.min(...values):null,max:values.length?Math.max(...values):null}];
      }));
    };
    return {...p,frames:rows.length,endpointSignals:{start:signals(p.startEndpoint),peak:signals(p.window),returned:signals(p.returnEndpoint)},
      ...Object.fromEntries(Object.entries(groups).map(([key,value])=>[key+'Coverage',coverage(rows,value,0.3,p.window[1]+0.1).coverage]))};
  });
  return {schema:'fox.pose_observability_report.v1',videoSHA256:header.videoSHA256,inferenceProvenance:header,
    subjectPolicy:labels.subjectRegion?'single-candidate-in-manually-reviewed-region-not-production-selector':'single-candidate-only-no-imputation-not-production-selector',
    subjectRegion:labels.subjectRegion??null,frameCount:frames.length,
    evidenceBoundary:'offline-development-observability-not-counting-form-or-live-acceptance',windows,peaks,jumpCandidates:jumps,leftRightSwapCandidates:swapCandidates,series};
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const [command,source,labelsPath,output]=process.argv.slice(2);
    if(command==='audio') {
      const raw=spawnSync('ffmpeg',['-v','error','-i',source,'-map','0:a:0','-ac','1','-ar','16000','-f','f32le','pipe:1'],{maxBuffer:64*1024*1024});
      if(raw.error||raw.status!==0) throw Error(raw.error?.message??raw.stderr.toString());
      const samples=Float32Array.from({length:raw.stdout.length/4},(_,i)=>raw.stdout.readFloatLE(i*4));
      const result={...detectClickCandidates(samples,16000),videoSHA256:sha(await readFile(source))};
      await writeFile(labelsPath,JSON.stringify(result,null,2)+'\n',{flag:'wx',mode:0o600});
      console.log(JSON.stringify(result));
    } else if(command==='analyze'&&output) {
      const bytes=await readFile(source),rows=bytes.toString().trim().split('\n').map(JSON.parse),labels=await readFile(labelsPath);
      const result={...analyzeObservability(rows.shift(),rows,JSON.parse(labels)),cacheSHA256:sha(bytes),labelsSHA256:sha(labels)};
      await writeFile(output,JSON.stringify(result,null,2)+'\n',{flag:'wx',mode:0o600});
      console.log(JSON.stringify({output,frameCount:result.frameCount,windows:result.windows.map(w=>({id:w.id,frames:w.frames,
        groups:Object.fromEntries(Object.entries(w.thresholds['0.3'].groups).map(([k,v])=>[k,{coverage:v.coverage,maxGapSeconds:v.maxGapSeconds}]))}))}));
    } else throw Error('Usage: vision-observability audio <video> <new-candidates.json> | analyze <cache> <labels> <new-report.json>');
  } catch(error) { console.error(error.message);process.exitCode=1; }
}
