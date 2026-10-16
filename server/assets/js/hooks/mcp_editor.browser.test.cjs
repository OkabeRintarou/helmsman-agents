const {chromium}=require(process.env.MCP_PLAYWRIGHT_MODULE || 'playwright-core');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const source=fs.readFileSync(require('node:path').join(__dirname,'mcp_editor.mjs'),'utf8');
(async()=>{
const browser=await chromium.launch({executablePath:process.env.MCP_CHROMIUM});
try {
const page=await browser.newPage();
await page.setContent('<form id="f"><div id="editor"><input data-mcp-output><div data-mcp-body></div></div></form>');
const result=await page.evaluate(async source=>{
 const hook=(await import(URL.createObjectURL(new Blob([source],{type:'application/javascript'})))).default;
 const el=document.querySelector('#editor');
 el.dataset.config=JSON.stringify({docs:{type:'http',url:'https://a.test',headers:{'X-Key':{$keep:'docs'}},auth:{$keep:'docs'},tools:['*']},pw:{command:'npx',args:['a b']}});
 el.dataset.labels=JSON.stringify(Object.fromEntries(['add','delete','name','type','template','json','import','form','preview','command','args','cwd','env','headers','key','value','local','fixed','set','other','url','overwrite','sse','invalidJson','duplicateName'].map(k=>[k,k])));
 el.dataset.templates=JSON.stringify([{name:'github',description:'GitHub',config:{type:'http',url:'https://github.test',headers:{Authorization:'Bearer ${env:GITHUB_PAT}'}},env_refs:['GITHUB_PAT']}]);
 const validations=[]; const h={...hook,el,pushEvent(name,payload,cb){validations.push(payload);if(name==='mcp_import')cb({entries:[{name:'docs',type:'stdio',config:{command:'uvx',args:['imported'],env:{TOKEN:'${env:TOKEN}'}},warnings:['default ignored']}]});else cb({errors:payload.mcp.docs?.url==='bad'?[['docs.url','invalid']]:[]})}};h.mounted();
 const check=(condition,message)=>{if(!condition)throw Error(message)};
 const input=(label,value)=>{const l=[...el.querySelectorAll('label')].find(l=>l.querySelector('span').textContent===label);const i=l.querySelector('input,textarea');i.value=value;i.dispatchEvent(new Event('input'));return i};
 input('url','bad');h.validate();check(el.querySelector('[data-mcp-field="docs.url"] [data-mcp-error]'),'field error missing');
 input('set','NEW_CANARY');h.renderJson();check(h.jsonText.value.includes('NEW_CANARY'),'new secret lost in JSON');check(h.jsonText.value.includes('••••••'),'stored marker exposed');
 h.jsonText.value=h.jsonText.value.replace('"docs":','"renamed":');h.config=(await import(URL.createObjectURL(new Blob([source],{type:'application/javascript'})))).fromJson(h.jsonText.value,h.originals);h.renderCards();
 check(h.config.renamed.auth.$keep==='docs','rename lost original marker');check(h.config.renamed.headers['X-Key']==='NEW_CANARY','new secret lost after rename');
 input('name','pw');check(h.invalidFields.size===1,'duplicate name allowed');check(h.config.renamed,'duplicate erased source card');
 input('name','renamed');check(h.invalidFields.size===0,'duplicate error not cleared');
 
 input('name','longer-name');input('name','x');
 check(el.querySelector('[data-mcp-field="x.url"]'),'consecutive rename lost field path');
 const click=(root,label)=>[...root.querySelectorAll('button')].find(b=>b.textContent===label).click();
 let card=el.querySelector('[data-mcp-card="x"]');
 const auth=card.querySelector('[data-mcp-field="x.auth"] input');auth.value='{';auth.dispatchEvent(new Event('input'));
 check(h.invalidFields.has('x.auth'),'invalid opaque replacement not blocked');
 const deleteCard=[...card.children].find(child=>child.tagName==='BUTTON');deleteCard.click();
 check(h.invalidFields.size===0,'deleting invalid card left submit blocked');
 click(el,'add');card=el.querySelector('[data-mcp-card="server"]');
 const set=(root,path,value)=>{const i=root.querySelector(`[data-mcp-field="${path}"] input,[data-mcp-field="${path}"] textarea`);i.value=value;i.dispatchEvent(new Event('input'));return i};
 set(card,'server.command','npx');set(card,'server.args','a b\n--headless');
 check(JSON.stringify(h.config.server.args)===JSON.stringify(['a b','--headless']),'args shell split');
 const type=card.querySelector('select[aria-label="type"]');type.value='sse';type.dispatchEvent(new Event('change'));
 check(h.config.server.type==='sse','type did not change');
 el.dataset.provider='codex';h.renderCards();check(el.textContent.includes('sse'),'Codex SSE notice missing');
 const templates=el.querySelector('select');templates.value='github';templates.dispatchEvent(new Event('change'));
 check(h.config.github.headers.Authorization==='Bearer ${env:GITHUB_PAT}','template changed reference');
 check(el.textContent.includes('GITHUB_PAT'),'template missing local env notice');
 h.renderImport();el.querySelector('textarea').value='claude mcp add docs -- uvx imported';click(el,'preview');
 check(el.textContent.includes('default ignored'),'import warnings absent');
 click(el.querySelector('input[placeholder="name"]').nextElementSibling.nextElementSibling,'add');
 check(h.config.docs.command==='uvx','import not added to draft');
 const imported=el.querySelector('[data-mcp-card="docs"]');
 const pair=imported.querySelector('[data-mcp-field="docs.env.TOKEN"]').parentElement;
 pair.querySelector('select').value='local';const inputs=pair.querySelectorAll('input');inputs[inputs.length-1].value='LOCAL_TOKEN';inputs[inputs.length-1].dispatchEvent(new Event('input'));
 check(h.config.docs.env.TOKEN==='${env:LOCAL_TOKEN}','local variable name not converted');
 h.renderJson();h.jsonText.value='{';click(el,'form');
 check(h.jsonText && h.jsonError.textContent,'invalid JSON left advanced mode');
 check(validations.some(v=>v.mcp_import===undefined),'validation not requested');
 h.single=true;h.config={docs:{command:'npx'}};h.renderCards();click(el,'add');
 check(Object.keys(h.config).length===1,'personal editor added a second entry');
 const singleTemplate=el.querySelector('select');singleTemplate.value='github';singleTemplate.dispatchEvent(new Event('change'));
 check(Object.keys(h.config).join(',')==='github','personal template did not replace entry');
 h.renderImport();click(el,'preview');click(el.querySelector('input[placeholder="name"]').nextElementSibling.nextElementSibling,'add');
 check(Object.keys(h.config).join(',')==='docs','personal import did not replace entry');
 h.destroyed();return ['field errors','browser secret retention','JSON rename','duplicate-name preservation','deleting invalid cards','types/args','templates','import preview','local references','invalid JSON'];

},source);
console.log(result.join(', ')+' passed');
} finally {await browser.close()}
})().catch(e=>{console.error(e);process.exit(1)});
