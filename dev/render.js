// Mirrors BriefRenderer.swift: template + font + escaped JSON payload.
const fs=require('fs');
const [,,tplPath,fontPath,jsonPath,outPath,buttons]=process.argv;
const brief=JSON.parse(fs.readFileSync(jsonPath,'utf8'));
let json=JSON.stringify({brief,options:{buttons:buttons==='1'}});
json=json.replace(/</g,'\\u003c').replace(/>/g,'\\u003e').replace(/&/g,'\\u0026').replace(/\u2028/g,'\\u2028').replace(/\u2029/g,'\\u2029');
const font=fs.readFileSync(fontPath).toString('base64');
let html=fs.readFileSync(tplPath,'utf8').split('__FONT_B64__').join(font).split('__BRIEF_JSON__').join(json);
fs.writeFileSync(outPath,html);
