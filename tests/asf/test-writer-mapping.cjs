const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),ts=require('typescript');
const src=fs.readFileSync(__dirname+'/../../entry/src/main/ets/services/AsfWriterMapping.ets','utf8');const js=ts.transpileModule(src,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText;const m={exports:{}};vm.runInThisContext('(function(exports,module,require){'+js+'\n})')(m.exports,m,()=>({}));const M=m.exports.AsfWriterMapping;
const mappings={title:'Title',artist:'Author',album:'WM/AlbumTitle',genre:'WM/Genre',comment:'Description',lyrics:'WM/Lyrics',albumArtist:'WM/AlbumArtist',composer:'WM/Composer',grouping:'WM/ContentGroupDescription',isrc:'WM/ISRC',copyright:'Copyright'};
for(const [k,name] of Object.entries(mappings)){let p=M.plan({[k]:'A曲'});assert.equal(p.edits.length,1,k);assert.equal(p.edits[0].name,name);assert.equal(p.edits[0].value,'A曲');p=M.plan({[k]:''});assert.equal(p.edits[0].value,'');assert.throws(()=>M.plan({[k]:'a\0b'}),/invalid string/)}
assert.deepEqual(Array.from(M.plan({genre:'x',comment:'y',lyrics:'z'}).forbiddenAliases),['WM/GenreID','WM/Comments','WM/Lyrics_Synchronised']);assert.equal(M.plan({}).edits.length,0);
for(const [k,name] of Object.entries({year:'WM/Year',bpm:'WM/BeatsPerMinute'})){let p=M.plan({[k]:123});assert.equal(p.edits[0].name,name);assert.equal(p.edits[0].value,'123');for(const n of [0,-1,1.5,NaN,Infinity,10000])assert.throws(()=>M.plan({[k]:n}),/unsupported numeric/)}
for(const k of ['track','trackTotal','disc','discTotal'])for(const n of [0,1,NaN])assert.throws(()=>M.plan({[k]:n}),/not yet representable/);
assert.equal(M.plan({coverImage:{}}).needsCover,true);assert.equal(M.plan({}).needsCover,false);
const all=Object.fromEntries(Object.keys(mappings).map(k=>[k,'']));assert.equal(M.plan(all).edits.length,11);
console.log('PASS writer preflight: all 18 fields covered; 11 strings, year/BPM, explicit number-total refusal and cover flag, absent/empty, aliases');

