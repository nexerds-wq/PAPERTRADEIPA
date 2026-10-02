import io, math, random
import numpy as np
import pandas as pd
import requests

URL='https://raw.githubusercontent.com/getdata-finance/nvda-3m-ohlcv-stocks-historical-data/main/NVDA_3m.csv'
FEE=0.0005
SLIP=0.01

def rma(x,n):
    x=np.asarray(x,float); out=np.full(len(x),np.nan); a=1.0/n
    if len(x)<n:return out
    out[n-1]=np.nanmean(x[:n])
    for i in range(n,len(x)): out[i]=a*x[i]+(1-a)*out[i-1]
    return out

def ema(x,n): return pd.Series(x).ewm(span=n,adjust=False).mean().to_numpy()
def load():
    d=pd.read_csv(io.StringIO(requests.get(URL,timeout=60).text)); d['datetime']=pd.to_datetime(d.datetime,utc=True); d=d.sort_values('datetime').drop_duplicates('datetime')
    d['ny']=d.datetime.dt.tz_convert('America/New_York'); m=d.ny.dt.hour*60+d.ny.dt.minute; d=d[(m>=570)&(m<960)].copy().reset_index(drop=True)
    d['date']=d.ny.dt.date; d['minute']=d.ny.dt.hour*60+d.ny.dt.minute
    o=d.open.to_numpy(float); h=d.high.to_numpy(float); l=d.low.to_numpy(float); c=d.close.to_numpy(float); v=d.volume.to_numpy(float); date=d.date.to_numpy(); minute=d.minute.to_numpy(int)
    tp=(h+l+c)/3; vwap=np.empty(len(c)); rangehi={b:np.empty(len(c)) for b in [1,2,3,5,10]}; rangelo={b:np.empty(len(c)) for b in [1,2,3,5,10]}
    for _,ids0 in d.groupby('date').groups.items():
        ids=np.asarray(list(ids0)); vwap[ids]=np.cumsum(tp[ids]*v[ids])/np.cumsum(v[ids])
        for b in [1,2,3,5,10]: rangehi[b][ids]=np.max(h[ids[:b]]); rangelo[b][ids]=np.min(l[ids[:b]])
    pc=np.r_[np.nan,c[:-1]]; tr=np.nanmax(np.vstack([h-l,np.abs(h-pc),np.abs(l-pc)]),axis=0); tr[0]=h[0]-l[0]; atr=rma(tr,14)
    up=np.diff(h,prepend=h[0]); dn=-np.diff(l,prepend=l[0]); plus=np.where((up>dn)&(up>0),up,0.); minus=np.where((dn>up)&(dn>0),dn,0.)
    pdi=100*rma(plus,14)/atr; mdi=100*rma(minus,14)/atr; den=pdi+mdi; dx=np.divide(100*np.abs(pdi-mdi),den,out=np.zeros_like(c),where=np.isfinite(den)&(den!=0)); adx=rma(np.nan_to_num(dx),14)
    rr=h-l; closepos=np.divide(c-l,rr,out=np.full_like(c,.5),where=rr>0)
    e20=ema(c,20); e50=ema(c,50); e200=ema(c,200)
    return dict(o=o,h=h,l=l,c=c,date=date,minute=minute,vwap=vwap,rangehi=rangehi,rangelo=rangelo,pc=pc,atr=atr,adx=adx,closepos=closepos,e20=e20,e50=e50,e200=e200)

def metrics(p):
    p=np.asarray(p,float)
    if len(p)==0:return dict(trades=0,wins=0,win_rate=0.,pf=0.,net=0.,maxdd=0.,avg=0.)
    gp=p[p>0].sum(); gl=-p[p<0].sum(); pf=gp/gl if gl>0 else 99.; eq=np.cumsum(p); peak=np.maximum.accumulate(np.r_[0.,eq])[:-1]
    return dict(trades=len(p),wins=int((p>0).sum()),win_rate=float((p>0).mean()*100),pf=float(pf),net=float(p.sum()),maxdd=float((peak-eq).max()),avg=float(p.mean()))

def signals(A,p):
    c=A['c']; pc=A['pc']; minute=A['minute']; atr=A['atr']; adx=A['adx']; cp=A['closepos']; L=np.zeros(len(c),bool); S=np.zeros(len(c),bool)
    for b in p['ranges']:
        hi=A['rangehi'][b]; lo=A['rangelo'][b]; ready=minute>=570+3*b; buf=p['buffer']*atr
        L |= (c>hi+buf)&(pc<=hi+buf)&ready
        S |= (c<lo-buf)&(pc>=lo-buf)&ready
    gate=(minute>=p['start'])&(minute<=p['end'])&(adx>=p['adx'])&np.isfinite(atr)
    L &= gate&(cp>=p['strength']); S &= gate&(cp<=1-p['strength'])
    if p['vwap']: L &= c>A['vwap']; S &= c<A['vwap']
    if p['ema']==20: L &= c>A['e20']; S &= c<A['e20']
    elif p['ema']==50: L &= c>A['e50']; S &= c<A['e50']
    elif p['ema']==200: L &= c>A['e200']; S &= c<A['e200']
    if p['side']=='long': S[:]=False
    return L,S

def simulate(A,p):
    L,S=signals(A,p); sig=np.flatnonzero(L|S); date=A['date']; minute=A['minute']; o=A['o']; h=A['h']; l=A['l']; c=A['c']; atr=A['atr']; trades=[]; nextok=-1; k=0; curday=None; dayn=0; n=len(c)
    while k<len(sig):
        i=int(sig[k]); dt=date[i]
        if curday!=dt:curday=dt;dayn=0
        if i<nextok or dayn>=p['maxday'] or i+1>=n or date[i+1]!=dt:k+=1;continue
        side=1 if L[i] else -1; ei=i+1; entry=o[ei]+(SLIP if side==1 else -SLIP); a=atr[i]; dayn+=1
        if not np.isfinite(a) or a<=0:k+=1;continue
        stop=entry-side*p['stop']*a; target=entry+side*p['target']*a; maxexit=min(ei+p['bars'],n-1); exit_i=maxexit; exit_px=c[maxexit]-(SLIP if side==1 else -SLIP)
        for j in range(ei,maxexit+1):
            hs=(l[j]<=stop) if side==1 else (h[j]>=stop); ht=(h[j]>=target) if side==1 else (l[j]<=target)
            if hs or ht:
                exit_px=(stop-(SLIP if side==1 else -SLIP)) if hs else target; exit_i=j; break
            if date[j]!=dt or minute[j]>=957:
                exit_px=c[j]-(SLIP if side==1 else -SLIP); exit_i=j; break
        trades.append((dt,side*(exit_px-entry)-(entry+exit_px)*FEE,side)); nextok=exit_i+p['cool']; k=int(np.searchsorted(sig,nextok,'left'))
    return trades

def randp(r):
    range_sets=[(1,),(2,),(3,),(5,),(1,2),(1,3),(1,5),(2,3),(2,5),(3,5),(1,2,3),(1,3,5),(1,2,3,5),(1,2,3,5,10)]
    p=dict(ranges=r.choice(range_sets),buffer=r.choice([0.,.025,.05,.075,.1,.15,.2]),start=r.choice([600,615,630,645,660]),end=r.choice([780,810,840,870,900,930]),strength=r.choice([.75,.8,.85,.9,.925,.95]),adx=r.choice([8,10,12,14,16,18,20]),vwap=r.choice([False,False,True]),ema=r.choice([0,0,20,50,200]),side=r.choice(['both','both','long']),stop=r.choice([.8,.9,1.,1.1,1.2,1.3]),target=r.choice([.8,.9,1.,1.1,1.2,1.3]),bars=r.choice([10,15,20,25,30]),cool=r.choice([1,2,3,5]),maxday=r.choice([1,2,3,4]))
    if p['end']<=p['start']:p['end']=900
    return p

def foldm(tr,lo,hi):return metrics([x[1] for x in tr if lo<=x[0]<=hi])
def score(ms):
    total=sum(m['trades'] for m in ms); positive=sum(m['net']>0 for m in ms); pfok=sum(m['pf']>=1 for m in ms)
    if total<75 or positive<3 or pfok<3:return -1e9
    return 3*np.median([m['pf'] for m in ms])+np.median([m['win_rate'] for m in ms])/30+math.log1p(total)/3-.1*max(m['maxdd'] for m in ms)

def main():
    A=load(); dates=sorted(np.unique(A['date'])); hold=(dates[-20],dates[-1]); dev=dates[:-20]; chunks=np.array_split(np.array(dev,dtype=object),4); folds=[(x[0],x[-1]) for x in chunks]
    print('DATA',dates[0],dates[-1],'DAYS',len(dates),'FOLDS',folds,'HOLD',hold)
    r=random.Random(777777); surv=[]; N=80000
    for _ in range(N):
        p=randp(r); tr=simulate(A,p); ms=[foldm(tr,*f) for f in folds]; s=score(ms)
        if s>-1e8:surv.append((s,p,ms,tr))
    surv.sort(key=lambda x:x[0],reverse=True);print('SURV',len(surv),'OF',N);out=[]
    for rank,(s,p,ms,tr) in enumerate(surv[:150],1):
        hm=foldm(tr,*hold); fm=metrics([x[1] for x in tr]); dm=metrics([x[1] for x in tr if x[0]<hold[0]])
        passh=hm['trades']>=12 and hm['win_rate']>=50 and hm['pf']>=1.2 and hm['net']>0; passf=fm['trades']>=100 and fm['win_rate']>=50 and fm['pf']>=1.2 and fm['net']>0
        if rank<=20 or (passh and passf):print('\nR',rank,p,'\nFOLDS',ms,'\nDEV',dm,'\nHOLD',hm,'\nFULL',fm,'PASS',passh,passf)
        row={'rank':rank,'score':s,**p,**{f'hold_{k}':v for k,v in hm.items()},**{f'full_{k}':v for k,v in fm.items()},**{f'dev_{k}':v for k,v in dm.items()},'pass_hold':passh,'pass_full':passf};out.append(row)
    pd.DataFrame(out).to_csv('nvda_rank7_expand_results.csv',index=False);good=[x for x in out if x['pass_hold'] and x['pass_full']]
    if good:pd.DataFrame([good[0]]).to_csv('nvda_rank7_winner.csv',index=False);print('\nWINNER',good[0])
    else:print('\nNO WINNER')
if __name__=='__main__':main()
