const knCurve=(()=>{const C={};return k=>{if(C[k])return C[k];const n=1024,c=new Float32Array(n);for(let i=0;i<n;i++){const x=i/(n-1)*2-1;c[i]=Math.tanh(x*k)/Math.tanh(k)}return C[k]=c}})();
/* Khaya Ndlovu film soundtracks: 10 tracks, all timed to the same film beats.
   T = {T1 fly in, T2 leaves the road, T3 track found, T4 named, T5 add to map, TE end} */
function knMusic(ac,dest,T,style){
  const S=KN_TRACKS[style%KN_TRACKS.length];
  const out=ac.createGain();out.gain.value=0;const comp=ac.createDynamicsCompressor();comp.threshold.value=-16;comp.ratio.value=3.5;const lim=ac.createDynamicsCompressor();lim.threshold.value=-4;lim.knee.value=0;lim.ratio.value=20;lim.attack.value=.002;lim.release.value=.15;const trim=ac.createGain();trim.gain.value=.8;out.connect(comp);comp.connect(lim);lim.connect(trim);trim.connect(dest);
  const verb=ac.createConvolver(),vg=ac.createGain();vg.gain.value=S.room||.32;{const L=ac.sampleRate*(S.roomLen||2.4),b=ac.createBuffer(2,L,ac.sampleRate);for(let c=0;c<2;c++){const d=b.getChannelData(c);for(let i=0;i<L;i++)d[i]=(Math.random()*2-1)*Math.pow(1-i/L,2.6)}verb.buffer=b}verb.connect(vg);vg.connect(out);
  const beat=60/S.bpm;const dly=ac.createDelay(2),dfb=ac.createGain(),dwet=ac.createGain();dly.delayTime.value=beat*(S.echo||.75);dfb.gain.value=.36;dwet.gain.value=.3;dly.connect(dfb);dfb.connect(dly);dly.connect(dwet);dwet.connect(out);
  const nodes=[];const keep=n=>{nodes.push(n);return n};let base=0,off=0;
  const noiseBuf=(()=>{const b=ac.createBuffer(1,ac.sampleRate,ac.sampleRate),d=b.getChannelData(0);for(let i=0;i<d.length;i++)d[i]=Math.random()*2-1;return b})();
  const hz=m=>440*Math.pow(2,(m-69)/12);
  const at=t=>base+t-off,ok=t=>t>=off-0.05;
  const route=(g,o)=>{const pan=ac.createStereoPanner?ac.createStereoPanner():null;let n=g;if(pan){pan.pan.value=o.pan||0;g.connect(pan);n=pan}n.connect(out);if(o.verb){const s=ac.createGain();s.gain.value=o.verb;n.connect(s);s.connect(verb)}if(o.echo){const s=ac.createGain();s.gain.value=o.echo;n.connect(s);s.connect(dly)}};
  const tone=(t,f,dur,o)=>{o=o||{};const type=o.type||'sine',vol=o.vol==null?.2:o.vol,att=o.att==null?.01:o.att,rel=o.rel==null?.3:o.rel;if(!ok(t))return;
    const osc=keep(ac.createOscillator()),g=ac.createGain();osc.type=type;const s0=at(t);osc.frequency.setValueAtTime(o.from?f*o.from:f,s0);if(o.from)osc.frequency.exponentialRampToValueAtTime(f,s0+(o.fall||.06));if(o.glide)osc.frequency.exponentialRampToValueAtTime(f*o.glide,s0+dur);osc.detune.value=o.det||0;let n=osc;if(o.drive){const ws=ac.createWaveShaper();ws.curve=knCurve(o.drive);osc.connect(ws);n=ws}
    if(o.vib){const l=keep(ac.createOscillator()),lg=ac.createGain();l.frequency.value=o.vib;lg.gain.value=o.vibd||8;l.connect(lg);lg.connect(osc.detune);l.start(s0);l.stop(s0+dur+.05)}
    if(o.cut){const fl=ac.createBiquadFilter();fl.type=o.bp?'bandpass':'lowpass';fl.frequency.value=o.cut;fl.Q.value=o.q||.7;n.connect(fl);n=fl;if(o.cut2){fl.frequency.setValueAtTime(o.cut,s0);fl.frequency.exponentialRampToValueAtTime(o.cut2,s0+dur)}}n.connect(g);route(g,o);
    g.gain.setValueAtTime(0,s0);g.gain.linearRampToValueAtTime(vol,s0+att);if(o.pluck)g.gain.exponentialRampToValueAtTime(.0008,s0+dur);else{g.gain.setValueAtTime(vol,s0+Math.max(att,dur-rel));g.gain.linearRampToValueAtTime(0,s0+dur)}osc.start(s0);osc.stop(s0+dur+.05)};
  const noise=(t,dur,o)=>{o=o||{};if(!ok(t))return;const sr=keep(ac.createBufferSource()),g=ac.createGain(),f=ac.createBiquadFilter();sr.buffer=noiseBuf;sr.loop=true;f.type=o.lp?'lowpass':o.bp?'bandpass':'highpass';f.frequency.value=o.lp||o.bp||o.hp||6000;if(o.q)f.Q.value=o.q;
    const s0=at(t),vol=o.vol==null?.2:o.vol,att=o.att==null?.002:o.att;if(o.sweep)f.frequency.exponentialRampToValueAtTime(o.sweep,s0+dur);
    sr.connect(f);f.connect(g);route(g,o);g.gain.setValueAtTime(0.0001,s0);g.gain.linearRampToValueAtTime(vol,s0+att);g.gain.exponentialRampToValueAtTime(.0008,s0+dur);sr.start(s0+Math.random()*.0);sr.stop(s0+dur+.05)};
  const kick=(t,v,o)=>{o=o||{};if(!ok(t))return;const k=keep(ac.createOscillator()),g=ac.createGain(),s0=at(t),dec=o.dec||.38;k.frequency.setValueAtTime(o.f0||150,s0);k.frequency.exponentialRampToValueAtTime(o.f1||40,s0+(o.drop||.2));g.gain.setValueAtTime(v||.7,s0);g.gain.exponentialRampToValueAtTime(.001,s0+dec);k.connect(g);route(g,{verb:o.verb||0});k.start(s0);k.stop(s0+dec+.05)};
  const snare=(t,v,o)=>{o=o||{};noise(t,o.dec||.18,{vol:v||.12,bp:o.bp||1900,q:.6,verb:o.verb==null?.35:o.verb,pan:o.pan||0});tone(t,o.f||190,.1,{vol:(v||.12)*.9,pluck:true,from:1.5,fall:.05})};
  const clap=(t,v,o)=>{o=o||{};for(let i=0;i<3;i++)noise(t+i*.011,i<2?.03:.2,{vol:v||.11,bp:1300,q:.8,verb:o.verb==null?.5:o.verb,pan:o.pan||0})};
  const hat=(t,v,open,pan)=>noise(t,open?.22:.045,{vol:v||.05,hp:open?7000:8500,pan:pan||0});
  const shaker=(t,v,pan)=>noise(t,.07,{vol:v||.04,hp:5500,att:.02,pan:pan||0});
  const tom=(t,m,v,o)=>{o=o||{};tone(t,hz(m),o.dec||.35,{vol:v||.25,pluck:true,from:1.6,fall:.04,verb:o.verb||.25,pan:o.pan||0})};
  const riser=(t,dur,v,o)=>{o=o||{};noise(t,dur,{vol:v||.12,hp:o.hp||300,sweep:o.to||9000,att:dur*.9,verb:o.verb==null?.4:o.verb})};
  const impact=(t,v,o)=>{o=o||{};kick(t,v||1,{f0:o.f0||120,f1:o.f1||32,dec:o.dec||.9,drop:.35,verb:.3});noise(t,o.tail||2.2,{vol:(v||1)*.12,lp:o.lp||5000,sweep:120,att:.005,verb:.9})};
  const hall=ac.createConvolver(),hg=ac.createGain();hg.gain.value=.55;{const L=ac.sampleRate*4.5,b=ac.createBuffer(2,L,ac.sampleRate);for(let c=0;c<2;c++){const d=b.getChannelData(c);for(let i=0;i<L;i++)d[i]=(Math.random()*2-1)*Math.pow(1-i/L,3.2)}hall.buffer=b}hall.connect(hg);hg.connect(out);
  const toHall=(n,v)=>{const g=ac.createGain();g.gain.value=v;n.connect(g);g.connect(hall)};
  /* sub drop: a deep boom you feel more than hear */
  const sub=(t,v,len)=>{if(!ok(t))return;const o=keep(ac.createOscillator()),g=ac.createGain(),s0=at(t);len=len||2.6;o.frequency.setValueAtTime(62,s0);o.frequency.exponentialRampToValueAtTime(26,s0+len);g.gain.setValueAtTime(v||.6,s0);g.gain.exponentialRampToValueAtTime(.001,s0+len);o.connect(g);g.connect(out);o.start(s0);o.stop(s0+len+.05)};
  /* reverse swell: sucks in to the hit */
  const swell=(t,dur,v)=>{if(!ok(t-dur))return;const sr=keep(ac.createBufferSource()),g=ac.createGain(),f=ac.createBiquadFilter(),s0=at(t-dur);sr.buffer=noiseBuf;sr.loop=true;f.type='highpass';f.frequency.setValueAtTime(400,s0);f.frequency.exponentialRampToValueAtTime(5000,s0+dur);sr.connect(f);f.connect(g);g.connect(out);toHall(g,.4);g.gain.setValueAtTime(.0001,s0);g.gain.exponentialRampToValueAtTime(v||.16,s0+dur-.02);g.gain.linearRampToValueAtTime(0,s0+dur);sr.start(s0);sr.stop(s0+dur+.05)};
  /* braam: a wall of low brass */
  const braam=(t,m,v,len)=>{if(!ok(t))return;len=len||3.4;[0,7,12,19].forEach((iv,k)=>[-14,0,14].forEach(d=>{const o=keep(ac.createOscillator()),f=ac.createBiquadFilter(),g=ac.createGain(),s0=at(t);o.type='sawtooth';o.frequency.value=hz(m+iv);o.detune.value=d;f.type='lowpass';f.Q.value=2;f.frequency.setValueAtTime(180,s0);f.frequency.exponentialRampToValueAtTime(2600,s0+.18);f.frequency.exponentialRampToValueAtTime(220,s0+len);g.gain.setValueAtTime(0,s0);g.gain.linearRampToValueAtTime((v||.05)*(k?0.8:1),s0+.05);g.gain.exponentialRampToValueAtTime(.0008,s0+len);o.connect(f);f.connect(g);g.connect(out);toHall(g,.35);o.start(s0);o.stop(s0+len+.05)}))};
  /* choir: 'aah' voices from a sawtooth through two vowel filters */
  const choir=(t,m,dur,v)=>{if(!ok(t))return;[-10,0,10].forEach(d=>{const o=keep(ac.createOscillator()),g=ac.createGain(),s0=at(t);o.type='sawtooth';o.frequency.value=hz(m);o.detune.value=d;const l=keep(ac.createOscillator()),lg=ac.createGain();l.frequency.value=5+Math.random();lg.gain.value=9;l.connect(lg);lg.connect(o.detune);
    [[800,.9],[1150,.5],[2900,.15]].forEach(([fq,a])=>{const f=ac.createBiquadFilter(),fg=ac.createGain();f.type='bandpass';f.frequency.value=fq;f.Q.value=7;fg.gain.value=a;o.connect(f);f.connect(fg);fg.connect(g)});
    g.gain.setValueAtTime(0,s0);g.gain.linearRampToValueAtTime(v||.09,s0+Math.min(1.5,dur*.4));g.gain.setValueAtTime(v||.09,s0+dur*.75);g.gain.linearRampToValueAtTime(0,s0+dur);g.connect(out);toHall(g,.7);o.start(s0);o.stop(s0+dur+.05);l.start(s0);l.stop(s0+dur+.05)})};
  /* a metal stinger on top of a hit */
  const sting=(t,v)=>{noise(t,1.4,{vol:(v||1)*.14,bp:3200,q:2,verb:.9});[1,2.76,5.4].forEach((r,i)=>tone(t,520*r,1.6-i*.3,{type:'sine',vol:(v||1)*.05/(i+1),pluck:true,verb:.9}))};
  const P={ac,T,hz,sub,swell,braam,choir,sting,tone,noise,kick,snare,clap,hat,shaker,tom,riser,impact,beat,bar:beat*4,end:T.TE+3.5,
    /* run fn on every step between a and b */ each(a,b,step,fn){let k=0;for(let t=a;t<b-1e-6;t+=step,k++)fn(t,k)},
    swing(k,amt){return k%2?beat/2*(amt||0):0}};
  return {name:S.name,start(o2){off=o2||0;try{const r=ac.resume();if(r&&r.catch)r.catch(()=>{})}catch(e){}base=ac.currentTime+.04;S.score(P);if(S.epic!==false)knEpic(P,S);out.gain.cancelScheduledValues(ac.currentTime);out.gain.setValueAtTime(0,ac.currentTime);out.gain.linearRampToValueAtTime(S.gain||.95,ac.currentTime+.25)},
    stop(){try{out.gain.cancelScheduledValues(ac.currentTime);out.gain.setValueAtTime(out.gain.value,ac.currentTime);out.gain.linearRampToValueAtTime(0,ac.currentTime+.5)}catch(e){}setTimeout(()=>{nodes.forEach(n=>{try{n.stop()}catch(e){}});nodes.length=0;try{out.disconnect()}catch(e){}},600)}}}

/* the epic layer, the same big moments in every track, in the track's own key */
function knEpic(P,S){const {T,hz}=P,k=S.key||45,minor=S.minor!==false,third=minor?3:4,E=S.epicAmt||1;
  // fly in: swell into a sub boom
  P.swell(T.T1,1.6,.1*E);P.sub(T.T1,.45*E,2);
  // the car leaves the road: the biggest hit, braam, sub, stinger
  P.swell(T.T2,2.2,.18*E);P.sub(T.T2,.7*E,3);P.braam(T.T2,k-12,.045*E,3.6);P.sting(T.T2,.8*E);
  // track found: second hit and the choir comes in under the reveal
  P.swell(T.T3,1.4,.12*E);P.sub(T.T3,.5*E,2.2);P.braam(T.T3,k-12+(minor?8:5),.035*E,3);
  [[T.T3,[k+12,k+12+third,k+19]],[T.T4,[k+12+(minor?8:5),k+12+(minor?12:9),k+24]]].forEach(([t,ch])=>ch.forEach(m=>P.choir(t,m,T.T4-T.T3+(t===T.T4?T.T5+2.6-T.T4:0),.06*E)));
  // into the road appearing: a taiko roll that speeds up, a long swell, then everything at once
  const t=T.T5+2.7;let u=T.T5+.4,gap=.36;while(u<t-.06){P.kick(u,(.25+(u-T.T5)/2.3*.55)*E,{f0:95,f1:40,dec:.5,drop:.25,verb:.4});u+=gap;gap=Math.max(.07,gap*.84)}
  P.swell(t,2.6,.22*E);P.sub(t,.8*E,4);P.braam(t,k-12,.05*E,5);P.sting(t,1.1*E);
  [k+12,k+12+third,k+19,k+24].forEach(m=>P.choir(t,m,4.2,.07*E))}
/* the end chord when the line turns into a road, at T5+2.7, shared shape, each track gives its own notes and sound */
function knEnd(P,notes,o){const t=P.T.T5+2.7;o=o||{};P.impact(t,o.v||1);notes.forEach((m,i)=>P.tone(t+i*(o.roll==null?.06:o.roll),P.hz(m),o.dur||2.8,{type:o.type||'triangle',vol:o.vol||.1,att:.005,rel:2.4,verb:.8,echo:.3,pan:(i%2?.4:-.4)}))}

/* boss helpers */
function knKit(P){const {kick,snare,noise,hz,tone}=P;return{
  k:(t,v)=>kick(t,v||.8,{f0:140,f1:45,dec:.3}),
  sn:(t,v)=>{snare(t,v||.14,{verb:.3,bp:2100});noise(t,.12,{vol:(v||.14)*.6,hp:5000})},
  crash:(t,v)=>noise(t,2,{vol:v||.11,hp:5500,verb:.6}),
  ride:(t,v)=>{noise(t,.25,{vol:v||.035,hp:8000});tone(t,3800,.2,{vol:(v||.035)*.3,pluck:true})},
  roll:(a,b,v)=>{let k=0;for(let t=a;t<b;t+=P.beat/8,k++)snare(t,(v||.07)*(.5+.5*(t-a)/(b-a)),{verb:.25,f:200})},
  taiko:(t,v)=>{kick(t,v||.8,{f0:95,f1:38,dec:.8,drop:.3,verb:.5});noise(t,.22,{vol:(v||.8)*.12,lp:900,verb:.6})},
  gong:(t,v)=>{noise(t,3,{vol:(v||1)*.07,bp:600,q:1.5,verb:.9});[1,1.48,2.1,2.9].forEach((r,i)=>tone(t,hz(38)*r*2,3-i*.4,{vol:(v||1)*.04,pluck:true,verb:.8,vib:3,vibd:10}))}}}
/* a chord progression by bar, as offsets from the key */
const knProg=(k,list)=>b=>k+list[b%list.length];

const KN_TRACKS=[
/* 1 */{name:'Final Boss',mood:'Full orchestra at war. Racing strings, choir and brass',bpm:162,key:38,
 score(P){const {T,hz,tone,choir,braam}=P,K=knKit(P),s=P.beat/4,BAR=P.bar,R=knProg(38,[0,-4,-2,-5]),MEL=[74,77,76,74,73,74,77,81,79,77,76,74,73,70,73,76];
  P.each(0,P.end-3,BAR,(t,b)=>{const r=R(b),fin=t>=T.T5+2.5;if(fin)return;const big=t>=T.T2-.1;
   const OST=[0,0,3,0,2,0,-1,0];for(let k=0;k<16;k++){const m=r+24+OST[k%8];tone(t+k*s,hz(m),s*.9,{type:'sawtooth',vol:big?.05:.035,pluck:true,cut:big?2600:1400,pan:-.3});if(big)tone(t+k*s,hz(m+12),s*.9,{type:'sawtooth',vol:.03,pluck:true,cut:3200,pan:.3})}
   tone(t,hz(r-12),BAR,{type:'sawtooth',vol:.07,cut:400,att:.02});
   if(t>=T.T1-.1){[0,1,2,3].forEach(q=>K.k(t+q*P.beat,.75));K.k(t+P.beat*3.5,.5);[1,3].forEach(q=>K.sn(t+q*P.beat));if(b%2)K.roll(t+P.beat*3,t+BAR,.06);if(b%4===0)K.crash(t)}
   if(big){braam(t,r-12,.035,.45);braam(t+P.beat*2.5,r-12,.03,.4);for(let k=0;k<4;k++)tone(t+k*P.beat,hz(MEL[(b*4+k)%16]),P.beat*.95,{type:'sawtooth',vol:.06,att:.02,cut:2800,vib:5.5,vibd:10,verb:.4,pan:.1})}
   if(t>=T.T3-.1)[0,2].forEach(h=>[r+12,r+15,r+19].forEach(m=>choir(t+h*P.beat,m,P.beat*1.9,.05)))});
  K.crash(T.T2,.16);K.crash(T.T5+2.7,.18)}},

/* 2 */{name:'Dark Lord',mood:'A cathedral organ and a choir. The villain has arrived',bpm:136,key:36,room:.55,roomLen:3.2,
 score(P){const {T,hz,tone,choir}=P,K=knKit(P),s=P.beat/4,BAR=P.bar,CH=[[0,3,7],[-4,0,3],[-7,-3,0],[-1,2,5]];
  const organ=(t,m,d,v)=>[1,2,4].forEach((r,i)=>tone(t,hz(m)*r,d,{type:i?'sine':'square',vol:(v||.03)/(i+1),cut:i?0:2200,att:.01,rel:.05,verb:.6}));
  P.each(0,P.end-3,BAR,(t,b)=>{const c=CH[b%4].map(x=>x+60);if(t>=T.T5+2.5)return;const arp=[c[0],c[1],c[2],c[0]+12,c[2]+12,c[0]+12,c[2],c[1]];
   for(let k=0;k<16;k++)organ(t+k*s,arp[k%8]+(k>=8&&b%2?12:0),s*.95,t>=T.T2?.035:.025);organ(t,c[0]-24,BAR,.05);organ(t,c[0]-12,BAR,.03);
   if(t>=T.T1-.1)c.forEach(m=>choir(t,m+(t>=T.T3?12:0),BAR*.98,t>=T.T2?.06:.04));
   if(t>=T.T2-.1){[0,2].forEach(q=>K.taiko(t+q*P.beat,.85));[0,1.5,2,3].forEach(q=>K.k(t+q*P.beat,.7));[1,3].forEach(q=>K.sn(t+q*P.beat,.13));if(b%2===0)K.crash(t,.1)}
   if(t>=T.T1-.1&&t<T.T2-.1)K.taiko(t,.6)});
  K.gong(T.T2,1.2);K.gong(T.T5+2.7,1.4)}},

/* 3 */{name:'Metal Titan',mood:'Heavy metal. Chugging guitars and double kick drums',bpm:176,key:40,
 score(P){const {T,hz,tone,noise}=P,K=knKit(P),s=P.beat/4,BAR=P.bar;
  const gtr=(t,m,d,mute,v)=>[0,7,12].forEach((iv,i)=>[-12,12].forEach(det=>tone(t,hz(m+iv),d,{type:'sawtooth',vol:(v||.03)*(i?.7:1),drive:9,cut:mute?900:2600,q:1.2,det,att:.003,rel:.03,pan:det>0?.45:-.45})));
  const RIFF=[[0,40,1],[2,40,1],[3,40,1],[4,41,0],[6,40,1],[8,40,1],[9,40,1],[10,46,0],[12,45,0],[14,43,0]];
  P.each(0,P.end-3,BAR,(t,b)=>{if(t>=T.T5+2.5)return;
   if(t<T.T1-.1){gtr(t,40,BAR,false,.02);return}
   RIFF.forEach(([q,m,mu])=>gtr(t+q*s,m+(t>=T.T3&&b%2?2:0),mu?s*.9:s*1.9,mu,.03));tone(t,hz(28),BAR,{type:'sawtooth',vol:.06,cut:200});
   const dbl=t>=T.T2-.1;for(let k=0;k<16;k++)if(dbl||k%4===0)K.k(t+k*s,dbl?.55:.75);[1,3].forEach(q=>K.sn(t+q*P.beat,.16));for(let k=0;k<8;k++)K.ride(t+k*s*2,.03);if(b%2===0)K.crash(t,.12);
   if(t>=T.T3-.1)[[0,76],[1,79],[1.5,80],[2,79],[3,76],[3.5,74]].forEach(([q,m])=>tone(t+q*P.beat,hz(m),P.beat*.9,{type:'sawtooth',vol:.035,drive:6,cut:3200,vib:6,vibd:22,verb:.4,echo:.25}))});
  noise(T.T1-.6,.6,{vol:.1,hp:2000,sweep:9000,att:.55});K.crash(T.T2,.18);K.crash(T.T5+2.7,.2);gtr(T.T5+2.7,40,3.5,false,.04)}},

/* 4 */{name:'Cyber Core',mood:'A machine boss. Distorted synth bass and fast arps',bpm:150,key:42,
 score(P){const {T,hz,tone,noise,clap}=P,K=knKit(P),s=P.beat/4,BAR=P.bar,R=knProg(42,[0,0,-2,1]);
  P.each(0,P.end-3,BAR,(t,b)=>{const r=R(b);if(t>=T.T5+2.5)return;
   for(let k=0;k<16;k++){const m=r+(k%8===6?7:k%8===7?3:0)-(k%4===3?12:0);tone(t+k*s,hz(m),s*.85,{type:'sawtooth',vol:t>=T.T1?.07:.04,drive:6,cut:k%2?600:2400,cut2:250,q:6,pluck:true,pan:0})}
   if(t>=T.T1-.1){[0,1,2,3].forEach(q=>K.k(t+q*P.beat,.85));[1,3].forEach(q=>clap(t+q*P.beat,.1,{verb:.3}));for(let k=0;k<16;k++)noise(t+k*s,.025,{vol:k%4===2?.06:.025,hp:9000,pan:k%2?.4:-.4})}
   if(t>=T.T2-.1){const ar=[r+24,r+31,r+27,r+34,r+36,r+34,r+27,r+31];for(let k=0;k<16;k++)tone(t+k*s,hz(ar[k%8]),s*.7,{type:'square',vol:.025,pluck:true,echo:.3,pan:k%2?.5:-.5})}
   if(t>=T.T3-.1)[0,2].forEach(h=>tone(t+h*P.beat,hz(r+36),P.beat*1.9,{type:'sawtooth',vol:.035,drive:3,cut:4000,glide:h?.94:1.06,vib:7,vibd:30,verb:.5}));
   if(Math.random()<.5&&t>=T.T2)for(let g=0;g<6;g++)noise(t+BAR-s*2+g*s/3,.02,{vol:.06,bp:1200+g*900,q:8})});
  K.crash(T.T2,.15);K.crash(T.T5+2.7,.18)}},

/* 5 */{name:'Dragon War',mood:'War drums and gongs. Low horns and a battle choir',bpm:118,key:45,room:.5,roomLen:3,
 score(P){const {T,hz,tone,choir,braam}=P,K=knKit(P),e=P.beat/2,BAR=P.bar,OST=[0,0,3,0,7,6,3,2];
  P.each(0,P.end-3,BAR,(t,b)=>{if(t>=T.T5+2.5)return;const r=45+(b%4===3?-2:0);
   for(let k=0;k<8;k++)[-12,0].forEach(o=>tone(t+k*e,hz(r+OST[k]+o),e*.85,{type:'sawtooth',vol:t>=T.T2?.045:.03,cut:t>=T.T2?1600:800,att:.01,rel:.04,verb:.3}));
   if(t>=T.T1-.1){K.taiko(t,1);K.taiko(t+e*3,.6);K.taiko(t+e*4,.85);K.taiko(t+e*6,.5);K.taiko(t+e*7,.6);if(b%2===0)K.gong(t,.6)}
   if(t>=T.T1-.1)[r+12,r+15,r+19].forEach(m=>choir(t,m+(t>=T.T3?12:0),BAR*.98,.05));
   if(t>=T.T2-.1){braam(t,r-12,.035,.6);[[0,69],[1.5,72],[2,76],[3,74],[3.5,72]].forEach(([q,m])=>tone(t+q*P.beat,hz(m+(b%2?-3:0)),P.beat*1.4,{type:'sawtooth',vol:.05,att:.04,cut:2200,vib:5,vibd:12,verb:.6,pan:-.1}))}});
  K.gong(T.T2,1.3);K.gong(T.T5+2.7,1.5)}},

/* 6 */{name:'Phase Two',mood:'The boss gets angrier. Chromatic riff and a key change',bpm:170,key:47,
 score(P){const {T,hz,tone,choir}=P,K=knKit(P),s=P.beat/4,BAR=P.bar,RIFF=[0,1,0,-1,0,3,2,1];
  P.each(0,P.end-3,BAR,(t,b)=>{if(t>=T.T5+2.5)return;const up=t>=T.T3-.1?3:0,r=47+up;
   for(let k=0;k<16;k++){const m=r+RIFF[(k>>1)%8];tone(t+k*s,hz(m),s*.9,{type:'sawtooth',vol:.045,drive:4,cut:1800,pluck:true,pan:-.25});tone(t+k*s,hz(m+12),s*.9,{type:'sawtooth',vol:.03,pluck:true,cut:2800,pan:.25})}
   tone(t,hz(r-24),BAR,{type:'sawtooth',vol:.07,drive:3,cut:300});
   if(t>=T.T1-.1){K.k(t);K.k(t+s*6);K.k(t+s*10,.7);[4,12].forEach(q=>K.sn(t+q*s,.15));for(let k=0;k<16;k+=2)K.ride(t+k*s);if(b%2===0)K.crash(t,.1)}
   if(t>=T.T2-.1)[r+12,r+15,r+18].forEach(m=>choir(t,m,BAR*.95,.05));
   if(t>=T.T3-.1)for(let k=0;k<8;k++)tone(t+k*s*2,hz(r+24+[0,3,7,6,3,1,0,-1][k]),s*1.8,{type:'square',vol:.03,cut:3500,echo:.3,pan:.1})});
  K.crash(T.T2,.16);K.crash(T.T3,.16);K.crash(T.T5+2.7,.2)}},

/* 7 */{name:'Savanna Warlord',mood:'African war drums and chants. The bush boss',bpm:126,key:43,
 score(P){const {T,hz,tone,choir,braam,shaker}=P,K=knKit(P),s=P.beat/4,BAR=P.bar;
  P.each(0,P.end-3,BAR,(t,b)=>{if(t>=T.T5+2.5)return;
   for(let k=0;k<16;k++)shaker(t+k*s,k%4===0?.06:.03,k%2?.3:-.3);
   [[0,43,1],[3,50,.5],[6,50,.6],[8,43,.9],[10,55,.5],[11,55,.5],[14,50,.6]].forEach(([q,m,v])=>P.tom(t+q*s,m,.3*v,{pan:(q%3-1)*.4}));
   if(t>=T.T1-.1){K.taiko(t,.9);K.taiko(t+s*8,.8);if(t>=T.T2-.1){K.taiko(t+s*12,.6);K.taiko(t+s*14,.6)}}
   if(t>=T.T1-.1)[[0,67],[2,67],[3,70],[4,67],[6,65],[7,62]].forEach(([q,m])=>choir(t+q*P.beat/2,m-(b%2?2:0)+(t>=T.T3?5:0),P.beat*.45,.08));
   if(t>=T.T2-.1){braam(t,31,.035,.5);braam(t+P.beat*2,34,.03,.4);for(let k=0;k<8;k++)tone(t+k*s*2,hz(31+[0,0,3,0,5,3,0,-2][k]),s*1.8,{type:'sawtooth',vol:.06,cut:700,att:.01})}});
  K.gong(T.T2,1);K.gong(T.T5+2.7,1.3)}},

/* 8 */{name:'Rage Mode',mood:'Half-time wobble bass. Heavy, dirty and loud',bpm:140,key:38,
 score(P){const {T,hz,tone,noise}=P,K=knKit(P),e=P.beat/2,BAR=P.bar,R=knProg(38,[0,0,3,-2]);
  P.each(0,P.end-3,BAR,(t,b)=>{const r=R(b);if(t>=T.T5+2.5)return;
   if(t<T.T2-.1){tone(t,hz(r+12),BAR,{type:'sawtooth',vol:.03,cut:600+t*120,att:.4,verb:.5});if(t>=T.T1-.1){K.k(t,.8);K.sn(t+P.beat*2,.14);for(let k=0;k<8;k++)noise(t+k*e,.03,{vol:.03,hp:9000})}return}
   const W=[1800,300,2400,500,1200,300,3000,400];for(let k=0;k<8;k++)tone(t+k*e,hz(r-12+(k===6?12:0)),e*.95,{type:'sawtooth',vol:.07,drive:8,cut:W[k],cut2:W[(k+1)%8],q:8,att:.005,rel:.02});
   tone(t,hz(r-24),BAR,{vol:.15,att:.01});K.k(t,.95);K.k(t+e*5,.6);K.sn(t+P.beat*2,.2);for(let k=0;k<8;k++)K.ride(t+k*e,.03);if(b%2===0)K.crash(t,.12);
   if(t>=T.T3-.1)[[0,74],[.75,77],[1.5,74],[3,72]].forEach(([q,m])=>tone(t+q*P.beat,hz(m),P.beat*.6,{type:'square',vol:.03,cut:3000,echo:.4,verb:.3}))});
  noise(T.T2-.02,.05,{vol:0});K.crash(T.T2,.18);K.crash(T.T5+2.7,.2)}},

/* 9 */{name:'8-bit Final Boss',mood:'The last level of an old video game. Fast and evil',bpm:184,key:45,room:.15,gain:1.4,epicAmt:.7,
 score(P){const {T,hz,tone,noise}=P,s=P.beat/4,BAR=P.bar,CH=[[57,60,64],[53,57,60],[52,56,59],[57,60,64]],LEAD=[69,72,76,75,76,72,69,68,69,71,72,71,72,74,76,80];
  P.each(0,P.end-3,BAR,(t,b)=>{const c=CH[b%4];if(t>=T.T5+2.5)return;
   for(let k=0;k<16;k++)tone(t+k*s,hz(c[k%3]+12+(k%4===3?12:0)),s*.9,{type:'square',vol:.025,att:.002,rel:.01,cut:5000});
   for(let k=0;k<8;k++)tone(t+k*s*2,hz(c[0]-24+(k%2?12:0)),s*1.8,{type:'triangle',vol:.14,att:.002,rel:.02});
   if(t>=T.T1-.1){[0,4,8,12].forEach(q=>noise(t+q*s,.06,{vol:.12,lp:800}));[4,12].forEach(q=>noise(t+q*s,.08,{vol:.1,hp:2500}));for(let k=0;k<16;k++)noise(t+k*s,.015,{vol:.03,hp:9000})}
   if(t>=T.T2-.1)for(let k=0;k<16;k++)tone(t+k*s,hz(LEAD[(k+b*4)%16]+(t>=T.T3?12:0)),s*.95,{type:'square',vol:.04,att:.002,rel:.02,cut:4500,det:10})});
  const t=T.T5+2.7;[[0,69],[1,72],[2,76],[3,81],[5,80],[6,81]].forEach(([q,m])=>tone(t+q*s,hz(m),q===6?1.5:s*.95,{type:'square',vol:.07,cut:5000,rel:.05}))}},

/* 10 */{name:'Last Stand',mood:'Heroic and huge. Everything rises for the final blow',bpm:150,key:40,room:.5,roomLen:3,
 score(P){const {T,hz,tone,choir,braam}=P,K=knKit(P),s=P.beat/4,BAR=P.bar,PR=[0,-4,-7,-2],HERO=[[0,76],[1,79],[1.5,78],[2,76],[3,83]];
  P.each(0,P.end-3,BAR,(t,b)=>{if(t>=T.T5+2.5)return;const lift=t>=T.T3-.1?2:0,r=40+PR[b%4]+lift;
   for(let k=0;k<16;k++)tone(t+k*s,hz(r+24+(k%4===2?7:k%4===3?12:0)),s*.9,{type:'sawtooth',vol:.04,pluck:true,cut:2400,pan:k%2?.3:-.3});
   for(let k=0;k<8;k++)tone(t+k*s*2,hz(r-12),s*1.7,{type:'sawtooth',vol:.07,drive:3,cut:500,pluck:true});
   if(t>=T.T1-.1){[0,1,2,3].forEach(q=>K.k(t+q*P.beat,.8));[1,3].forEach(q=>K.sn(t+q*P.beat,.15));K.taiko(t,.7);if(b%2)K.roll(t+P.beat*3,t+BAR,.07);if(b%4===0)K.crash(t,.12)}
   if(t>=T.T2-.1){braam(t,r-12,.035,.5);HERO.forEach(([q,m])=>tone(t+q*P.beat,hz(m+lift-(b%4===1?4:0)),P.beat*.95,{type:'sawtooth',vol:.06,att:.02,cut:3200,vib:5,vibd:10,verb:.5}))}
   if(t>=T.T2-.1)[r+12,r+16,r+19].forEach(m=>choir(t,m+12,BAR*.98,.045))});
  K.crash(T.T2,.17);K.crash(T.T3,.15);K.crash(T.T5+2.7,.2)}}
];
