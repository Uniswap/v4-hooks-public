"""Run fee designs against each other in the two-venue environment.

    python3 run_study.py --configs "kind:a:b;..." --seeds 128 --blocks-days 365 \
        --market-arrival 0.4220 --half-width-bps 20 --norm-tvl 50000000 \
        --router-gas-usd 0.35 --out NAME

Writes results/results-NAME.json: one row per (config, seed) with pnl, fees,
volume and diagnostics, plus the market tuple the run used. Results are plain
JSON, so analysis never re-runs the simulation.

Two things to keep in mind when reading the output:

* Every config sees the same seeds. Raw pnl is dominated by which price path a
  seed drew, and that cancels in a paired difference. Never compare configs
  across different seed sets.

* Matched average fee is the comparison that isolates shape from level. Flow is
  direction-symmetric here (retail is a fair coin; an arb excursion pays one leg
  out and one leg back), so a design charging F on the toward leg and 0 on the
  away leg collects an average of F/2. Compare designs at the same average fee:
  flat F against hook(0/2F) against inverted(2F/0).
"""

from __future__ import annotations

import argparse
import json
import multiprocessing as mp
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from stablesim.env import config as C                     # noqa: E402
from stablesim.env.two_venue import run_two_venue_path    # noqa: E402
from stablesim import engines                             # noqa: E402


def _one(job: tuple) -> dict:
    """Run a single (config, seed) path, in a worker."""
    spec, seed, blocks, market = job
    eng = engines.build(spec)
    t0 = time.monotonic()
    from stablesim.retail_empirical import QuantileRetail
    (arrival, norm_tvl, quantiles, rival_fee, hw, buy_prob, gas_usd, gas_asym,
     our_tvl, our_hw, coverage) = market
    qpath = Path(quantiles)
    if not qpath.is_absolute():          # recorded relative to the sim dir
        qpath = ROOT / qpath
    r = run_two_venue_path(
        eng, C.PathConfig(seed=seed, blocks=blocks),
        retail_orders=QuantileRetail(arrival, qpath, buy_prob=buy_prob),
        router_gas_raw=(int(round((gas_usd + gas_asym) * C.SCALE)),
                        int(round(gas_usd * C.SCALE))),
        scored_tvl_usd=our_tvl,
        rival_fee_e6=rival_fee,
        rival_tvl_usd=norm_tvl, rival_tracks_fair=True,
        half_width_bps=hw,
        scored_half_width_bps=our_hw,
        integration_coverage=coverage,
    )
    return {
        "spec": list(spec), "label": eng.label, "kind": eng.kind,
        "market": list(market), "seed": seed, "blocks": blocks,
        "toward_volume": r.toward_volume, "away_volume": r.away_volume,
        "pnl": r.pnl, "lp_fee": r.lp_fee, "trades": r.trades,
        "volume": r.volume, "volume_share": r.volume_share,
        "rival_pnl": r.rival_pnl,
        "retail_arrived": r.retail_arrived, "retail_executed": r.retail_executed,
        "track_err_bp": r.track_err_bp, "vol_mean": r.vol_mean,
        "seconds": time.monotonic() - t0,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--configs", type=str, required=True,
                    help='designs to run, "kind:a:b;kind:a:b;..." (see stablesim/engines.py)')
    ap.add_argument("--seeds", type=int, default=128)
    # Seeds [start, start+seeds). Rows store absolute seed ids, so a run can be
    # extended later and still pair against the earlier seeds.
    ap.add_argument("--seed-start", type=int, default=0)
    ap.add_argument("--workers", type=int, default=max(1, mp.cpu_count() - 2))
    ap.add_argument("--blocks-days", type=int, default=C.DAYS_PER_PATH)
    ap.add_argument("--market-arrival", type=float, required=True,
                    help="total market retail arrivals per block (published: 0.4220)")
    ap.add_argument("--norm-tvl", type=float, default=50e6,
                    help="rest-of-market depth in USD at the chosen half-width")
    ap.add_argument("--half-width-bps", type=float, default=20.0,
                    help="range half-width for both pools")
    ap.add_argument("--rival-fee", type=int, default=None,
                    help="rest-of-market fee in e6 pips (default: config.RIVAL_FEE_E6)")
    ap.add_argument("--quantiles", type=str,
                    default=str(ROOT / "data" / "retail_size_quantiles.csv"),
                    help="empirical order-size quantile table")
    # 0.5: retail is treated as noise flow, and net direction lives in the fair
    # price path. See methodology.md.
    ap.add_argument("--buy-prob", type=float, default=0.5)
    # Fixed routing cost per venue LEG in USD, measured on retail transactions:
    # marginal leg ~$0.35 at the window's median gas price.
    ap.add_argument("--router-gas-usd", type=float, default=0.35)
    # EXTRA per-leg USD charged only on the scored pool, for measured frictions
    # the rest of the market does not pay. Research parameter; published runs use 0.
    ap.add_argument("--router-gas-asym", type=float, default=0.0)
    # Scored pool's TVL and half-width when they differ from the defaults.
    ap.add_argument("--our-tvl", type=float, default=None)
    ap.add_argument("--our-half-width-bps", type=float, default=None)
    # Probability a retail order's router quotes the scored pool at all.
    # Research parameter; published runs use 1.0.
    ap.add_argument("--integration-coverage", type=float, default=1.0)
    ap.add_argument("--out", type=str, required=True,
                    help="basename for results/results-<name>.json")
    args = ap.parse_args()

    configs = [tuple([p.split(":")[0], int(p.split(":")[1]), int(p.split(":")[2])])
               for p in args.configs.split(";") if p]
    blocks = args.blocks_days * C.BLOCKS_PER_DAY
    seeds = list(range(args.seed_start, args.seed_start + args.seeds))
    # Record the quantiles path relative to the sim dir when it lives inside it, so
    # results files carry no machine-specific paths.
    qabs = Path(args.quantiles).resolve()
    try:
        quantiles_rec = str(qabs.relative_to(ROOT))
    except ValueError:
        quantiles_rec = str(qabs)
    market = (args.market_arrival, args.norm_tvl, quantiles_rec,
              args.rival_fee if args.rival_fee is not None else C.RIVAL_FEE_E6,
              args.half_width_bps, args.buy_prob, args.router_gas_usd,
              args.router_gas_asym, args.our_tvl, args.our_half_width_bps,
              args.integration_coverage)
    jobs = [(spec, s, blocks, market) for spec in configs for s in seeds]
    print(f"configs={len(configs)} seeds={len(seeds)} blocks={blocks:,} "
          f"jobs={len(jobs)} workers={args.workers}", flush=True)

    t0 = time.monotonic()
    rows: list[dict] = []
    with mp.Pool(args.workers) as pool:
        for i, row in enumerate(pool.imap_unordered(_one, jobs, chunksize=1), 1):
            rows.append(row)
            if i % 40 == 0 or i == len(jobs):
                el = time.monotonic() - t0
                print(f"  {i}/{len(jobs)}  {el/60:.1f} min elapsed, "
                      f"~{el/i*(len(jobs)-i)/60:.1f} min left", flush=True)

    out = ROOT / "results" / f"results-{args.out}.json"
    out.parent.mkdir(exist_ok=True)
    if out.exists():
        print(f"NOTE: overwriting existing {out.name}", flush=True)
    out.write_text(json.dumps({"blocks": blocks, "seeds": seeds, "market": list(market),
                               "rows": rows}, indent=1) + "\n")
    print(f"wrote {out}  ({time.monotonic()-t0:.0f}s total)", flush=True)


if __name__ == "__main__":
    main()
