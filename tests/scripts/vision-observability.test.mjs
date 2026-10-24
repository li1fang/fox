import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzeObservability, detectClickCandidates, angleDegrees } from '../../scripts/vision-observability.mjs';

const sha = 'a'.repeat(64);
const header = {schema:'fox.pose_comparison_cache.v1',videoSHA256:sha,visionRevision:'1',sampledHz:'10',timebase:'asset-seconds'};
const labels = {schema:'fox.pose_observability_labels.v1',videoSHA256:sha,durationSeconds:1,
  markerSource:'post-production-human-clicks', windows:[{id:'active',kind:'active',start:0,end:1}],peaks:[]};
const point = (joint,x,y,confidence=0.9) => ({joint,x,y,confidence});
const person = [point('leftShoulder',0.5,0.8),point('leftElbow',0.5,0.5),point('leftWrist',0.7,0.5)];
const rows = () => Array.from({length:10},(_,i)=>({seconds:i/10,width:1280,height:720,people:[structuredClone(person)]}));
test('single candidate coverage and aspect-correct angles are measured without exercise counting', () => {
  const result = analyzeObservability(header,rows(),labels);
  assert.equal(result.windows[0].thresholds['0.3'].groups.leftArm.coverage,1);
  assert.equal(result.windows[0].thresholds['0.3'].groups.rightArm.coverage,0);
  assert.equal(result.series[0].leftElbowDegrees,90);
  assert.equal(result.repetitionCount,undefined);
  assert.equal(angleDegrees({x:0,y:0.5},{x:0.5,y:0.5},{x:1,y:1},2,1).toFixed(2),'153.43');
});
test('missing joints create bounded gaps and are never interpolated into angles', () => {
  const frames=rows(); for(let i=2;i<6;i++) frames[i].people[0][2].confidence=0.01;
  const result=analyzeObservability(header,frames,labels);
  const arm=result.windows[0].thresholds['0.3'].groups.leftArm;
  assert.equal(arm.validFrames,6);
  assert.ok(Math.abs(arm.maxGapSeconds-0.4)<1e-6);
  assert.equal(arm.gapsOver03.length,1);
  assert.equal(result.series[2].leftElbowDegrees,null);
});
test('zero and multiple candidates cannot silently become a tracked subject', () => {
  const frames=rows(); frames[0].people=[]; frames[1].people.push(structuredClone(person));
  const result=analyzeObservability(header,frames,labels);
  assert.equal(result.series[0].selectedIndex,null);
  assert.equal(result.series[1].selectedIndex,null);
  assert.equal(result.windows[0].ambiguousFrames,1);
  assert.equal(result.windows[0].noCandidateFrames,1);
});
test('reviewed spatial region is explicit, rejects ambiguity, and never fills an absent target', () => {
  const frames=rows();
  const background=person.map(p=>({...p,x:0.1}));
  frames[0].people=[background,structuredClone(person)]; frames[1].people=[background];
  frames[2].people=[structuredClone(person),structuredClone(person)];
  const result=analyzeObservability(header,frames,{...labels,subjectRegion:{minX:0.35,maxX:0.75,minY:0.3,maxY:0.9}});
  assert.equal(result.series[0].selectedIndex,1);
  assert.equal(result.series[1].selectedIndex,null);
  assert.equal(result.series[2].selectedIndex,null);
  assert.match(result.subjectPolicy,/reviewed-region/);
});
test('terminal peak does not fabricate a return endpoint or complete cycle', () => {
  const result=analyzeObservability(header,rows(),{...labels,peaks:[{id:'p',clickSeconds:0.8,window:[0.6,0.8],
    startEndpoint:[0,0.2],returnEndpoint:null,reviewStatus:'visually-reviewed'}]});
  assert.equal(result.peaks[0].endpointSignals.returned,null);
  assert.equal(result.peaks[0].endpointSignals.peak.leftElbowDegrees.median,90);
});
test('invalid provenance, duplicated time, missing timeline and invalid labels are rejected', () => {
  assert.throws(()=>analyzeObservability({...header,videoSHA256:'b'.repeat(64)},rows(),labels));
  const bad=rows(); bad[2].seconds=bad[1].seconds; assert.throws(()=>analyzeObservability(header,bad,labels));
  assert.throws(()=>analyzeObservability(header,rows().slice(0,3),labels));
  assert.throws(()=>analyzeObservability(header,rows(),{...labels,peaks:[{id:'p',clickSeconds:0.5,window:[0.8,0.4],reviewStatus:'visually-reviewed'}]}));
});
test('reviewed peak checks use visual intervals and keep click offset distinct', () => {
  const result=analyzeObservability(header,rows(),{...labels,peaks:[{id:'p',clickSeconds:0.8,window:[0.4,0.6],reviewStatus:'visually-reviewed'}]});
  assert.equal(result.peaks[0].clickSeconds,0.8);
  assert.deepEqual(result.peaks[0].window,[0.4,0.6]);
  assert.equal(result.peaks[0].leftArmCoverage,1);
});
test('confidence sensitivity retains low-confidence distinction', () => {
  const frames=rows(); frames.forEach(f=>f.people[0][2].confidence=0.2);
  const result=analyzeObservability(header,frames,labels);
  assert.equal(result.windows[0].thresholds['0.1'].groups.leftArm.coverage,1);
  assert.equal(result.windows[0].thresholds['0.3'].groups.leftArm.coverage,0);
});
test('silent audio is not a marker and ringing around an impulse is merged', () => {
  const samples=new Float32Array(32000);
  assert.deepEqual(detectClickCandidates(samples,16000).candidates,[]);
  for(const t of [0.5,0.52,1.5]) for(let i=Math.round(t*16000);i<Math.round(t*16000)+40;i++) samples[i]=0.8;
  const clicks=detectClickCandidates(samples,16000).candidates;
  assert.equal(clicks.length,2);
  assert.ok(Math.abs(clicks[0].seconds-0.5)<0.05);
});
