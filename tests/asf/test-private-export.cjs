const fs=require('fs'),vm=require('vm'),assert=require('assert/strict'),ts=require('typescript');
function load(file,deps){const js=ts.transpileModule(fs.readFileSync(require('node:path').join(__dirname,'../../entry/src/main/ets/services',file+'.ets'),'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,m={exports:{}};vm.runInThisContext('(function(exports,module,require){'+js+'\n})')(m.exports,m,x=>deps[x]||{});return m.exports}
const map=load('AsfWriterMapping',{}),state={readyFail:false,cleanupFail:false,closeFail:false,sourceCreated:0,closed:0,cleaned:0,edits:[],cover:null};
class Source{constructor(){state.sourceCreated++}close(){state.closed++;if(state.closeFail)throw Error('close fails')}}class Factory{constructor(){if(state.factoryFail)throw Error('PRIVATE_CONTENT') }readyPrivatePath(){if(state.readyFail)throw Error('identity changed');return '/private/owned/candidate.wma'}cleanupReadyPrivateStage(){state.cleaned++;if(state.cleanupFail)throw Error('cleanup fails')}recoveryPrivateDir(){return '/private/owned'}}
class Edit{constructor(name,value){Object.assign(this,{name,value})}}class Cover{constructor(bytes,mime){Object.assign(this,{bytes,mime})}}
const stream={AsfTextEdit:Edit,AsfCoverEdit:Cover,AsfStreamingExport:{async exportCopy(source,factory,probe,verifier,edits,cover,aliases){if(state.streamFail)throw Error('ASF_STAGE_PRIVATE_CONTENT failed');state.edits=edits;state.cover=cover;state.aliases=aliases}}};const deps={'./AsfWriterMapping':map,'./AsfStreamingExport':stream,'./AsfPrivateIO':{AsfPrivateSource:Source,AsfPrivateStageFactory:Factory},'./AsfSystemAudioProbe':{AsfSystemAudioProbe:class{}},'./BoundedCoverVerification':{BoundedCoverVerification:{}},'./AsfPixelMapEncoder':{AsfPixelMapEncoder:{async encode(){return Uint8Array.from([1,2])}}}};
const X=load('AsfPrivateExport',deps).AsfPrivateExport;
(async()=>{let result=await X.exportWorkingFields('/private/input.wma','/private',{title:'x',coverImage:{}});assert.equal(result.path,'/private/owned/candidate.wma');assert.equal(state.edits[0].name,'Title');assert.equal(state.cover.mime,'image/png');result.cleanup();assert.equal(state.cleaned,1);
 let count=state.sourceCreated;await assert.rejects(()=>X.exportWorkingFields('/private/input.wma','/private',{track:1}),/not yet representable/);assert.equal(state.sourceCreated,count);
 state.factoryFail=true;await assert.rejects(()=>X.exportWorkingFields('/private/input.wma','/private',{title:'x'}),e=>String(e).includes('stage_factory')&&!String(e).includes('PRIVATE_CONTENT'));state.factoryFail=false;
 state.streamFail=true;await assert.rejects(()=>X.exportWorkingFields('/private/input.wma','/private',{title:'x'}),e=>String(e).includes('recovery directory: /private/owned')&&!String(e).includes('PRIVATE_CONTENT'));state.streamFail=false;
 state.readyFail=true;await assert.rejects(()=>X.exportWorkingFields('/private/input.wma','/private',{title:'x'}),/stage_ready/);assert.equal(state.cleaned,2);
 state.cleanupFail=true;await assert.rejects(()=>X.exportWorkingFields('/private/input.wma','/private',{title:'x'}),/recovery directory: \/private\/owned/);state.readyFail=false;state.cleanupFail=false;
 state.closeFail=true;let cleanedBefore=state.cleaned;await assert.rejects(()=>X.exportWorkingFields('/private/input.wma','/private',{title:'x'}),e=>String(e).includes('source close failed')&&!String(e).includes('recovery directory'));assert.equal(state.cleaned,cleanedBefore+1);
 state.cleanupFail=true;cleanedBefore=state.cleaned;await assert.rejects(()=>X.exportWorkingFields('/private/input.wma','/private',{title:'x'}),/source close failed; cleanup failed, recovery directory: \/private\/owned/);assert.equal(state.cleaned,cleanedBefore+1);state.cleanupFail=false;state.closeFail=false;
 console.log('PASS mocked private export orchestration: mapping, cover, ready-path and close-failure cleanup, recovery reporting');
})().catch(e=>{console.error(e);process.exitCode=1});



