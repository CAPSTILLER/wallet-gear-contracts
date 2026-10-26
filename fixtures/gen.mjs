// Regenerate: node fixtures/gen.mjs > fixtures/teeth.json
import {traits} from './traits3.mjs';
import fs from 'fs'; import crypto from 'crypto';
const demo=JSON.parse(fs.readFileSync(new URL('./demo_addrs.json',import.meta.url)));
const r=[];for(let i=0;i<500;i++)r.push('0x'+crypto.createHash('sha256').update('wg-fixture-'+i).digest('hex').slice(0,40));
const all=[...demo,...r];
console.log(JSON.stringify({addrs:all,teeth:all.map(a=>traits(a).teeth)}));
