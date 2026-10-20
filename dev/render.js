// Mirrors BriefRenderer.swift: template + escaped JSON payload.
const fs=require('fs');
const [,,tplPath,jsonPath,outPath,buttons]=process.argv;
const brief=JSON.parse(fs.readFileSync(jsonPath,'utf8'));
let json=JSON.stringify({brief,options:{buttons:buttons==='1'}});
json=json.replace(/</g,'\\u003c').replace(/>/g,'\\u003e').replace(/&/g,'\\u0026').replace(/\u2028/g,'\\u2028').replace(/\u2029/g,'\\u2029');
let html=fs.readFileSync(tplPath,'utf8').split('__BRIEF_JSON__').join(json);
fs.writeFileSync(outPath,html);
