import io, math, random
import numpy as np
import pandas as pd
import requests

URL='https://raw.githubusercontent.com/getdata-finance/nvda-3m-ohlcv-stocks-historical-data/main/NVDA_3m.csv'
FEE=0.0005; SLIP=0.01

def rma(x,n):
    x=np.asarray(x,float); out=np.full(len(x),np.nan); a=1.0/n
    if len(x)<n:return out
    out[n-1]=np.nanmean(x[:n])
    for i in range(n,len(x)): out[i]=a*x[i]+(1-a)*out[i-1]
    return out

def ema(x,n): return pd.Series(x).ewm(span=n,adjust=False).mean().to_numpy()
def rsi(c,n):
    d=np.diff(c,prepend=c[0]); up=np.maximum(d,0); dn=np.maximum(-d,0); au=rma(up,n); ad=rma(dn,n)
    rs=np.divide(au,ad,out=np.full_like(au,np.nan),where=ad!=0); return 100-100/(1+rs)

def load():
    d=pd.read_csv(io.StringIO(requests.get(URL,timeout=60).text)); d['datetime']=pd.to_datetime(d.datetime,utc=True); d=d.sort_values('datetime').drop_duplicates('datetime')
    d['ny']=d.datetime.dt.tz_convert('America/New_York'); m=d.ny.dt.hour*60+d.ny.dt.minute; d=d[(m>=570)&(m<960)].copy().reset_index(drop=True)
    d['date']=d.ny.dt.date; d['minute']=d.ny.dt.hour*60+d.ny.dt.minute
    o=d.open.to_numpy(float); h=d.high.to_numpy(float); l=d.low.to_numpy(float); c=d.close.to_numpy(float); v=d.volume.to_numpy(float); date=d.date.to_numpy(); minute=d.minute.to_numpy(int)
    tp=(h+l+c)/3; vwap=np.empty(len(c)); orh={}; orl={}
    for _,ids0 in d.groupby('date').groups.items():
        ids=np.asarray(list(ids0)); sw=np.cumsum(v[ids]); vwap[ids]=np.cumsum(tp[ids]*v[ids])/sw
        for bars in [1,3,5,10]:
            z=ids[:bars]; orh[(ids[0],bars)]=np.max(h[z]); orl[(ids[0],bars)]=np.min(l[z])
    first_idx={dt:int(ids[0]) for dt,ids in d.groupby('date').groups.items()}
    rangehi={b:np.empty(len(c)) for b in [1,3,5,10]}; rangelo={b:np.empty(len(c)) for b in [1,3,5,10]}
    for dt,ids0 in d.groupby('date').groups.items():
        ids=np.asarray(list(ids0)); fi=ids[0]
        for b in [1,3,5,10]: rangehi[b][ids]=orh[(fi,b)]; rangelo[b][ids]=orl[(fi,b)]
    e9=ema(c,9); e20=ema(c,20); e50=ema(c,50); e200=ema(c,200)
    pc=np.r_[np.nan,c[:-1]]; tr=np.nanmax(np.vstack([h-l,np.abs(h-pc),np.abs(l-pc)]),axis=0); tr[0]=h[0]-l[0]; atr=rma(tr,14)
    up=np.diff(h,prepend=h[0]); dn=-np.diff(l,prepend=l[0]); plus=np.where((up>dn)&(up>0),up,0.0); minus=np.where((dn>up)&(dn>0),dn,0.0)
    pdi=100*rma(plus,14)/atr; mdi=100*rma(minus,14)/atr; den=pdi+mdi; dx=np.divide(100*np.abs(pdi-mdi),den,out=np.zeros_like(c),where=np.isfinite(den)&(den!=0)); adx=rma(np.nan_to_num(dx),14)
    rs=rsi(c,7); rr=h-l; body=np.abs(c-o); strength=np.divide(body,rr,out=np.zeros_like(c),where=rr>0); closepos=np.divide(c-l,rr,out=np.full_like(c,.5),where=rr>0)
    return dict(d=d,o=o,h=h,l=l,c=c,v=v,date=date,minute=minute,vwap=vwap,atr=atr,adx=adx,pdi=pdi,mdi=mdi,e9=e9,e20=e20,e50=e50,e200=e200,pc=pc,rs=rs,strength=strength,closepos=closepos,rangehi=rangehi,rangelo=rangelo)

def metrics(p):
    p=np.asarray(p,float)
    if len(p)==0:return dict(trades=0,wins=0,win_rate=0.,pf=0.,net=0.,maxdd=0.,avg=0.)
    gp=p[p>0].sum(); gl=-p[p<0].sum(); pf=gp/gl if gl>0 else 99.; eq=np.cumsum(p); peak=np.maximum.accumulate(np.r_[0.,eq])[:-1]
    return dict(trades=len(p),wins=int((p>0).sum()),win_rate=float((p>0).mean()*100),pf=float(pf),net=float(p.sum()),maxdd=float((peak-eq).max()),avg=float(p.mean()))

def build_signals(A,p):
    c=A['c']; pc=A['pc']; minute=A['minute']; atr=A['atr']; adx=A['adx']; rs=A['rs']; cp=A['closepos']; st=A['strength']; vwap=A['vwap']
    L=np.zeros(len(c),bool); S=np.zeros(len(c),bool)
    for bars in p['ranges']:
        hi=A['rangehi'][bars]; lo=A['rangelo'][bars]; ready=minute >= 570+3*bars
        buffer=p['buffer']*atr
        ll=(c>hi+buffer)&(pc<=hi+buffer)&ready
        ss=(c<lo-buffer)&(pc>=lo-buffer)&ready
        L|=ll; S|=ss
    sess=(minute>=p['start'])&(minute<=p['end'])&np.isfinite(atr)&np.isfinite(adx)
    L &= sess&(cp>=p['closepos'])&(st>=p['body'])&(adx>=p['adx'])&(A['pdi']>A['mdi'])
    S &= sess&(cp<=(1-p['closepos']))&(st>=p['body'])&(adx>=p['adx'])&(A['mdi']>A['pdi'])
    if p['vwap']:
        L &= c>vwap; S &= c<vwap
    if p['trend']==1:
        L &= (A['e9']>A['e20'])&(c>A['e20']); S &= (A['e9']<A['e20'])&(c<A['e20'])
    elif p['trend']==2:
        L &= (A['e20']>A['e50'])&(c>A['e50']); S &= (A['e20']<A['e50'])&(c<A['e50'])
    elif p['trend']==3:
        L &= c>A['e200']; S &= c<A['e200']
    if p['rsi']:
        L &= rs<=p['rsi_hi']; S &= rs>=100-p['rsi_hi']
    if p['side']=='long': S[:]=False
    return L,S

def simulate(A,p):
    L,S=build_signals(A,p); sig=np.flatnonzero(L|S); date=A['date']; minute=A['minute']; o=A['o']; h=A['h']; l=A['l']; c=A['c']; atr=A['atr']
    trades=[]; next_allowed=-1; k=0; day=None; day_count=0; n=len(c)
    while k<len(sig):
        i=int(sig[k]); dt=date[i]
        if day!=dt: day=dt; day_count=0
        if i<next_allowed or day_count>=p['maxday'] or i+1>=n or date[i+1]!=dt: k+=1; continue
        side=1 if L[i] else -1; ei=i+1; entry=o[ei]+(SLIP if side==1 else -SLIP); a=atr[i]; day_count+=1
        if not np.isfinite(a) or a<=0: k+=1; continue
        stop=entry-side*p['stop']*a; target=entry+side*p['target']*a; maxexit=min(ei+p['bars'],n-1); exit_i=maxexit; exit_px=c[maxexit]-(SLIP if side==1 else -SLIP)
        for j in range(ei,maxexit+1):
            hs=(l[j]<=stop) if side==1 else (h[j]>=stop); ht=(h[j]>=target) if side==1 else (l[j]<=target)
            if hs or ht:
                if hs: exit_px=stop-(SLIP if side==1 else -SLIP)
                else: exit_px=target
                exit_i=j; break
            if date[j]!=dt or minute[j]>=957:
                exit_px=c[j]-(SLIP if side==1 else -SLIP); exit_i=j; break
        pnl=side*(exit_px-entry)-(entry+exit_px)*FEE; trades.append((dt,pnl,side)); next_allowed=exit_i+p['cool']; k=int(np.searchsorted(sig,next_allowed,'left'))
    return trades

def randp(r):
    sets=[(1,),(3,),(5,),(1,3),(1,5),(3,5),(1,3,5),(1,3,5,10)]
    p=dict(ranges=r.choice(sets),buffer=r.choice([0.,0.05,0.1,0.2,0.3,0.5]),start=r.choice([579,585,600,630,660]),end=r.choice([720,750,840,900,930]),closepos=r.choice([.55,.65,.75,.85,.9]),body=r.choice([.2,.35,.5,.65]),adx=r.choice([10,12,15,18,20,22,25,28]),vwap=r.choice([True,False]),trend=r.choice([0,1,2,3]),rsi=r.choice([True,False]),rsi_hi=r.choice([65,70,75,80,85]),side=r.choice(['both','both','long']),stop=r.choice([.7,.85,1.,1.2,1.4]),target=r.choice([.7,.85,1.,1.2,1.4,1.6]),bars=r.choice([6,10,15,20,30]),cool=r.choice([1,2,3,5]),maxday=r.choice([1,2,3,4]))
    if p['end']<=p['start']:p['end']=930
    return p

def foldm(tr,lo,hi): return metrics([x[1] for x in tr if lo<=x[0]<=hi])
def devscore(ms):
    total=sum(m['trades'] for m in ms); pos=sum(m['net']>0 for m in ms); goodpf=sum(m['pf']>=1 for m in ms)
    if total<70 or pos<3 or goodpf<3:return -1e9
    return 2*np.median([m['pf'] for m in ms])+np.median([m['win_rate'] for m in ms])/40+math.log1p(total)/3-.08*max(m['maxdd'] for m in ms)

def main():
    A=load(); dates=sorted(np.unique(A['date'])); hold=(dates[-20],dates[-1]); dev=dates[:-20]; chunks=np.array_split(np.array(dev,dtype=object),4); folds=[(x[0],x[-1]) for x in chunks]
    print('DATA',dates[0],dates[-1],'days',len(dates),'HOLD',hold,'FOLDS',folds)
    r=random.Random(2601002); surv=[]; N=60000
    for q in range(N):
        p=randp(r); tr=simulate(A,p); ms=[foldm(tr,*f) for f in folds]; s=devscore(ms)
        if s>-1e8:surv.append((s,p,ms,tr))
    surv.sort(key=lambda x:x[0],reverse=True); print('SURV',len(surv),'of',N); out=[]
    for rank,(s,p,ms,tr) in enumerate(surv[:100],1):
        hm=foldm(tr,*hold); fm=metrics([x[1] for x in tr]); dm=metrics([x[1] for x in tr if x[0]<hold[0]])
        passh=hm['trades']>=12 and hm['win_rate']>=50 and hm['pf']>=1.2 and hm['net']>0; passf=fm['trades']>=100 and fm['win_rate']>=50 and fm['pf']>=1.2 and fm['net']>0
        if rank<=20 or (passh and passf): print('\nR',rank,p,'\nFOLDS',ms,'\nDEV',dm,'\nHOLD',hm,'\nFULL',fm,'PASS',passh,passf)
        row={'rank':rank,'score':s,**p,**{f'hold_{k}':v for k,v in hm.items()},**{f'full_{k}':v for k,v in fm.items()},**{f'dev_{k}':v for k,v in dm.items()},'pass_hold':passh,'pass_full':passf}
        out.append(row)
    pd.DataFrame(out).to_csv('nvda_multi_orb_results.csv',index=False)
    good=[x for x in out if x['pass_hold'] and x['pass_full']]
    if good:
        pd.DataFrame([good[0]]).to_csv('nvda_multi_orb_winner.csv',index=False); print('\nWINNER',good[0])
    else: print('\nNO WINNER')
if __name__=='__main__':main()
