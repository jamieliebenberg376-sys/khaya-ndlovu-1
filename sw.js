const V='kn-v217';
const CORE=['./','./index.html'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(V).then(c=>c.addAll(CORE)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==V&&k!=='kn-tiles'&&k!=='kn-app-manual'&&k!=='kn-music').map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  const u=new URL(e.request.url);
  if(e.request.method!=='GET')return;
  if(u.hostname.includes('arcgisonline.com')||u.hostname.includes('elevation-tiles-prod')){
    // saved tile first; then the network (given up after 8 s on weak signal); then a zoomed-in piece of a saved bigger tile, so it's never blank
    e.respondWith(caches.open('kn-tiles').then(async c=>{const hit=await c.match(e.request);if(hit)return hit;
      try{const r=await Promise.race([fetch(e.request),new Promise((_,no)=>setTimeout(()=>no(0),8000))]);if(r&&r.ok){c.put(e.request,r.clone());return r}}catch(err){}
      if(u.hostname.includes('arcgisonline.com')){const fb=await parentTile(c,u.href);if(fb)return fb}
      return new Response('',{status:504})}));
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
async function parentTile(c,href){try{const m=href.match(/\/tile\/(\d+)\/(\d+)\/(\d+)/);if(!m||typeof OffscreenCanvas==='undefined'||typeof createImageBitmap==='undefined')return null;const z=+m[1],y=+m[2],x=+m[3];
  for(let k=1;k<=6&&z-k>=0;k++){const pz=z-k,px=x>>k,py=y>>k;const h=await c.match(href.replace(/\/tile\/\d+\/\d+\/\d+/,'/tile/'+pz+'/'+py+'/'+px));if(!h)continue;
    const bmp=await createImageBitmap(await h.blob());const n=1<<k,sz=bmp.width/n,sx=(x-(px<<k))*sz,sy=(y-(py<<k))*sz;const cv=new OffscreenCanvas(256,256),g=cv.getContext('2d');g.imageSmoothingQuality='high';g.drawImage(bmp,sx,sy,sz,sz,0,0,256,256);
    const b=await cv.convertToBlob({type:'image/jpeg',quality:.85});return new Response(b,{headers:{'Content-Type':'image/jpeg'}})}}catch(e){}return null}
self.addEventListener('notificationclick',e=>{e.notification.close();e.waitUntil(clients.matchAll({type:'window',includeUncontrolled:true}).then(l=>l.length?l[0].focus():clients.openWindow('/')))});
