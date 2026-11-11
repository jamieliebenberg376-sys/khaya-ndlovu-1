// invite links (/j/CODE): WhatsApp and other apps read the title, text and picture from here, people go straight on to the map
const SUPA={"url": "https://fumilqahcpgkmprlxtzo.supabase.co", "key": "sb_publishable_zVeyOjAzpgCbsE8lIqqrfQ_0lxDnrXg"};
const esc=s=>String(s==null?'':s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
module.exports=async(req,res)=>{
  let code=String((req.query&&req.query.code)||'').toUpperCase().replace(/[^A-Z0-9-]/g,'').slice(0,20);
  const host=(req.headers['x-forwarded-host']||req.headers.host||'khaya-ndlovu-1.vercel.app'),base='https://'+host;
  const go=base+'/?guest='+encodeURIComponent(code);let P=null;
  try{if(code.length>=4){const ac=new AbortController();const t=setTimeout(()=>ac.abort(),2500);
    const r=await fetch(SUPA.url+'/rest/v1/rpc/code_preview',{method:'POST',signal:ac.signal,headers:{apikey:SUPA.key,'Content-Type':'application/json'},body:JSON.stringify({p_code:code})});clearTimeout(t);if(r.ok)P=await r.json()}}catch(e){}
  const k=P&&['guest','owner','admin'].includes(P.kind)?P.kind:'guest',K=k[0].toUpperCase()+k.slice(1);
  const from=P&&P.from?String(P.from).split(' ')[0]:'';
  let title=P?(from?from+' sent you ':'You have ')+K+' access':'Khaya Ndlovu game drive map';
  let end='';try{if(P&&P.ends)end=new Date(P.ends).toLocaleString('en-GB',{timeZone:'Africa/Johannesburg',weekday:'short',day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'})}catch(e){}
  const bits=[];if(P&&P.for)bits.push('For '+P.for);if(code)bits.push('Code '+code);bits.push(P?(end?'Valid until '+end:'Never expires'):'Tap to open the map');
  let desc=bits.join(' · ');if(P&&P.state==='ended')desc='This code has ended. Ask for a new one.';if(P&&P.state==='revoked')desc='This code was cancelled. Ask for a new one.';
  const img=base+'/og/'+k+'.png';
  res.setHeader('Content-Type','text/html; charset=utf-8');res.setHeader('Cache-Control','public, max-age=60');
  res.end(`<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><meta name="description" content="${esc(desc)}">
<meta property="og:type" content="website"><meta property="og:site_name" content="Khaya Ndlovu">
<meta property="og:title" content="${esc(title)}"><meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${esc(base+'/j/'+code)}"><meta property="og:image" content="${esc(img)}"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image"><meta name="theme-color" content="#16301f">
<meta http-equiv="refresh" content="0;url=${esc(go)}"><script>location.replace(${JSON.stringify(go)})</script>
<style>body{background:#0b1a11;color:#fff;font-family:-apple-system,Segoe UI,Roboto,sans-serif;text-align:center;padding:40px 20px}a{color:#e9c46a}</style></head>
<body><h2>${esc(title)}</h2><p>${esc(desc)}</p><p><a href="${esc(go)}">Open the map</a></p></body></html>`)};
