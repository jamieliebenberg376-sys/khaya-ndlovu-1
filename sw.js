const V='kn-v119';
const CORE=['./','./index.html'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==V&&k!=='kn-tiles'&&k!=='kn-app-manual').map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=='GET')return;
  if(u.hostname.includes('arcgisonline.com')||u.hostname.includes('elevation-tiles-prod')){
    e.respondWith(caches.open('kn-tiles').then(async c=>{const hit=await c.match(e.request);if(hit)return hit;try{const r=await fetch(e.request);if(r.ok)c.put(e.request,r.clone());return r}catch(err){return new Response('',{status:504})}}));
    return;
  }
  if(u.origin===location.origin){
    // network first for the app page so updates arrive, cache fallback offline
    const isPage=e.request.mode==='navigate'||/\/(index\.html)?$/.test(u.pathname);
    const cached=async()=>{const c=await caches.open(V);let h=await c.match(e.request,{ignoreSearch:true})||(isPage&&(await c.match('./index.html')||await c.match('./')));
      if(h)return h;const m=await caches.open('kn-app-manual');h=await m.match(e.request,{ignoreSearch:true})||(isPage&&(await m.match('./index.html')||await m.match('./')));
      return h||caches.match(e.request,{ignoreSearch:true})};
    // an update (?fresh=) always waits for the new page; normal opens fall back to the saved copy after 6 s of weak signal
    const fresh=u.searchParams.has('fresh');
    e.respondWith(new Promise(res=>{let done=false;const t=fresh?0:setTimeout(()=>{cached().then(h=>{if(h&&!done){done=true;res(h)}})},6000);
      fetch(e.request).then(r=>{if(r.ok){const cl=r.clone();caches.open(V).then(c=>c.put(e.request,cl));if(isPage){const c2=r.clone();caches.open('kn-app-manual').then(c=>c.put('./index.html',c2))}}if(!done){done=true;clearTimeout(t);res(r)}})
      .catch(()=>cached().then(h=>{if(!done){done=true;clearTimeout(t);res(h||new Response('Offline',{status:503}))}}))}));
  }
});
self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>l.length?l[0].focus():clients.openWindow('/')))});
