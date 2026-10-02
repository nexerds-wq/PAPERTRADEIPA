import io, math, random
import numpy as np
import pandas as pd
import requests

DATA_URL='https://raw.githubusercontent.com/getdata-finance/nvda-3m-ohlcv-stocks-historical-data/main/NVDA_3m.csv'
COMMISSION=0.0005
SLIP=0.01


def rma(s,n):
    a=1.0/n
    x=np.asarray(s,float)
    out=np.full(len(x),np.nan)
    if len(x)<n:return out
    seed=np.nanmean(x[:n]); out[n-1]=seed
    for i in range(n,len(x)):
        out[i]=a*x[i]+(1-a)*out[i-1]
    return out

def rsi(close,n):
    d=np.diff(close,prepend=close[0])
    up=np.maximum(d,0); dn=np.maximum(-d,0)
    au=rma(up,n); ad=rma(dn,n)
    rs=np.divide(au,ad,out=np.full_like(au,np.nan),where=ad!=0)
    return 100-100/(1+rs)

def ema(x,n):
    return pd.Series(x).ewm(span=n,adjust=False).mean().to_numpy()

def load():
    t=requests.get(DATA_URL,timeout=60).text
    d=pd.read_csv(io.StringIO(t))
    d['datetime']=pd.to_datetime(d['datetime'],utc=True)
    d=d.sort_values('datetime').drop_duplicates('datetime').copy()
    d['ny']=d['datetime'].dt.tz_convert('America/New_York')
    mins=d['ny'].dt.hour*60+d['ny'].dt.minute
    d=d[(mins>=570)&(mins<960)].copy().reset_index(drop=True)
    d['date']=d['ny'].dt.date
    d['minute']=d['ny'].dt.hour*60+d['ny'].dt.minute
    o=d.open.to_numpy(float); h=d.high.to_numpy(float); l=d.low.to_numpy(float); c=d.close.to_numpy(float); v=d.volume.to_numpy(float)
    date=d.date.to_numpy(); minute=d.minute.to_numpy(int)
    tp=(h+l+c)/3
    pv=pd.Series(tp*v).groupby(d.date).cumsum().to_numpy()
    vc=pd.Series(v).groupby(d.date).cumsum().to_numpy()
    vwap=pv/vc
    emas={n:ema(c,n) for n in [9,20,50,200]}
    pc=np.r_[np.nan,c[:-1]]
    tr=np.nanmax(np.vstack([h-l,np.abs(h-pc),np.abs(l-pc)]),axis=0)
    tr[0]=h[0]-l[0]
    atr=rma(tr,14)
    rsis={n:rsi(c,n) for n in [2,3,5,7,14]}
    up=np.diff(h,prepend=h[0]); dn=-np.diff(l,prepend=l[0])
    plus=np.where((up>dn)&(up>0),up,0.0); minus=np.where((dn>up)&(dn>0),dn,0.0)
    pdi=100*rma(plus,14)/atr; mdi=100*rma(minus,14)/atr
    den=pdi+mdi
    dx=np.divide(100*np.abs(pdi-mdi),den,out=np.zeros_like(den),where=np.isfinite(den)&(den!=0))
    adx=rma(np.nan_to_num(dx,nan=0),14)
    bull=c>o; bear=c<o
    prev_high=np.r_[np.nan,h[:-1]]; prev_low=np.r_[np.nan,l[:-1]]; prev_close=np.r_[np.nan,c[:-1]]
    rr=h-l; close_pos=np.divide(c-l,rr,out=np.full_like(c,np.nan),where=rr!=0)
    day_first_hi=np.empty(len(c)); day_first_lo=np.empty(len(c))
    for dt,idx in d.groupby('date').groups.items():
        idx=np.asarray(list(idx)); day_first_hi[idx]=h[idx[0]]; day_first_lo[idx]=l[idx[0]]
    return dict(df=d,o=o,h=h,l=l,c=c,v=v,date=date,minute=minute,vwap=vwap,atr=atr,adx=adx,bull=bull,bear=bear,prev_high=prev_high,prev_low=prev_low,prev_close=prev_close,close_pos=close_pos,first_hi=day_first_hi,first_lo=day_first_lo,emas=emas,rsis=rsis)

def metrics(pnls):
    p=np.asarray(pnls,float)
    if len(p)==0:return dict(trades=0,wins=0,win_rate=0.0,pf=0.0,net=0.0,maxdd=0.0,avg=0.0)
    gp=p[p>0].sum(); gl=-p[p<0].sum(); pf=gp/gl if gl>0 else 99.0
    eq=np.cumsum(p); peak=np.maximum.accumulate(np.r_[0.0,eq])[:-1]; dd=peak-eq
    return dict(trades=int(len(p)),wins=int((p>0).sum()),win_rate=float((p>0).mean()*100),pf=float(pf),net=float(p.sum()),maxdd=float(dd.max() if len(dd) else 0),avg=float(p.mean()))

def signal_arrays(A,p):
    c=A['c']; h=A['h']; l=A['l']; vwap=A['vwap']; atr=A['atr']; adx=A['adx']; minute=A['minute']
    bull=A['bull']; bear=A['bear']; ph=A['prev_high']; pl=A['prev_low']; pc=A['prev_close']; cp=A['close_pos']
    rs=A['rsis'][p['rsi_len']]
    sess=(minute>=p['start'])&(minute<=p['end'])&np.isfinite(atr)
    fam=p['family']
    if fam=='meanrev':
        lower=vwap-p['dev']*atr; upper=vwap+p['dev']*atr
        L=(l<lower)&(c>lower)&bull&(rs<=p['os'])
        S=(h>upper)&(c<upper)&bear&(rs>=p['ob'])
        if p['reversal']==1:
            L &= c>pc; S &= c<pc
        if p['regime']=='range':
            L &= adx<=p['adx']; S &= adx<=p['adx']
        elif p['regime']=='trend':
            L &= A['emas'][50]>A['emas'][200]; S &= A['emas'][50]<A['emas'][200]
    elif fam=='trendpull':
        e20=A['emas'][20]; e50=A['emas'][50]; e200=A['emas'][200]
        lt=(e20>e50)&(e50>e200)&(c>vwap)&(adx>=p['adx'])
        st=(e20<e50)&(e50<e200)&(c<vwap)&(adx>=p['adx'])
        L=lt&(l<=e20+p['touch']*atr)&(c>e20)&(rs>=p['rlo'])&(rs<=p['rhi'])&bull&(c>ph)
        S=st&(h>=e20-p['touch']*atr)&(c<e20)&(rs>=(100-p['rhi']))&(rs<=(100-p['rlo']))&bear&(c<pl)
    elif fam=='vwaprsi':
        em=A['emas'][p['ema']]; prs=np.r_[np.nan,rs[:-1]]
        L=(c>vwap)&(c>em)&(prs<=p['os'])&(rs>p['os'])&bull
        S=(c<vwap)&(c<em)&(prs>=p['ob'])&(rs<p['ob'])&bear
        if p['adx']>0:
            L &= adx>=p['adx']; S &= adx>=p['adx']
    else:
        oh=A['first_hi']; ol=A['first_lo']
        L=(c>oh)&(pc<=oh)&(c>vwap)&(cp>=p['strength'])
        S=(c<ol)&(pc>=ol)&(c<vwap)&(cp<=(1-p['strength']))
        if p['adx']>0:
            L &= adx>=p['adx']; S &= adx>=p['adx']
        L &= minute>570; S &= minute>570
    L &= sess; S &= sess
    if not p['shorts']:
        S=np.zeros_like(S,dtype=bool)
    return L,S

def bt(A,p,start_date,end_date):
    L,S=signal_arrays(A,p)
    date=A['date']; o=A['o']; h=A['h']; l=A['l']; c=A['c']; atr=A['atr']; minute=A['minute']
    mask=(date>=start_date)&(date<=end_date)
    sig=np.flatnonzero(mask&(L|S))
    if len(sig)==0:return []
    pnls=[]; next_allowed=-1; k=0
    n=len(c)
    while k<len(sig):
        i=int(sig[k])
        if i<next_allowed or i+1>=n or date[i+1]>end_date:
            k+=1; continue
        side=1 if L[i] else -1
        ei=i+1
        entry=o[ei]+(SLIP if side==1 else -SLIP)
        a=atr[i]
        if not np.isfinite(a) or a<=0:
            k+=1; continue
        stop=entry-side*p['stop']*a
        target=entry+side*p['target']*a
        max_exit=min(ei+p['maxbars'],n-1)
        exit_i=None; exit_px=None
        for j in range(ei,max_exit+1):
            hs=(l[j]<=stop) if side==1 else (h[j]>=stop)
            ht=(h[j]>=target) if side==1 else (l[j]<=target)
            if hs or ht:
                if hs:
                    exit_px=stop-(SLIP if side==1 else -SLIP)
                else:
                    exit_px=target
                exit_i=j; break
            if minute[j]>=957 or date[j]!=date[ei] or j==max_exit:
                exit_px=c[j]-(SLIP if side==1 else -SLIP)
                exit_i=j; break
        if exit_i is None:
            exit_i=max_exit; exit_px=c[exit_i]-(SLIP if side==1 else -SLIP)
        gross=side*(exit_px-entry); cost=(entry+exit_px)*COMMISSION
        pnls.append(gross-cost)
        next_allowed=exit_i+p['cool']
        k=int(np.searchsorted(sig,next_allowed,side='left'))
    return pnls

def random_params(rng):
    fam=rng.choice(['meanrev','trendpull','vwaprsi','orb'])
    base=dict(family=fam, stop=rng.choice([0.45,0.55,0.7,0.85,1.0,1.2,1.4]), target=rng.choice([0.55,0.7,0.85,1.0,1.2,1.5,1.8]), maxbars=rng.choice([4,6,8,10,15,20,30]), cool=rng.choice([1,2,3,5]), shorts=rng.choice([True,False]), start=rng.choice([573,579,585,600,630]), end=rng.choice([690,750,840,900,930]), rsi_len=rng.choice([2,3,5,7,14]), adx=rng.choice([0,12,15,18,20,25,30]))
    if base['end']<=base['start']: base['end']=930
    if fam=='meanrev':
        base.update(dev=rng.choice([0.35,0.5,0.65,0.8,1.0,1.2,1.5,1.8]),os=rng.choice([10,15,20,25,30,35,40]),ob=rng.choice([60,65,70,75,80,85,90]),reversal=rng.choice([0,1]),regime=rng.choice(['none','range','trend']))
    elif fam=='trendpull':
        base.update(touch=rng.choice([0.0,0.05,0.15,0.3,0.5,0.8]),rlo=rng.choice([25,30,35,40,45]),rhi=rng.choice([50,55,60,65,70]))
    elif fam=='vwaprsi':
        base.update(os=rng.choice([10,15,20,25,30,35,40,45]),ob=rng.choice([55,60,65,70,75,80,85,90]),ema=rng.choice([9,20,50]))
    else:
        base.update(strength=rng.choice([0.5,0.55,0.65,0.75,0.85,0.9]))
    return base

def score(m):
    if m['trades']<25 or m['net']<=0:return -1e9
    return (m['pf']-1)*3.0+(m['win_rate']-50)/18.0+math.log1p(m['trades'])/4.0-m['maxdd']/8.0

def main():
    A=load(); dates=sorted(np.unique(A['date'])); n=len(dates)
    train=(dates[0],dates[int(n*.50)-1]); val=(dates[int(n*.50)],dates[int(n*.75)-1]); test=(dates[int(n*.75)],dates[-1]); full=(dates[0],dates[-1])
    print('period',full,'days',n,'rows',len(A['c']))
    print('splits train',train,'val',val,'test',test)
    rng=random.Random(20261002)
    rows=[]
    N=8000
    for k in range(N):
        p=random_params(rng); mt=metrics(bt(A,p,*train)); s=score(mt)
        if s>-1e8: rows.append((s,p,mt))
    rows.sort(key=lambda x:x[0],reverse=True)
    print('train survivors',len(rows),'of',N)
    top=rows[:300]
    vals=[]
    for s,p,mt in top:
        mv=metrics(bt(A,p,*val))
        if mv['trades']>=10 and mv['net']>0 and mv['pf']>=1.0:
            robust=min(mt['pf'],mv['pf'])+min(mt['win_rate'],mv['win_rate'])/100+math.log1p(mt['trades']+mv['trades'])/20
            vals.append((robust,p,mt,mv))
    vals.sort(key=lambda x:x[0],reverse=True)
    print('validation survivors',len(vals))
    out=[]
    for rank,(rob,p,mt,mv) in enumerate(vals[:30],1):
        mtest=metrics(bt(A,p,*test)); mf=metrics(bt(A,p,*full))
        pass_test=mtest['trades']>=12 and mtest['win_rate']>=50 and mtest['pf']>=1.2 and mtest['net']>0
        pass_full=mf['trades']>=100 and mf['win_rate']>=50 and mf['pf']>=1.2 and mf['net']>0
        print('\nRANK',rank,'PARAMS',p)
        print('TRAIN',mt); print('VAL',mv); print('TEST',mtest); print('FULL',mf); print('PASS_TEST',pass_test,'PASS_FULL',pass_full)
        row={'rank':rank,'robust':rob,**p}
        for tag,m in [('train',mt),('val',mv),('test',mtest),('full',mf)]:
            for kk,vv in m.items(): row[f'{tag}_{kk}']=vv
        row['pass_test']=pass_test; row['pass_full']=pass_full
        out.append(row)
    pd.DataFrame(out).to_csv('nvda_strategy_search_results.csv',index=False)
    good=[r for r in out if r['pass_test'] and r['pass_full']]
    if good:
        pd.DataFrame([good[0]]).to_csv('nvda_search_best_params.csv',index=False)
        print('\nWINNER',good[0])
    elif out:
        pd.DataFrame([out[0]]).to_csv('nvda_search_best_params.csv',index=False)
        print('\nNO FULL PASS. BEST ROBUST CANDIDATE',out[0])

if __name__=='__main__': main()
