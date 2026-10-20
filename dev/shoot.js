const{chromium}=require('playwright') // npm i playwright;
(async()=>{const b=await chromium.launch({executablePath:'/opt/pw-browsers/chromium'});
for(const [f,w] of process.argv.slice(2).map(s=>s.split('@'))){const p=await b.newPage({viewport:{width:+w,height:900}});
const errs=[];p.on('pageerror',e=>errs.push(e.message));p.on('console',m=>{if(m.type()==='error')errs.push(m.text())});p.on('dialog',d=>{errs.push('DIALOG '+d.message());d.dismiss()});
await p.goto('file://'+f);await p.waitForTimeout(500);
const sw=await p.evaluate(()=>document.documentElement.scrollWidth);
await p.screenshot({path:f.replace('.html',`-${w}.png`),fullPage:true});console.log(f,w,'scrollWidth',sw,errs.join(' | ')||'no errors');await p.close();}
await b.close();})();
