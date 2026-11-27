const V='kn-v207';
const CORE=['./','./index.html'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==V&&k!=='kn-tiles'&&k!=='kn-app-manual'&&k!=='kn-music').map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=='GET')return;
  if(u.hostname.includes('arcgisonline.com')||u.hostname.includes('elevation-tiles-prod')){
    e.respondWith(caches.open('kn-tiles').then(async c=>{const hit=await c.match(e.request);if(hit)return hit;try{const r=await fetch(e.request);if(r.ok)c.put(e.request,r.clone());return r}catch(err){return new Response('',{status:504})}}));
    return;
  }
  // film music: saved once, played from the phone after that
  if(u.origin===location.origin&&u.pathname.includes('/mp3/')){
    e.respondWith(caches.open('kn-music').then(async c=>{const hit=await c.match(e.request,{ignoreSearch:true});if(hit)return hit;const r=await fetch(e.request);if(r.ok&&r.status===200)c.put(e.request,r.clone());return r}));
    return;
  }
  if(u.origin===location.origin){
    // network first for the app page so updates arrive, cache fallback offline
    const isPage=e.request.mode==='navigate'||/\/(index\.html)?$/.test(u.pathname);
    const cached=async()=>{const c=await caches.open(V);let h=isPage?(await c.match('./index.html')||await c.match('./')):await c.match(e.request,{ignoreSearch:true});
      if(h)return h;const m=await caches.open('kn-app-manual');h=isPage?(await m.match('./index.html')||await m.match('./')):await m.match(e.request,{ignoreSearch:true});
      return h||caches.match(e.request,{ignoreSearch:true})};
    // the saved copy opens instantly (signal or not); a fresh copy is saved quietly in the background for next time.
    // an update (?fresh=) always goes to the network for the new page.
    const fresh=u.searchParams.has('fresh');
    // the app page is always saved under one name, so the newest download is the one that opens next time
    const save=r=>{if(r&&r.ok){if(isPage){const a=r.clone(),b2=r.clone(),c2=r.clone();caches.open(V).then(c=>{c.put('./index.html',a);c.put('./',b2)});caches.open('kn-app-manual').then(c=>c.put('./index.html',c2))}else{const cl=r.clone();caches.open(V).then(c=>c.put(e.request,cl))}}return r};
    if(fresh){e.respondWith(fetch(e.request).then(save).catch(()=>cached().then(h=>h||new Response('Offline',{status:503}))));return}
    e.respondWith(cached().then(h=>{const net=fetch(e.request).then(save);if(h){e.waitUntil(net.catch(()=>{}));return h}return net.catch(()=>new Response('Offline',{status:503}))}));
  }
});
self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>l.length?l[0].focus():clients.openWindow('/')))});
