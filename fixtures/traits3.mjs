// Wallet Gear v3 — traits + 2D profile. Pure ES module (browser + node). No rerolls: one gear per wallet.
export const VERSION='gear-v3';
// ---- keccak256 ----
const RC=[0x1n,0x8082n,0x800000000000808an,0x8000000080008000n,0x808bn,0x80000001n,0x8000000080008081n,0x8000000000008009n,0x8an,0x88n,0x80008009n,0x8000000an,0x8000808bn,0x800000000000008bn,0x8000000000008089n,0x8000000000008003n,0x8000000000008002n,0x8000000000000080n,0x800an,0x800000008000000an,0x8000000080008081n,0x8000000000008080n,0x80000001n,0x8000000080008008n];
const ROT=[0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14];
const M=(1n<<64n)-1n,rl=(x,n)=>n?((x<<BigInt(n))|(x>>BigInt(64-n)))&M:x;
function f(A){for(let r=0;r<24;r++){const C=[0,1,2,3,4].map(x=>A[x]^A[x+5]^A[x+10]^A[x+15]^A[x+20]);
 for(let x=0;x<5;x++){const D=C[(x+4)%5]^rl(C[(x+1)%5],1);for(let y=0;y<25;y+=5)A[y+x]^=D;}
 const B=new Array(25);for(let x=0;x<5;x++)for(let y=0;y<5;y++)B[y+5*((2*x+3*y)%5)]=rl(A[x+5*y],ROT[x+5*y]);
 for(let x=0;x<5;x++)for(let y=0;y<5;y++)A[x+5*y]=B[x+5*y]^((~B[(x+1)%5+5*y])&M&B[(x+2)%5+5*y]);A[0]^=RC[r];}}
export function keccak256(bytes){const rate=136,p=new Uint8Array(Math.ceil((bytes.length+1)/rate)*rate);p.set(bytes);p[bytes.length]^=1;p[p.length-1]^=0x80;
 const A=new Array(25).fill(0n);for(let o=0;o<p.length;o+=rate){for(let i=0;i<17;i++){let v=0n;for(let b=7;b>=0;b--)v=(v<<8n)|BigInt(p[o+i*8+b]);A[i]^=v;}f(A);}
 const out=new Uint8Array(32);for(let i=0;i<4;i++)for(let b=0;b<8;b++)out[i*8+b]=Number((A[i]>>BigInt(8*b))&0xffn);return out;}
const utf8=s=>new TextEncoder().encode(s);
export function normAddress(a){a=String(a).trim().toLowerCase();if(!/^0x[0-9a-f]{40}$/.test(a))throw new Error('need 0x + 40 hex address');return a;}
export function seeds(addr){const raw=Uint8Array.from(normAddress(addr).slice(2).match(/../g),x=>parseInt(x,16));
 const H1=keccak256(raw),b=new Uint8Array(32+VERSION.length);b.set(H1);b.set(utf8(VERSION),32);return {H1,H2:keccak256(b)};}
function pick(u,t){let tot=t.reduce((s,x)=>s+x[1],0),x=u*tot;for(const [v,w] of t){if(x<w)return v;x-=w;}return t[t.length-1][0];}

// ---- locked geometry (Cap, 2026-10-26) ----
export const MODULE=3, PRESSURE_ANGLE=20, ADDENDUM=0.8, DEDENDUM=1.0;   // 20° stub tooth
export const TEETH=[[32,40],[18,35],[11,25]];
export const PROFILE_SHIFT={11:0.2,18:0,32:0};                            // 11T: +0.2 (x_min 0.157) avoids undercut
export const od=z=>MODULE*(z+2*ADDENDUM+2*PROFILE_SHIFT[z]);
export const rootD=z=>MODULE*(z-2*DEDENDUM+2*PROFILE_SHIFT[z]);
const inv=t=>Math.tan(t)-t;
export function centerDistance(z1,z2){const a=PRESSURE_ANGLE*Math.PI/180,x=PROFILE_SHIFT[z1]+PROFILE_SHIFT[z2];
 const iw=2*Math.tan(a)*x/(z1+z2)+inv(a);let lo=.01,hi=1.2;for(let i=0;i<80;i++){const m=(lo+hi)/2;inv(m)<iw?lo=m:hi=m;}
 return MODULE*(z1+z2)/2*Math.cos(a)/Math.cos(lo);}
/** closed outline [[x,y],...] in mm; tooth k centred at angle 2πk/z (k=0 on +X) */
export function toothOutline(z,n=10){
 const m=MODULE,x=PROFILE_SHIFT[z],a=PRESSURE_ANGLE*Math.PI/180,r=m*z/2,rb=r*Math.cos(a),ra=r+(ADDENDUM+x)*m,rf=r-(DEDENDUM-x)*m;
 const s=Math.PI*m/2+2*x*m*Math.tan(a),hp=s/(2*r),pts=[],teeth=[];
 const rs=[],ang=[];for(let i=0;i<n;i++){const rr=Math.max(rb,rf)+(ra-Math.max(rb,rf))*i/(n-1);rs.push(rr);ang.push(hp+inv(a)-inv(Math.acos(Math.min(1,rb/rr))));}
 if(rb>rf){rs.unshift(rf);ang.unshift(ang[0]);}
 for(let k=0;k<z;k++){const c=2*Math.PI*k/z;
  for(let i=0;i<rs.length;i++)pts.push([rs[i]*Math.cos(c-ang[i]),rs[i]*Math.sin(c-ang[i]),k]);
  for(let i=rs.length-1;i>=0;i--)pts.push([rs[i]*Math.cos(c+ang[i]),rs[i]*Math.sin(c+ang[i]),k]);
  for(let j=1;j<5;j++){const t=c+ang[0]+(2*Math.PI/z-2*ang[0])*j/5;pts.push([rf*Math.cos(t),rf*Math.sin(t),-1]);}}
 return {pts,ra,rf,rb,r};}

// ---- trait tables ----
export const TIERS=[['Rust',4000],['Iron',2500],['Brass',1700],['Steel',1000],['Gold',530],['Relic',200],['Prophet',70]];
export const MASTER_ODDS=[7,1000];          // 0.7%, own hash slice, any tier (overlay, keeps the 7 tiers)
export const CANON=[['Crimson','#DC143C',1],['Tangerine','#F28500',2],['Amber','#FFBF00',3],['Canary','#FFFF99',5],['Chartreuse','#CCFF00',6],
 ['Emerald','#50C878',7],['Turquoise','#30D5BC',8],['Base','#0000FF',9],['Sapphire','#0F52BA',10],['Amethyst','#9966CC',11],['Orchid','#9D00D4',12]]; // marigold removed (Cap)
export const MASTER_PINK='#FFC5FF';
export const STACK_CHANCE={Rust:5,Iron:12,Brass:20,Steel:35,Gold:50,Relic:70,Prophet:100}; // % of eligible (18T/32T) gears
export const WEBS=[['Solid',12],['Spokes',24],['Curved Spokes',14],['Holes',18],['Kidney',14],['Lattice',10],['Sun Rays',8]];
export const HUBS=[['Flush',35],['Boss',30],['Flanged',20],['Hex Boss',15]];
export const BORES=[['Round',35],['D-Shaft',25],['Hex',15],['Square',10],['Keyed',15]];
export const ENGR=[['None',30],['Groove',25],['Twin Grooves',15],['Dot Ring',15],['Ticks',15]];
export const FAMILY_BY_TIER={
 Rust:[['Rusted Iron',56],['Iron',18],['Copper',10],['Bronze',8],['Stone',5],['Bone',3]],
 Iron:[['Iron',42],['Gunmetal',28],['Rusted Iron',14],['Steel',10],['Stone',6]],
 Brass:[['Brass',55],['Bronze',25],['Copper',20]],
 Steel:[['Steel',50],['Gunmetal',30],['Brass',10],['Copper',10]],
 Gold:[['Gold',70],['Brass',15],['Copper',15]],
 Relic:[['Bone',35],['Stone',30],['Bronze',30],['Gold',25]],
 Prophet:[['Prophet Voidglass',100]]};
export const FAMILIES={'Rusted Iron':{color:'#8a4a26',metal:[.55,.8],rough:[.7,.95],tint:.35},'Iron':{color:'#6b6f76',metal:[.85,1],rough:[.45,.7],tint:.45},
 'Gunmetal':{color:'#3c4048',metal:[.9,1],rough:[.3,.5],tint:.45},'Steel':{color:'#b4bcc8',metal:[.95,1],rough:[.15,.35],tint:.45},
 'Brass':{color:'#c9a227',metal:[.95,1],rough:[.2,.4],tint:.4},'Bronze':{color:'#9c6a32',metal:[.9,1],rough:[.3,.5],tint:.4},
 'Copper':{color:'#c46a3c',metal:[.95,1],rough:[.2,.4],tint:.35},'Gold':{color:'#ffcc44',metal:[1,1],rough:[.08,.25],tint:.3},
 'Bone':{color:'#e6dcc2',metal:[0,0],rough:[.55,.8],tint:.15},'Stone':{color:'#8a8a86',metal:[0,0],rough:[.75,.95],tint:.2},
 'Prophet Voidglass':{color:'#2a0a55',metal:[.3,.6],rough:[.05,.2],tint:.3}};
export const PATTERNS={base:[['Brushed',22],['Hammered',16],['Pitted Rust',14],['Patina',12],['Heat Tint',12],['Swirl',10],['Damascus',8],['Circuit',6]],
 Bone:[['Porous Ivory',50],['Cracked Ivory',50]],Stone:[['Granite',55],['Slate',45]],
 Prophet:[['Seven Rings',50],['Swirl',20],['Damascus',15],['Circuit',15]]};
export const SHEEN_BY_TIER={Rust:[['None',70],['Clearcoat',20],['Sheen',10]],Iron:[['None',55],['Clearcoat',30],['Sheen',10],['Oil Slick',5]],
 Brass:[['None',40],['Clearcoat',35],['Oil Slick',15],['Sheen',10]],Steel:[['None',30],['Clearcoat',30],['Oil Slick',30],['Sheen',10]],
 Gold:[['Clearcoat',40],['Oil Slick',40],['Emissive Glow',20]],Relic:[['Oil Slick',40],['Emissive Glow',35],['Sheen',25]],Prophet:[['Seventh Halo',100]]};
export const SHEEN_NONMETAL=[['None',50],['Clearcoat',30],['Sheen',20]];     // Bone/Stone outside Relic
export const WEAR=[['Mint',30],['Light',35],['Worn',25],['Ancient',10]];
const SYL=['ka','ru','vex','om','tal','zor','ix','nu','bel','dra','sy','mor','qua','the','lun','gar'];

export function traits(addr){
 const {H1,H2}=seeds(addr),u=(H,i)=>((H[i]<<8)|H[i+1])/65536,t={version:VERSION,address:normAddress(addr)};
 t.tier=pick(u(H1,0),TIERS);const P=t.tier==='Prophet';
 t.teeth=P?32:pick(u(H1,2),TEETH);
 const elig=t.teeth>11, stacked=elig&&(u(H1,14)*100<STACK_CHANCE[t.tier]);
 t.stack=stacked?(t.teeth===32?(P?'32+11':(H1[16]&1?'32+18':'32+11')):'18+11'):'Single';
 t.family=pick(u(H2,0),FAMILY_BY_TIER[t.tier]);
 // Bone/Stone spokes only on single 32T: otherwise re-pick from the same tier table without Bone/Stone, same slice H2[0:2]
 if((t.family==='Bone'||t.family==='Stone')&&!(t.teeth===32&&t.stack==='Single'))t.family=pick(u(H2,0),FAMILY_BY_TIER[t.tier].filter(f=>f[0]!=='Bone'&&f[0]!=='Stone'));
 const BS=t.family==='Bone'||t.family==='Stone';
 t.web=BS?(t.family+' Spokes'):(t.teeth===11?'Solid':pick(u(H1,4),WEBS));
 t.arms=P?7:3+H1[6]%6; if(!P&&t.arms===7)t.arms=H1[7]&1?6:8; if(BS)t.arms=Math.min(t.arms,6)<4?4:Math.min(t.arms,6)===6?6:5; if(P&&BS)t.arms=7;
 t.hub=pick(u(H1,8),HUBS); t.bore=P?'Seven Star':pick(u(H1,10),BORES); t.engraving=P?'Seven Seals':pick(u(H1,12),ENGR);
 t.thickness=[6,8,10][H1[17]%3];
 t.phase=+(u(H1,18)*360).toFixed(2); t.twist=+((u(H1,20)-.5)*0.6).toFixed(4);
 t.master=u(H1,24)*MASTER_ODDS[1]<MASTER_ODDS[0];
 if(t.master){ // Fisher-Yates over 11 canon colors with H2[27..31]+H1[26..31] bytes
  const idx=CANON.map((_,i)=>i),src=[...H2.slice(27,32),...H1.slice(26,32)];for(let i=idx.length-1;i>0;i--){const j=src[10-i]%(i+1);[idx[i],idx[j]]=[idx[j],idx[i]];}
  t.color='Master';t.colorHex=MASTER_PINK;t.colorOrder=idx.map(i=>CANON[i][0]);t.masterHex=idx.map(i=>CANON[i][1]);
  t.toothColors=[...Array(t.teeth)].map((_,k)=>CANON[idx[k%11]][1]);   // 11 distinct; cycle for 18/32 (11∤z ⇒ wrap neighbours still differ)
 } else {const c=CANON[Math.floor(H1[22]/256*11)];t.color=c[0];t.colorHex=c[1];t.canonType=c[2];}
 t.pattern=pick(u(H2,2),P?PATTERNS.Prophet:BS?PATTERNS[t.family]:PATTERNS.base);
 t.sheen=pick(u(H2,4),(BS&&t.tier!=='Relic')?SHEEN_NONMETAL:SHEEN_BY_TIER[t.tier]);
 t.wear=P?'Mint':pick(u(H2,6),WEAR);
 const fam=FAMILIES[t.family],lerp=(r,v)=>+(r[0]+(r[1]-r[0])*v).toFixed(4);
 t.roughness=lerp(fam.rough,u(H2,8));t.metalness=lerp(fam.metal,u(H2,10));
 const iri=t.sheen==='Oil Slick'||t.sheen==='Seventh Halo';t.iridescenceIOR=iri?lerp([1.3,1.8],u(H2,12)):null;t.iridescenceThickness=iri?Math.round(lerp([100,800],u(H2,14))):null;
 t.textureSeed=((H2[16]<<24)|(H2[17]<<16)|(H2[18]<<8)|H2[19])>>>0;t.patternScale=+(0.6+u(H2,20)*0.9).toFixed(3);t.patternAngle=Math.round(u(H2,22)*360);
 t.codename=(SYL[H2[24]%16]+SYL[H2[25]%16]+SYL[H2[26]%16]).replace(/^./,c=>c.toUpperCase());
 t.serial=t.address.slice(-4);
 t.od=+od(t.teeth).toFixed(2);
 t.name=`${t.master?'Master ':''}${t.tier} ${t.family} ${t.teeth}T${t.stack!=='Single'?' ['+t.stack+']':''} “${t.codename}” #${t.serial}`;
 return t;}
