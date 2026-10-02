import io, math, random
from dataclasses import dataclass
import numpy as np
import pandas as pd
import requests

DATA_URL='https://raw.githubusercontent.com/getdata-finance/nvda-3m-ohlcv-stocks-historical-data/main/NVDA_3m.csv'
COMMISSION=0.0005
SLIP=0.01


def rma(s,n):
    a=1/n
    out=np.full(len(s),np.nan)
    x=np.asarray(s,float)
    if len(x)<n:return pd.Series(out,index=s.index)
    seed=np.nanmean(x[:n]); out[n-1]=seed
    for i in range(n,len(x)):
        out[i]=a*x[i]+(1-a)*out[i-1]
    return pd.Series(out,index=s.index)

def rsi(s,n):
    d=s.diff(); up=d.clip(lower=0); dn=(-d).clip(lower=0)
    au=rma(up.fillna(0),n); ad=rma(dn.fillna(0),n)
    rs=au/ad.replace(0,np.nan)
    return 100-100/(1+rs)

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
    tp=(d.high+d.low+d.close)/3
    d['vwap']=(tp*d.volume).groupby(d.date).cumsum()/d.volume.groupby(d.date).cumsum()
    for n in [9,20,50,200]: d[f'ema{n}']=d.close.ewm(span=n,adjust=False).mean()
    pc=d.close.shift(1)
    tr=pd.concat([d.high-d.low,(d.high-pc).abs(),(d.low-pc).abs()],axis=1).max(axis=1)
    d['atr']=rma(tr,14)
    for n in [2,3,5,7,14]: d[f'rsi{n}']=rsi(d.close,n)
    up=d.high.diff(); dn=-d.low.diff()
    plus=np.where((up>dn)&(up>0),up,0.0); minus=np.where((dn>up)&(dn>0),dn,0.0)
    atr=d.atr
    pdi=100*rma(pd.Series(plus,index=d.index),14)/atr
    mdi=100*rma(pd.Series(minus,index=d.index),14)/atr
    dx=(100*(pdi-mdi).abs()/(pdi+mdi).replace(0,np.nan))
    d['adx']=rma(dx.fillna(0),14)
    d['bull']=d.close>d.open; d['bear']=d.close<d.open
    d['prev_high']=d.high.shift(1); d['prev_low']=d.low.shift(1); d['prev_close']=d.close.shift(1)
    d['range']=d.high-d.low
    d['close_pos']=(d.close-d.low)/d['range'].replace(0,np.nan)
    return d

def metrics(trades):
    if not trades:return dict(trades=0,wins=0,win_rate=0,pf=0,net=0,maxdd=0,avg=0)
    p=np.array([x['pnl'] for x in trades],float)
    gp=p[p>0].sum(); gl=-p[p<0].sum(); pf=gp/gl if gl>0 else 99
    eq=np.cumsum(p); peak=np.maximum.accumulate(np.r_[0,eq])[:-1]; dd=peak-eq
    return dict(trades=len(p),wins=int((p>0).sum()),win_rate=float((p>0).mean()*100),pf=float(pf),net=float(p.sum()),maxdd=float(dd.max() if len(dd) else 0),avg=float(p.mean()))

def bt(d,p,start_date,end_date):
    # one position at a time, next-bar-open entries, conservative same-bar stop/target
    mask=(d.date>=start_date)&(d.date<=end_date)
    ids=np.flatnonzero(mask.to_numpy())
    if len(ids)==0:return []
    first,last=ids[0],ids[-1]
    pos=None; pending=None; trades=[]; bars=0; last_exit=-9999
    for i in range(first,last+1):
        r=d.iloc[i]
        # execute pending next bar
        if pos is None and pending is not None:
            side=pending['side']; entry=float(r.open)+(SLIP if side==1 else -SLIP)
            atr=float(pending['atr'])
            pos=dict(side=side,entry=entry,atr=atr,entry_i=i,entry_time=r.ny)
            pending=None
        # manage
        if pos is not None:
            side=pos['side']; e=pos['entry']; a=pos['atr']
            st=e-side*p['stop']*a; tg=e+side*p['target']*a
            h=float(r.high); l=float(r.low); o=float(r.open)
            hit_st=(l<=st) if side==1 else (h>=st)
            hit_tg=(h>=tg) if side==1 else (l<=tg)
            exit_px=None; reason=None
            if hit_st or hit_tg:
                if hit_st and hit_tg: which='st'
                else: which='st' if hit_st else 'tg'
                if which=='st':
                    exit_px=st-(SLIP if side==1 else -SLIP); reason='stop'
                else:
                    exit_px=tg; reason='target'
            elif i-pos['entry_i']>=p['maxbars'] or int(r.minute)>=957:
                exit_px=float(r.close)-(SLIP if side==1 else -SLIP); reason='time'
            if exit_px is not None:
                gross=side*(exit_px-e)
                cost=(e+exit_px)*COMMISSION
                trades.append(dict(pnl=gross-cost,side=side,reason=reason))
                pos=None; last_exit=i
        if pos is not None or pending is not None: continue
        if i-last_exit<p['cool']: continue
        if not (p['start']<=int(r.minute)<=p['end']): continue
        if not np.isfinite(r.atr) or r.atr<=0: continue
        side=0
        fam=p['family']
        rs=float(r[f"rsi{p['rsi_len']}"])
        if fam=='meanrev':
            lower=r.vwap-p['dev']*r.atr; upper=r.vwap+p['dev']*r.atr
            long_sig=(r.low<lower and r.close>lower and r.bull and rs<=p['os'])
            short_sig=(r.high>upper and r.close<upper and r.bear and rs>=p['ob'])
            if p['reversal']==1:
                long_sig=long_sig and r.close>r.prev_close
                short_sig=short_sig and r.close<r.prev_close
            if p['regime']=='range':
                long_sig=long_sig and r.adx<=p['adx']
                short_sig=short_sig and r.adx<=p['adx']
            elif p['regime']=='trend':
                long_sig=long_sig and r.ema50>r.ema200
                short_sig=short_sig and r.ema50<r.ema200
            if long_sig: side=1
            elif short_sig and p['shorts']: side=-1
        elif fam=='trendpull':
            lt=(r.ema20>r.ema50>r.ema200 and r.close>r.vwap and r.adx>=p['adx'])
            st=(r.ema20<r.ema50<r.ema200 and r.close<r.vwap and r.adx>=p['adx'])
            long_sig=lt and r.low<=r.ema20+p['touch']*r.atr and r.close>r.ema20 and p['rlo']<=rs<=p['rhi'] and r.bull and r.close>r.prev_high
            short_sig=st and r.high>=r.ema20-p['touch']*r.atr and r.close<r.ema20 and (100-p['rhi'])<=rs<=(100-p['rlo']) and r.bear and r.close<r.prev_low
            if long_sig: side=1
            elif short_sig and p['shorts']: side=-1
        elif fam=='vwaprsi':
            ema=r[f"ema{p['ema']}"]
            prev=d.iloc[i-1] if i>0 else r
            prs=float(prev[f"rsi{p['rsi_len']}"])
            long_sig=r.close>r.vwap and r.close>ema and prs<=p['os'] and rs>p['os'] and r.bull
            short_sig=r.close<r.vwap and r.close<ema and prs>=p['ob'] and rs<p['ob'] and r.bear
            if p['adx']>0:
                long_sig=long_sig and r.adx>=p['adx']; short_sig=short_sig and r.adx>=p['adx']
            if long_sig: side=1
            elif short_sig and p['shorts']: side=-1
        elif fam=='orb':
            day=d[d.date==r.date]
            firstbar=day[day.minute==570]
            if len(firstbar):
                oh=float(firstbar.iloc[0].high); ol=float(firstbar.iloc[0].low)
                long_sig=r.close>oh and r.prev_close<=oh and r.close>r.vwap and r.close_pos>=p['strength']
                short_sig=r.close<ol and r.prev_close>=ol and r.close<r.vwap and r.close_pos<=(1-p['strength'])
                if p['adx']>0:
                    long_sig=long_sig and r.adx>=p['adx']; short_sig=short_sig and r.adx>=p['adx']
                if long_sig: side=1
                elif short_sig and p['shorts']: side=-1
        if side!=0:
            pending=dict(side=side,atr=float(r.atr))
    return trades

def random_params(rng):
    fam=rng.choice(['meanrev','trendpull','vwaprsi','orb'])
    base=dict(family=fam, stop=rng.choice([0.55,0.7,0.85,1.0,1.2]), target=rng.choice([0.65,0.8,1.0,1.2,1.5]), maxbars=rng.choice([6,10,15,20,30]), cool=rng.choice([1,2,3,5]), shorts=rng.choice([True,False]), start=rng.choice([573,579,585,600]), end=rng.choice([690,750,840,930]), rsi_len=rng.choice([2,3,5,7,14]), adx=rng.choice([0,15,18,20,25,30]))
    if base['end']<=base['start']: base['end']=930
    if fam=='meanrev': base.update(dev=rng.choice([0.5,0.7,0.9,1.1,1.3,1.6]),os=rng.choice([15,20,25,30,35]),ob=rng.choice([65,70,75,80,85]),reversal=rng.choice([0,1]),regime=rng.choice(['none','range','trend']))
    elif fam=='trendpull': base.update(touch=rng.choice([0.05,0.15,0.3,0.5]),rlo=rng.choice([30,35,40,45]),rhi=rng.choice([50,55,60,65]))
    elif fam=='vwaprsi': base.update(os=rng.choice([10,15,20,25,30,35,40]),ob=rng.choice([60,65,70,75,80,85,90]),ema=rng.choice([9,20,50]))
    else: base.update(strength=rng.choice([0.55,0.65,0.75,0.85]))
    return base

def score(m):
    if m['trades']<25 or m['net']<=0:return -1e9
    return (m['pf']-1)*3 + (m['win_rate']-50)/20 + math.log1p(m['trades'])/4 - m['maxdd']/10

def main():
    d=load(); dates=sorted(d.date.unique()); n=len(dates)
    train=(dates[0],dates[int(n*.50)-1]); val=(dates[int(n*.50)],dates[int(n*.75)-1]); test=(dates[int(n*.75)],dates[-1]); full=(dates[0],dates[-1])
    print('period',full,'days',n,'rows',len(d)); print('splits train',train,'val',val,'test',test)
    rng=random.Random(20261002)
    rows=[]
    for k in range(1800):
        p=random_params(rng); m=metrics(bt(d,p,*train)); s=score(m)
        if s>-1e8: rows.append((s,p,m))
    rows.sort(key=lambda x:x[0],reverse=True)
    top=rows[:120]
    print('train survivors',len(rows),'evaluating',len(top))
    vals=[]
    for s,p,mt in top:
        mv=metrics(bt(d,p,*val))
        if mv['trades']>=10 and mv['net']>0:
            robust=min(mt['pf'],mv['pf']) + min(mt['win_rate'],mv['win_rate'])/100 + math.log1p(mt['trades']+mv['trades'])/20
            vals.append((robust,p,mt,mv))
    vals.sort(key=lambda x:x[0],reverse=True)
    print('validation survivors',len(vals))
    for rank,(rob,p,mt,mv) in enumerate(vals[:15],1):
        mf=metrics(bt(d,p,*full)); mtest=metrics(bt(d,p,*test))
        print('\nRANK',rank,'PARAMS',p)
        print('TRAIN',mt); print('VAL',mv); print('TEST',mtest); print('FULL',mf)
        pass_test=mtest['trades']>=12 and mtest['win_rate']>=50 and mtest['pf']>=1.2 and mtest['net']>0
        pass_full=mf['trades']>=100 and mf['win_rate']>=50 and mf['pf']>=1.2 and mf['net']>0
        print('PASS_TEST',pass_test,'PASS_FULL',pass_full)
    if vals:
        best=vals[0][1]
        pd.DataFrame([best]).to_csv('nvda_search_best_params.csv',index=False)

if __name__=='__main__': main()
