import json,math,collections
d=json.load(open('/home/claude/work/data4.json'))
KX=111320*math.cos(math.radians(-24.388));KY=110574
def m(p):return (p[0]*KX,p[1]*KY)
def ll(q):return [round(q[0]/KX,7),round(q[1]/KY,7)]
def cr(P,step=6.0):
    """centripetal Catmull-Rom through every point (all original points stay exactly where they are)"""
    if len(P)<3:return P
    Q=[m(p) for p in P];out=[P[0]]
    for i in range(len(Q)-1):
        p0=Q[i-1] if i>0 else (2*Q[0][0]-Q[1][0],2*Q[0][1]-Q[1][1])
        p1,p2=Q[i],Q[i+1]
        p3=Q[i+2] if i+2<len(Q) else (2*Q[-1][0]-Q[-2][0],2*Q[-1][1]-Q[-2][1])
        L=math.dist(p1,p2)
        # how much does it bend here? straight runs get no extra points
        def ang(a,b,c):
            v1=(b[0]-a[0],b[1]-a[1]);v2=(c[0]-b[0],c[1]-b[1]);n1=math.hypot(*v1);n2=math.hypot(*v2)
            if n1<1e-6 or n2<1e-6:return 0
            return abs(math.degrees(math.atan2(v1[0]*v2[1]-v1[1]*v2[0],v1[0]*v2[0]+v1[1]*v2[1])))
        bend=max(ang(p0,p1,p2) if i>0 else 0,ang(p1,p2,p3) if i+2<len(Q) else 0)
        n=0 if bend<6 or L<6 else min(8,int(L/step))
        if n>1:
            a=.5
            def tj(t,pa,pb):return t+max(1e-6,math.dist(pa,pb))**a
            t0=0;t1=tj(t0,p0,p1);t2=tj(t1,p1,p2);t3=tj(t2,p2,p3)
            for k in range(1,n):
                t=t1+(t2-t1)*k/n
                def lerp(pa,pb,ta,tb):return ((tb-t)/(tb-ta)*pa[0]+(t-ta)/(tb-ta)*pb[0],(tb-t)/(tb-ta)*pa[1]+(t-ta)/(tb-ta)*pb[1])
                A1=lerp(p0,p1,t0,t1);A2=lerp(p1,p2,t1,t2);A3=lerp(p2,p3,t2,t3)
                B1=lerp(A1,A2,t0,t2);B2=lerp(A2,A3,t1,t3);C=lerp(B1,B2,t1,t2)
                out.append(ll(C))
        out.append(P[i+1])
    return out
n0=n1=0
for f in d['roads']['features']:
    c=f['geometry']['coordinates'];n0+=len(c);s=cr(c);f['geometry']['coordinates']=s;n1+=len(s)
print('road points',n0,'->',n1)
# dams: counter-clockwise outer rings (so the inner shore shading works)
def area(r):return sum(r[i][0]*r[i+1][1]-r[i+1][0]*r[i][1] for i in range(len(r)-1))/2
for f in d['water']['features']:
    r=f['geometry']['coordinates'][0]
    if area(r)<0:f['geometry']['coordinates'][0]=r[::-1]
# Hippo Dam pin sits on the bank: move it into the water
for f in d['pois']['features']:
    if f['properties'].get('name')=='Hippo Dam':f['geometry']['coordinates']=[30.95541,-24.40233]
json.dump(d,open('/home/claude/work/data5.json','w'),separators=(',',':'))
print('ok')
