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
    d=pd.read_csv(io.StringIO(requests.get(URL,timeout=60).text))
    d['datetime']=pd.to_datetime(d.datetime,utc=True)
    d=d.sort_values('datetime').drop_duplicates('datetime')
    d['ny']=d.datetime.dt.tz_convert('America/New_York')
    m=d.ny.dt.hour*60+d.ny.dt.minute
    d=d[(m>=570)&(m<960)].copy().reset_index(drop=True)
    d['date']=d.ny.dt.date; d['minute']=d.ny.dt.hour*60+d.ny.dt.minute
    o=d.open.to_numpy(float); h=d.high.to_numpy(float); l=d.low.to_numpy(float); c=d.close.to_numpy(float); v=d.volume.to_numpy(float); date=d.date.to_numpy(); minute=d.minute.to_numpy(int)
    tp=(h+l+c)/3
    vwap=np.empty(len(c))
    rangehi={b:np.empty(len(c)) for b in [1,2,3,5,10]}
    rangelo={b:np.empty(len(c)) for b in [1,2,3,5,10]}
    for _,ids0 in d.groupby('date').groups.items():
        ids=np.asarray(list(ids0)); vv=v[ids]
        vwap[ids]=np.cumsum(tp[ids]*vv)/np.cumsum(vv)
        for b in [1,2,3,5,10]:
            rangehi[b][ids]=np.max(h[ids[:b]]); rangelo[b][ids]=np.min(l[ids[:b]])
    pc=np.r_[np.nan,c[:-1]]
    tr=np.nanmax(np.vstack([h-l,np.abs(h-pc),np.abs(l-pc)]),axis=0); tr[0]=h[0]-l[0]
    atr=rma(tr,14)
    up=np.diff(h,prepend=h[0]); dn=-np.diff(l,prepend=l[0])
    plus=np.where((up>dn)&(up>0),up,0.); minus=np.where((dn>up)&(dn>0),dn,0.)
    pdi=100*rma(plus,14)/atr; mdi=100*rma(minus,14)/atr
    den=pdi+mdi; dx=np.divide(100*np.abs(pdi-mdi),den,out=np.zeros_like(c),where=np.isfinite(den)&(den!=0)); adx=rma(np.nan_to_num(dx),14)
    rr=h-l; closepos=np.divide(c-l,rr,out=np.full_like(c,.5),where=rr>0)
    e20=ema(c,20); e50=ema(c,50); e200=ema(c,200)
    vol20=pd.Series(v).rolling(20,min_periods=20).mean().to_numpy()
    vwap3=np.r_[np.full(3,np.nan),vwap[:-3]]
    vwap6=np.r_[np.full(6,np.nan),vwap[:-6]]
    e50prev=np.r_[np.nan,e50[:-1]]; e200prev=np.r_[np.nan,e200[:-1]]
    return dict(o=o,h=h,l=l,c=c,v=v,date=date,minute=minute,vwap=vwap,vwap3=vwap3,vwap6=vwap6,rangehi=rangehi,rangelo=rangelo,pc=pc,atr=atr,adx=adx,pdi=pdi,mdi=mdi,closepos=closepos,e20=e20,e50=e50,e200=e200,e50prev=e50prev,e200prev=e200prev,vol20=vol20)

def metrics(p):
    p=np.asarray(p,float)
    if len(p)==0:return dict(trades=0,wins=0,win_rate=0.,pf=0.,net=0.,maxdd=0.,avg=0.)
    gp=p[p>0].sum(); gl=-p[p<0].sum(); pf=gp/gl if gl>0 else 99.
    eq=np.cumsum(p); peak=np.maximum.accumulate(np.r_[0.,eq])[:-1]
    return dict(trades=len(p),wins=int((p>0).sum()),win_rate=float((p>0).mean()*100),pf=float(pf),net=float(p.sum()),maxdd=float((peak-eq).max()),avg=float(p.mean()))

def raw_breaks(A,p):
    c=A['c']; pc=A['pc']; minute=A['minute']; atr=A['atr']
    L=np.zeros(len(c),bool); S=np.zeros(len(c),bool)
    for b in p['ranges']:
        hi=A['rangehi'][b]; lo=A['rangelo'][b]; ready=minute>=570+3*b; buf=p['buffer']*atr
        L |= (c>hi+buf)&(pc<=hi+buf)&ready
        S |= (c<lo-buf)&(pc>=lo-buf)&ready
    return L,S

def signals(A,p):
    c=A['c']; minute=A['minute']; atr=A['atr']; adx=A['adx']; cp=A['closepos']; v=A['v']
    L,S=raw_breaks(A,p)
    # Internet-supported false-breakout confirmation: require a second close beyond the broken range.
    if p['confirm']==1:
        L0,S0=L.copy(),S.copy(); L[:]=False; S[:]=False
        for b in p['ranges']:
            hi=A['rangehi'][b]+p['buffer']*atr; lo=A['rangelo'][b]-p['buffer']*atr
            L |= np.r_[False,L0[:-1]] & (c>hi)
            S |= np.r_[False,S0[:-1]] & (c<lo)
    gate=(minute>=p['start'])&(minute<=p['end'])&(adx>=p['adx'])&np.isfinite(atr)
    L &= gate&(cp>=p['strength']); S &= gate&(cp<=1-p['strength'])
    # DMI direction is a common ADX companion; optional because prior baseline only used ADX strength.
    if p['dmi']:
        L &= A['pdi']>A['mdi']; S &= A['mdi']>A['pdi']
    # EMA directional confirmation from public ORB scripts.
    if p['ema']==50:
        L &= c>A['e50']; S &= c<A['e50']
        if p['ema_slope']:
            L &= A['e50']>A['e50prev']; S &= A['e50']<A['e50prev']
    elif p['ema']==200:
        L &= c>A['e200']; S &= c<A['e200']
        if p['ema_slope']:
            L &= A['e200']>A['e200prev']; S &= A['e200']<A['e200prev']
    # VWAP alignment / slope confirmation.
    if p['vwap_mode']>=1:
        L &= c>A['vwap']; S &= c<A['vwap']
    if p['vwap_mode']==2:
        L &= A['vwap']>A['vwap3']; S &= A['vwap']<A['vwap3']
    elif p['vwap_mode']==3:
        L &= A['vwap']>A['vwap6']; S &= A['vwap']<A['vwap6']
    # Relative-volume breakout confirmation.
    if p['rvol']>0:
        rv=np.divide(v,A['vol20'],out=np.zeros_like(v,dtype=float),where=np.isfinite(A['vol20'])&(A['vol20']>0))
        L &= rv>=p['rvol']; S &= rv>=p['rvol']
    return L,S

def simulate(A,p):
    L,S=signals(A,p); sig=np.flatnonzero(L|S); date=A['date']; minute=A['minute']; o=A['o']; h=A['h']; l=A['l']; c=A['c']; atr=A['atr']
    trades=[]; nextok=-1; k=0; curday=None; dayn=0; n=len(c)
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
                # Conservative same-bar collision: stop first.
                exit_px=(stop-(SLIP if side==1 else -SLIP)) if hs else target; exit_i=j; break
            if date[j]!=dt or minute[j]>=957:
                exit_px=c[j]-(SLIP if side==1 else -SLIP); exit_i=j; break
        trades.append((dt,side*(exit_px-entry)-(entry+exit_px)*FEE,side)); nextok=exit_i+p['cool']; k=int(np.searchsorted(sig,nextok,'left'))
    return trades

def foldm(tr,lo,hi):return metrics([x[1] for x in tr if lo<=x[0]<=hi])

def devscore(ms):
    total=sum(m['trades'] for m in ms); pos=sum(m['net']>0 for m in ms); pfok=sum(m['pf']>=1 for m in ms)
    if total<60 or pos<3 or pfok<3:return -1e9
    # Reward median fold PF and win rate, penalize fold drawdown and extreme instability.
    pfs=[m['pf'] for m in ms]; wrs=[m['win_rate'] for m in ms]
    return 4*np.median(pfs)+np.median(wrs)/20+math.log1p(total)/3-.10*max(m['maxdd'] for m in ms)-0.35*np.std(pfs)

def randp(r):
    # Search stays near two independently strong families from the previous 80k run.
    range_sets=[(1,2),(1,5),(1,2,3),(1,2,3,5)]
    p=dict(
        ranges=r.choice(range_sets), buffer=r.choice([0.,.025,.05,.075,.1]),
        start=r.choice([630,645]), end=r.choice([840,870,900,930]),
        strength=r.choice([.80,.85,.90,.925]), adx=r.choice([10,12,14,16,18]),
        dmi=r.choice([False,False,True]), ema=r.choice([0,50,200]), ema_slope=r.choice([False,True]),
        vwap_mode=r.choice([0,0,1,2,3]), rvol=r.choice([0.,0.,1.1,1.25,1.5]), confirm=r.choice([0,0,1]),
        stop=r.choice([1.1,1.2,1.3]), target=r.choice([1.0,1.1,1.2,1.3,1.4]),
        bars=r.choice([10,15,20,25]), cool=r.choice([2,3,5]), maxday=r.choice([1,2,3,4])
    )
    return p

def main():
    A=load(); dates=sorted(np.unique(A['date'])); hold=(dates[-20],dates[-1]); dev=dates[:-20]
    chunks=np.array_split(np.array(dev,dtype=object),4); folds=[(x[0],x[-1]) for x in chunks]
    print('DATA',dates[0],dates[-1],'DAYS',len(dates),'FOLDS',folds,'HOLD',hold)

    # Fixed baseline from the current downloadable Pine strategy.
    baseline=dict(ranges=(1,2),buffer=0.,start=645,end=930,strength=.90,adx=10,dmi=False,ema=0,ema_slope=False,vwap_mode=0,rvol=0.,confirm=0,stop=1.3,target=1.2,bars=10,cool=3,maxday=4)
    bt=simulate(A,baseline); print('BASE DEV',metrics([x[1] for x in bt if x[0]<hold[0]]),'BASE HOLD',foldm(bt,*hold),'BASE FULL',metrics([x[1] for x in bt]))

    r=random.Random(20261002); surv=[]; N=50000
    for _ in range(N):
        p=randp(r); tr=simulate(A,p); ms=[foldm(tr,*f) for f in folds]; s=devscore(ms)
        if s>-1e8:surv.append((s,p,ms,tr))
    surv.sort(key=lambda x:x[0],reverse=True); print('SURV',len(surv),'OF',N)
    out=[]
    for rank,(s,p,ms,tr) in enumerate(surv[:200],1):
        devm=metrics([x[1] for x in tr if x[0]<hold[0]]); hm=foldm(tr,*hold); fm=metrics([x[1] for x in tr])
        pass_hold=hm['trades']>=10 and hm['win_rate']>=60 and hm['pf']>=1.20 and hm['net']>0
        pass_full=fm['trades']>=75 and fm['win_rate']>=60 and fm['pf']>=1.25 and fm['net']>0
        better=(fm['pf']>1.243 and hm['pf']>1.264 and fm['win_rate']>=65 and hm['win_rate']>=60)
        if rank<=25 or (pass_hold and pass_full and better):
            print('\nR',rank,p,'\nFOLDS',ms,'\nDEV',devm,'\nHOLD',hm,'\nFULL',fm,'PASS',pass_hold,pass_full,'BETTER',better)
        row={'rank':rank,'score':s,**p,**{f'dev_{k}':v for k,v in devm.items()},**{f'hold_{k}':v for k,v in hm.items()},**{f'full_{k}':v for k,v in fm.items()},'pass_hold':pass_hold,'pass_full':pass_full,'better_than_current':better}
        out.append(row)
    df=pd.DataFrame(out); df.to_csv('nvda_internet_filters_results.csv',index=False)
    good=df[(df.pass_hold)&(df.pass_full)&(df.better_than_current)] if len(df) else df
    if len(good):
        # choose best combined PF with a trade-count floor, never by holdout alone
        g=good.copy(); g['robust_pick']=g['dev_pf']+g['full_pf']+0.35*g['hold_pf']+g['full_trades']/500
        winner=g.sort_values('robust_pick',ascending=False).iloc[0]
        pd.DataFrame([winner]).to_csv('nvda_internet_filters_winner.csv',index=False)
        print('\nWINNER',winner.to_dict())
    else:
        print('\nNO CANDIDATE BEAT CURRENT WITH BOTH GATES')

if __name__=='__main__':main()
