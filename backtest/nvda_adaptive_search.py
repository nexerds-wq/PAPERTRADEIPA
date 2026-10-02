import io, math, random
import numpy as np
import pandas as pd
import requests

DATA_URL='https://raw.githubusercontent.com/getdata-finance/nvda-3m-ohlcv-stocks-historical-data/main/NVDA_3m.csv'
COMMISSION=0.0005
SLIP=0.01


def rma(x,n):
    x=np.asarray(x,float); out=np.full(len(x),np.nan); a=1.0/n
    if len(x)<n:return out
    out[n-1]=np.nanmean(x[:n])
    for i in range(n,len(x)): out[i]=a*x[i]+(1-a)*out[i-1]
    return out

def ema(x,n): return pd.Series(x).ewm(span=n,adjust=False).mean().to_numpy()
def rsi(c,n):
    d=np.diff(c,prepend=c[0]); up=np.maximum(d,0); dn=np.maximum(-d,0)
    au=rma(up,n); ad=rma(dn,n); rs=np.divide(au,ad,out=np.full_like(au,np.nan),where=ad!=0)
    return 100-100/(1+rs)

def rolling_er(c,n):
    ch=np.abs(c-np.roll(c,n)); ch[:n]=np.nan
    dif=np.abs(np.diff(c,prepend=c[0])); den=pd.Series(dif).rolling(n,min_periods=n).sum().to_numpy()
    return np.divide(ch,den,out=np.full_like(c,np.nan),where=den!=0)

def load():
    txt=requests.get(DATA_URL,timeout=60).text
    d=pd.read_csv(io.StringIO(txt)); d['datetime']=pd.to_datetime(d.datetime,utc=True)
    d=d.sort_values('datetime').drop_duplicates('datetime').copy(); d['ny']=d.datetime.dt.tz_convert('America/New_York')
    minute=d.ny.dt.hour*60+d.ny.dt.minute; d=d[(minute>=570)&(minute<960)].copy().reset_index(drop=True)
    d['date']=d.ny.dt.date; d['minute']=d.ny.dt.hour*60+d.ny.dt.minute
    o=d.open.to_numpy(float); h=d.high.to_numpy(float); l=d.low.to_numpy(float); c=d.close.to_numpy(float); v=d.volume.to_numpy(float)
    date=d.date.to_numpy(); minute=d.minute.to_numpy(int); tp=(h+l+c)/3
    vwap=np.empty(len(c)); vwstd=np.empty(len(c))
    for _,idx0 in d.groupby('date').groups.items():
        idx=np.asarray(list(idx0)); vv=v[idx]; xx=tp[idx]
        sw=np.cumsum(vv); sx=np.cumsum(vv*xx); sx2=np.cumsum(vv*xx*xx)
        mu=sx/sw; var=np.maximum(sx2/sw-mu*mu,0)
        vwap[idx]=mu; vwstd[idx]=np.sqrt(var)
    e9=ema(c,9); e20=ema(c,20); e50=ema(c,50); e200=ema(c,200)
    pc=np.r_[np.nan,c[:-1]]; ph=np.r_[np.nan,h[:-1]]; pl=np.r_[np.nan,l[:-1]]
    tr=np.nanmax(np.vstack([h-l,np.abs(h-pc),np.abs(l-pc)]),axis=0); tr[0]=h[0]-l[0]; atr=rma(tr,14)
    up=np.diff(h,prepend=h[0]); dn=-np.diff(l,prepend=l[0]); plus=np.where((up>dn)&(up>0),up,0.0); minus=np.where((dn>up)&(dn>0),dn,0.0)
    pdi=100*rma(plus,14)/atr; mdi=100*rma(minus,14)/atr; den=pdi+mdi
    dx=np.divide(100*np.abs(pdi-mdi),den,out=np.zeros_like(c),where=np.isfinite(den)&(den!=0)); adx=rma(np.nan_to_num(dx),14)
    rsis={n:rsi(c,n) for n in [2,3,5,7,14]}; ers={n:rolling_er(c,n) for n in [8,12,20,30]}
    bull=c>o; bear=c<o
    return dict(d=d,o=o,h=h,l=l,c=c,v=v,date=date,minute=minute,vwap=vwap,vwstd=vwstd,atr=atr,adx=adx,pdi=pdi,mdi=mdi,e9=e9,e20=e20,e50=e50,e200=e200,pc=pc,ph=ph,pl=pl,rsis=rsis,ers=ers,bull=bull,bear=bear)

def metrics(pnls):
    p=np.asarray(pnls,float)
    if len(p)==0:return dict(trades=0,wins=0,win_rate=0.0,pf=0.0,net=0.0,maxdd=0.0,avg=0.0)
    gp=p[p>0].sum(); gl=-p[p<0].sum(); pf=gp/gl if gl>0 else 99.0
    eq=np.cumsum(p); peak=np.maximum.accumulate(np.r_[0.0,eq])[:-1]; dd=peak-eq
    return dict(trades=len(p),wins=int((p>0).sum()),win_rate=float((p>0).mean()*100),pf=float(pf),net=float(p.sum()),maxdd=float(dd.max() if len(dd) else 0),avg=float(p.mean()))

def signals(A,p):
    c=A['c']; h=A['h']; l=A['l']; vwap=A['vwap']; sd=A['vwstd']; atr=A['atr']; adx=A['adx']; minute=A['minute']; rs=A['rsis'][p['rsi_len']]; er=A['ers'][p['er_len']]
    e9=A['e9']; e20=A['e20']; e50=A['e50']; e200=A['e200']; pc=A['pc']; ph=A['ph']; pl=A['pl']; bull=A['bull']; bear=A['bear']; pdi=A['pdi']; mdi=A['mdi']
    sess=(minute>=p['start'])&(minute<=p['end'])&np.isfinite(atr)&np.isfinite(er)&np.isfinite(sd)
    trend= (adx>=p['trend_adx']) & (er>=p['trend_er'])
    Ltrend=trend&(c>vwap)&(e9>e20)&(e20>e50)&(pdi>mdi)&(l<=e20+p['touch']*atr)&(c>e20)&bull&(c>ph)&(rs>=p['trend_rlo'])&(rs<=p['trend_rhi'])
    Strend=trend&(c<vwap)&(e9<e20)&(e20<e50)&(mdi>pdi)&(h>=e20-p['touch']*atr)&(c<e20)&bear&(c<pl)&(rs<=(100-p['trend_rlo']))&(rs>=(100-p['trend_rhi']))
    if p['major_ema']:
        Ltrend &= c>e200; Strend &= c<e200
    ranging=(adx<=p['range_adx'])&(er<=p['range_er'])
    lower=vwap-p['band']*sd; upper=vwap+p['band']*sd
    Lrange=ranging&(l<lower)&(c>lower)&bull&(rs<=p['os'])
    Srange=ranging&(h>upper)&(c<upper)&bear&(rs>=p['ob'])
    if p['reclaim']:
        Lrange &= c>pc; Srange &= c<pc
    if p['mode']=='trend': L=Ltrend; S=Strend
    elif p['mode']=='range': L=Lrange; S=Srange
    else: L=Ltrend|Lrange; S=Strend|Srange
    L &= sess; S &= sess
    if p['side']=='long': S=np.zeros_like(S,bool)
    elif p['side']=='short': L=np.zeros_like(L,bool)
    return L,S,Ltrend,Strend,Lrange,Srange

def simulate(A,p):
    L,S,Lt,St,Lr,Sr=signals(A,p); date=A['date']; o=A['o']; h=A['h']; l=A['l']; c=A['c']; atr=A['atr']; minute=A['minute']
    sig=np.flatnonzero(L|S); trades=[]; next_allowed=-1; k=0; n=len(c)
    while k<len(sig):
        i=int(sig[k]);
        if i<next_allowed or i+1>=n or date[i+1]!=date[i]: k+=1; continue
        side=1 if L[i] else -1; engine='trend' if (Lt[i] or St[i]) else 'range'; ei=i+1
        entry=o[ei]+(SLIP if side==1 else -SLIP); a=atr[i]
        if not np.isfinite(a) or a<=0: k+=1; continue
        if engine=='trend': stopm=p['trend_stop']; targm=p['trend_target']; maxbars=p['trend_bars']
        else: stopm=p['range_stop']; targm=p['range_target']; maxbars=p['range_bars']
        stop=entry-side*stopm*a; target=entry+side*targm*a; max_exit=min(ei+maxbars,n-1)
        exit_i=max_exit; exit_px=c[max_exit]-(SLIP if side==1 else -SLIP)
        for j in range(ei,max_exit+1):
            hs=(l[j]<=stop) if side==1 else (h[j]>=stop); ht=(h[j]>=target) if side==1 else (l[j]<=target)
            if hs or ht:
                if hs: exit_px=stop-(SLIP if side==1 else -SLIP)
                else: exit_px=target
                exit_i=j; break
            if minute[j]>=957 or date[j]!=date[ei]:
                exit_px=c[j]-(SLIP if side==1 else -SLIP); exit_i=j; break
        pnl=side*(exit_px-entry)-(entry+exit_px)*COMMISSION
        trades.append((date[ei],pnl,engine,side))
        next_allowed=exit_i+p['cool']; k=int(np.searchsorted(sig,next_allowed,'left'))
    return trades

def randp(r):
    p=dict(mode=r.choice(['both','both','trend','range']), side=r.choice(['both','both','long']), start=r.choice([579,585,600,630]), end=r.choice([750,840,900,930]), cool=r.choice([1,2,3,5]), er_len=r.choice([8,12,20,30]), trend_adx=r.choice([18,20,22,25,28,30]), trend_er=r.choice([0.20,0.25,0.30,0.35,0.40,0.50]), range_adx=r.choice([12,15,18,20,22,25]), range_er=r.choice([0.10,0.15,0.20,0.25,0.30,0.35]), rsi_len=r.choice([2,3,5,7,14]), touch=r.choice([0.0,0.05,0.15,0.30,0.50]), trend_rlo=r.choice([30,35,40,45]), trend_rhi=r.choice([55,60,65,70]), major_ema=r.choice([True,False]), band=r.choice([0.8,1.0,1.2,1.5,1.8,2.0,2.3]), os=r.choice([10,15,20,25,30,35]), ob=r.choice([65,70,75,80,85,90]), reclaim=r.choice([True,False]), trend_stop=r.choice([0.55,0.7,0.85,1.0,1.2,1.4]), trend_target=r.choice([0.7,0.85,1.0,1.2,1.5,1.8]), trend_bars=r.choice([6,8,10,15,20]), range_stop=r.choice([0.7,0.85,1.0,1.2,1.4,1.6]), range_target=r.choice([0.45,0.55,0.7,0.85,1.0,1.2]), range_bars=r.choice([4,6,8,10,15]))
    if p['end']<=p['start']: p['end']=930
    if p['range_adx']>=p['trend_adx']: p['range_adx']=max(10,p['trend_adx']-3)
    if p['range_er']>=p['trend_er']: p['range_er']=max(0.05,p['trend_er']-0.10)
    if p['trend_rhi']<=p['trend_rlo']: p['trend_rhi']=p['trend_rlo']+15
    return p

def fold_metrics(trades,lo,hi): return metrics([x[1] for x in trades if lo<=x[0]<=hi])
def composite(folds):
    if sum(m['trades'] for m in folds)<60:return -1e9
    positives=sum(m['net']>0 for m in folds); pfok=sum(m['pf']>=1.0 for m in folds); wrok=sum(m['win_rate']>=50 for m in folds)
    if positives<3 or pfok<3:return -1e9
    medpf=float(np.median([m['pf'] for m in folds])); medwr=float(np.median([m['win_rate'] for m in folds])); worstnet=min(m['net'] for m in folds); totaltr=sum(m['trades'] for m in folds)
    return medpf*2.5+medwr/40+math.log1p(totaltr)/3+0.15*worstnet+0.1*wrok

def main():
    A=load(); dates=sorted(np.unique(A['date'])); n=len(dates)
    dev_dates=dates[:-20]; hold=(dates[-20],dates[-1]); chunks=np.array_split(np.array(dev_dates,dtype=object),4)
    folds=[(x[0],x[-1]) for x in chunks]
    print('DATA',dates[0],dates[-1],'days',n,'rows',len(A['c'])); print('DEV FOLDS',folds,'HOLDOUT',hold)
    rng=random.Random(20261002); survivors=[]; N=25000
    for k in range(N):
        p=randp(rng); tr=simulate(A,p); fm=[fold_metrics(tr,*f) for f in folds]; s=composite(fm)
        if s>-1e8: survivors.append((s,p,fm,tr))
    survivors.sort(key=lambda x:x[0],reverse=True)
    print('SURVIVORS',len(survivors),'of',N)
    out=[]
    for rank,(s,p,fm,tr) in enumerate(survivors[:50],1):
        holdm=fold_metrics(tr,*hold); fullm=metrics([x[1] for x in tr]); devm=metrics([x[1] for x in tr if x[0]<hold[0]])
        engine_counts={'trend':sum(x[2]=='trend' for x in tr),'range':sum(x[2]=='range' for x in tr)}
        pass_hold=holdm['trades']>=12 and holdm['win_rate']>=50 and holdm['pf']>=1.2 and holdm['net']>0
        pass_full=fullm['trades']>=100 and fullm['win_rate']>=50 and fullm['pf']>=1.2 and fullm['net']>0
        print('\nRANK',rank,'SCORE',s,'PARAMS',p); print('FOLDS',fm); print('DEV',devm); print('HOLD',holdm); print('FULL',fullm,'ENGINES',engine_counts,'PASS',pass_hold,pass_full)
        row={'rank':rank,'score':s,**p,**{f'hold_{k}':v for k,v in holdm.items()},**{f'full_{k}':v for k,v in fullm.items()},**{f'dev_{k}':v for k,v in devm.items()},'trend_trades':engine_counts['trend'],'range_trades':engine_counts['range'],'pass_hold':pass_hold,'pass_full':pass_full}
        for z,m in enumerate(fm,1):
            for kk,vv in m.items(): row[f'fold{z}_{kk}']=vv
        out.append(row)
    pd.DataFrame(out).to_csv('nvda_adaptive_search_results.csv',index=False)
    good=[r for r in out if r['pass_hold'] and r['pass_full']]
    if good:
        winner=good[0]; pd.DataFrame([winner]).to_csv('nvda_adaptive_winner.csv',index=False); print('\nWINNER',winner)
    else:
        print('\nNO CANDIDATE PASSED BOTH HOLDOUT AND FULL GATES')

if __name__=='__main__': main()
