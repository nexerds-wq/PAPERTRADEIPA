import math
import sys
import io
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
import requests

DATA_URL = 'https://raw.githubusercontent.com/getdata-finance/nvda-3m-ohlcv-stocks-historical-data/main/NVDA_3m.csv'

# Exact strategy inputs from NEXER_RESEARCH_V3_FIXED.pine
EMA_LEN = 200
VOL_LEN = 20
VOL_MULT = 0.90
ATR_LEN = 14
MIN_ATR_PCT = 0.20
MTF_EMA_LEN = 50
STOP_ATR = 0.80
TARGET_ATR = 1.20
BE_AT_ATR = 0.55
MAX_TRADES_DAY = 4
MAX_LOSSES_DAY = 2
COOLDOWN_BARS = 3
COMMISSION = 0.0005  # 0.05% each side
TICK = 0.01
SLIPPAGE_TICKS = 1
SLIP = TICK * SLIPPAGE_TICKS

SLOTS = [
    ((9,30),(10,0)),
    ((10,0),(10,30)),
    ((11,0),(11,30)),
    ((13,0),(13,30)),
    ((14,0),(14,30)),
    ((15,0),(15,30)),
]


def rma(s: pd.Series, n: int) -> pd.Series:
    """Wilder RMA close to Pine ta.rma: SMA seed at n, then recursive alpha=1/n."""
    x = s.astype(float).to_numpy()
    out = np.full(len(x), np.nan, dtype=float)
    if len(x) < n:
        return pd.Series(out, index=s.index)
    start = None
    for i in range(n-1, len(x)):
        w = x[i-n+1:i+1]
        if np.all(np.isfinite(w)):
            start = i
            break
    if start is None:
        return pd.Series(out, index=s.index)
    out[start] = np.mean(x[start-n+1:start+1])
    a = 1.0 / n
    for i in range(start+1, len(x)):
        if np.isfinite(x[i]):
            out[i] = a*x[i] + (1-a)*out[i-1]
        else:
            out[i] = out[i-1]
    return pd.Series(out, index=s.index)


def load_data() -> pd.DataFrame:
    r = requests.get(DATA_URL, timeout=60)
    r.raise_for_status()
    df = pd.read_csv(io.StringIO(r.text))
    df['datetime'] = pd.to_datetime(df['datetime'], utc=True)
    df = df.sort_values('datetime').drop_duplicates('datetime').reset_index(drop=True)
    for c in ['open','high','low','close','volume']:
        df[c] = pd.to_numeric(df[c], errors='coerce')
    df = df.dropna(subset=['open','high','low','close','volume']).copy()
    df['ny'] = df['datetime'].dt.tz_convert('America/New_York')
    mins = df['ny'].dt.hour*60 + df['ny'].dt.minute
    df = df[(mins >= 9*60+30) & (mins < 16*60)].copy().reset_index(drop=True)
    df['date'] = df['ny'].dt.date
    df['minute'] = df['ny'].dt.hour*60 + df['ny'].dt.minute
    return df


def add_indicators(df: pd.DataFrame) -> pd.DataFrame:
    d = df.copy()
    typical = (d['high'] + d['low'] + d['close']) / 3.0
    pv = typical * d['volume']
    d['vwap'] = pv.groupby(d['date']).cumsum() / d['volume'].groupby(d['date']).cumsum()
    d['ema200'] = d['close'].ewm(span=EMA_LEN, adjust=False).mean()
    d['volsma'] = d['volume'].rolling(VOL_LEN, min_periods=VOL_LEN).mean()
    prev_close = d['close'].shift(1)
    tr = pd.concat([
        d['high'] - d['low'],
        (d['high'] - prev_close).abs(),
        (d['low'] - prev_close).abs(),
    ], axis=1).max(axis=1)
    d['atr'] = rma(tr, ATR_LEN)
    d['atr_pct'] = d['atr'] / d['close'] * 100.0
    d['slot15'] = ((d['minute'] - (9*60+30)) // 15).astype(int)
    agg = d.groupby(['date','slot15'], sort=True).agg(close15=('close','last')).reset_index()
    agg['ema15'] = agg['close15'].ewm(span=MTF_EMA_LEN, adjust=False).mean()
    agg['mtfClose'] = agg['close15'].shift(1)
    agg['mtfEMA'] = agg['ema15'].shift(1)
    agg['mtfEMA1'] = agg['ema15'].shift(2)
    d = d.merge(agg[['date','slot15','mtfClose','mtfEMA','mtfEMA1']], on=['date','slot15'], how='left')
    return d


def in_slot(minute: int, slot_idx: int) -> bool:
    (sh,sm),(eh,em) = SLOTS[slot_idx]
    s = sh*60+sm; e = eh*60+em
    return s <= minute < e


def any_slot(minute: int) -> bool:
    return any(in_slot(minute, j) for j in range(6))

@dataclass
class Position:
    entry_time: object
    signal_time: object
    entry_price: float
    entry_commission: float
    qty: float = 1.0
    active_stop: float = math.nan
    active_target: float = math.nan


def fill_exit(position: Position, price: float, when, reason: str):
    exit_comm = price * position.qty * COMMISSION
    gross = (price - position.entry_price) * position.qty
    pnl = gross - position.entry_commission - exit_comm
    return {
        'signal_time': position.signal_time,
        'entry_time': position.entry_time,
        'exit_time': when,
        'entry_price': position.entry_price,
        'exit_price': price,
        'reason': reason,
        'gross': gross,
        'commission': position.entry_commission + exit_comm,
        'pnl': pnl,
        'return_pct_on_entry_value': pnl / (position.entry_price * position.qty) * 100.0,
    }


def run_backtest(df: pd.DataFrame, use_volume=True, conservative_both_hit=True):
    prev_slot_up = [False]*6
    slot_open = [math.nan]*6
    trades_today = 0
    losses_today = 0
    last_exit_bar = None
    last_date = None
    position = None
    pending_entry = None
    pending_market_close = False
    trades = []

    for i, row in df.iterrows():
        date = row['date']
        minute = int(row['minute'])
        ny = row['ny']
        if last_date is None or date != last_date:
            trades_today = 0
            losses_today = 0
            last_date = date
        prev_minute = int(df.iloc[i-1]['minute']) if i > 0 and df.iloc[i-1]['date'] == date else None
        starts = [in_slot(minute,j) and not (prev_minute is not None and in_slot(prev_minute,j)) for j in range(6)]
        ends = [not in_slot(minute,j) and (prev_minute is not None and in_slot(prev_minute,j)) for j in range(6)]
        current_any = any_slot(minute)
        prev_any = any_slot(prev_minute) if prev_minute is not None else False
        slot_just_ended = (not current_any) and prev_any

        if position is not None and pending_market_close:
            px = float(row['open']) - SLIP
            t = fill_exit(position, px, ny, 'SLOT_END_MARKET')
            trades.append(t)
            if t['pnl'] < 0:
                losses_today += 1
            last_exit_bar = i
            position = None
            pending_market_close = False

        if position is None and pending_entry is not None:
            px = float(row['open']) + SLIP
            entry_comm = px * COMMISSION
            position = Position(entry_time=ny, signal_time=pending_entry['signal_time'], entry_price=px, entry_commission=entry_comm)
            pending_entry = None

        if position is not None and not pending_market_close and np.isfinite(position.active_stop) and np.isfinite(position.active_target):
            stop = position.active_stop
            target = position.active_target
            o,h,l = float(row['open']), float(row['high']), float(row['low'])
            hit_stop = l <= stop
            hit_target = h >= target
            if hit_stop or hit_target:
                if hit_stop and hit_target:
                    if conservative_both_hit:
                        which = 'stop'
                    else:
                        path_high_first = abs(o-h) < abs(o-l)
                        which = 'target' if path_high_first else 'stop'
                else:
                    which = 'stop' if hit_stop else 'target'
                if which == 'stop':
                    trigger_fill = stop - SLIP
                    px = min(o - SLIP, trigger_fill) if o < stop else trigger_fill
                    reason = 'ATR_STOP'
                else:
                    px = max(target, o) if o >= target else target
                    reason = 'ATR_TARGET'
                t = fill_exit(position, px, ny, reason)
                trades.append(t)
                if t['pnl'] < 0:
                    losses_today += 1
                last_exit_bar = i
                position = None

        for j in range(6):
            if starts[j]:
                slot_open[j] = float(row['open'])
            if ends[j] and np.isfinite(slot_open[j]):
                prev_slot_up[j] = float(df.iloc[i-1]['close']) > slot_open[j]

        vals_finite = all(np.isfinite(row[k]) for k in ['vwap','ema200','volsma','atr','atr_pct','mtfClose','mtfEMA','mtfEMA1'])
        if vals_finite:
            vwap_ok = float(row['close']) > float(row['vwap'])
            ema_ok = float(row['close']) > float(row['ema200'])
            vol_ok = (not use_volume) or float(row['volume']) >= float(row['volsma']) * VOL_MULT
            atr_ok = float(row['atr_pct']) >= MIN_ATR_PCT
            mtf_ok = float(row['mtfClose']) > float(row['mtfEMA']) and float(row['mtfEMA']) > float(row['mtfEMA1'])
            quality_ok = vwap_ok and ema_ok and vol_ok and atr_ok and mtf_ok
        else:
            quality_ok = False

        cooldown_ok = last_exit_bar is None or (i - last_exit_bar >= COOLDOWN_BARS)
        daily_ok = trades_today < MAX_TRADES_DAY and losses_today < MAX_LOSSES_DAY
        flat = position is None and pending_entry is None
        raw_periodic = any(starts[j] and prev_slot_up[j] for j in range(6))
        long_signal = flat and daily_ok and cooldown_ok and raw_periodic and quality_ok
        if long_signal:
            pending_entry = {'signal_time': ny}
            trades_today += 1

        if position is not None:
            atr = float(row['atr']) if np.isfinite(row['atr']) else math.nan
            if np.isfinite(atr):
                base_stop = position.entry_price - atr * STOP_ATR
                target = position.entry_price + atr * TARGET_ATR
                be_reached = float(row['high']) >= position.entry_price + atr * BE_AT_ATR
                final_stop = max(base_stop, position.entry_price) if be_reached else base_stop
                position.active_stop = final_stop
                position.active_target = target
            if slot_just_ended:
                pending_market_close = True

    if position is not None:
        row = df.iloc[-1]
        t = fill_exit(position, float(row['close']) - SLIP, row['ny'], 'END_OF_DATA')
        trades.append(t)

    tdf = pd.DataFrame(trades)
    if tdf.empty:
        return {'trades': 0, 'win_rate': math.nan, 'profit_factor': math.nan, 'net_profit': 0.0, 'gross_profit':0.0, 'gross_loss':0.0, 'max_drawdown':0.0, 'avg_trade':math.nan, 'trades_df':tdf}
    gross_profit = tdf.loc[tdf.pnl > 0, 'pnl'].sum()
    gross_loss_abs = -tdf.loc[tdf.pnl < 0, 'pnl'].sum()
    pf = gross_profit / gross_loss_abs if gross_loss_abs > 0 else math.inf
    win_rate = (tdf.pnl > 0).mean() * 100
    eq = 10000 + tdf.pnl.cumsum()
    peak = eq.cummax()
    max_dd = (peak - eq).max()
    return {
        'trades': len(tdf),
        'wins': int((tdf.pnl > 0).sum()),
        'losses': int((tdf.pnl < 0).sum()),
        'win_rate': win_rate,
        'profit_factor': pf,
        'net_profit': tdf.pnl.sum(),
        'gross_profit': gross_profit,
        'gross_loss': gross_loss_abs,
        'max_drawdown': max_dd,
        'avg_trade': tdf.pnl.mean(),
        'avg_return_pct': tdf.return_pct_on_entry_value.mean(),
        'trades_df': tdf,
    }


def report(name, result):
    print(f'\n=== {name} ===')
    for k in ['trades','wins','losses','win_rate','profit_factor','net_profit','gross_profit','gross_loss','max_drawdown','avg_trade','avg_return_pct']:
        if k in result:
            v=result[k]
            if isinstance(v,float):
                print(f'{k}: {v:.6f}')
            else:
                print(f'{k}: {v}')
    passed = result['trades'] >= 100 and result['win_rate'] >= 50 and result['profit_factor'] >= 1.20 and result['net_profit'] > 0
    print('performance_gate:', 'PASS' if passed else 'NOT PROVEN')
    if not result['trades_df'].empty:
        print('exit_reasons:')
        print(result['trades_df']['reason'].value_counts().to_string())


def main():
    df=add_indicators(load_data())
    print('rows:', len(df))
    print('period_utc:', df['datetime'].min(), '->', df['datetime'].max())
    print('period_ny:', df['ny'].min(), '->', df['ny'].max())
    print('trading_days:', df['date'].nunique())
    print('local_time_range:', df['ny'].dt.strftime('%H:%M').min(), '->', df['ny'].dt.strftime('%H:%M').max())
    print('source:', DATA_URL)
    print('note: source volume is tick-volume per publisher; TradingView volume may differ.')

    exact = run_backtest(df, use_volume=True, conservative_both_hit=True)
    report('V3 DEFAULTS / VOLUME ON / CONSERVATIVE SAME-BAR COLLISIONS', exact)
    no_vol = run_backtest(df, use_volume=False, conservative_both_hit=True)
    report('SENSITIVITY / VOLUME FILTER OFF', no_vol)
    path = run_backtest(df, use_volume=True, conservative_both_hit=False)
    report('SENSITIVITY / TRADINGVIEW-LIKE OHLC PATH FOR BOTH-HIT BARS', path)

    exact['trades_df'].to_csv('nvda_v3_trades.csv', index=False)
    summary = pd.DataFrame([
        {'case':'default_conservative', **{k:v for k,v in exact.items() if k!='trades_df'}},
        {'case':'volume_off', **{k:v for k,v in no_vol.items() if k!='trades_df'}},
        {'case':'ohlc_path', **{k:v for k,v in path.items() if k!='trades_df'}},
    ])
    summary.to_csv('nvda_v3_summary.csv', index=False)

if __name__=='__main__':
    main()
