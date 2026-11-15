const fs=require('node:fs');const path=require('node:path');const cp=require('node:child_process');
const root=path.resolve(__dirname,'..');
let ts;
const candidates=[process.env.TYPESCRIPT_PATH,'typescript',process.env.DEVECO_HOME && path.join(process.env.DEVECO_HOME,'tools/hvigor/hvigor/node_modules/typescript'),'D:/D Program Files/DevEco Studio/tools/hvigor/hvigor/node_modules/typescript'];
for(const candidate of candidates.filter(Boolean)){try{ts=require(candidate);break;}catch{}}
if(!ts)throw Error('Install TypeScript or set TYPESCRIPT_PATH to its package directory');
const dir=path.join(root,'entry/src/main/ets/core');const out=path.join(root,'.test-build');fs.mkdirSync(out,{recursive:true});
const files=fs.readdirSync(dir).filter(x=>x.endsWith('.ts')).map(x=>path.join(dir,x));
const options={strict:true,target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS,outDir:out,skipLibCheck:true,types:[]};
const program=ts.createProgram(files,options);const diagnostics=ts.getPreEmitDiagnostics(program);
if(diagnostics.length){console.error(ts.formatDiagnosticsWithColorAndContext(diagnostics,{getCanonicalFileName:x=>x,getCurrentDirectory:()=>root,getNewLine:()=> '\n'}));process.exit(1);}
program.emit();
const nativeSource=fs.readFileSync(path.join(root,'entry/src/main/ets/platform/DeepSeek.ets'),'utf8');
fs.writeFileSync(path.join(out,'DeepSeek.js'),ts.transpileModule(nativeSource,{compilerOptions:options}).outputText);
const result=cp.spawnSync(process.execPath,['--test',path.join(root,'tests/core.cjs'),path.join(root,'tests/transport.cjs'),path.join(root,'tests/rpc.cjs')],{stdio:'inherit'});process.exit(result.status??1);
