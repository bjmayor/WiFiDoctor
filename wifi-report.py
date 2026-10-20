#!/usr/bin/env python3
"""把 wifi-watch.sh 的日志汇总成「分时网络质量报告」。

用法：
    python3 wifi-report.py                 # 按小时，读 ~/wifi-watch.log
    python3 wifi-report.py --bin 30        # 按半小时
    python3 wifi-report.py --date 2026-10-18
    python3 wifi-report.py --log /tmp/x.log

只用标准库，不依赖第三方包。
"""

import argparse
import os
import re
import statistics
from collections import OrderedDict

LINE = re.compile(
    r"^(?P<date>\d{4}-\d\d-\d\d) (?P<hour>\d\d):(?P<min>\d\d):\d\d\s+"
    r"if=(?P<iface>\S+)\s+link=(?P<link>\S+)\s+wifi=(?P<wifi>\S+)\s+"
    r"rssi=(?P<rssi>\S+)\s+noise=(?P<noise>\S+)\s+ch=(?P<ch>.*?)\s+"
    r"rate=(?P<rate>\S+)\s+gw=(?P<gw>\S+)\s+net=(?P<net>\S+)"
)


def num(value):
    return None if value in ("-", "") else float(value)


def bar(value, peak, width=28):
    if not peak:
        return ""
    n = int(round(value / peak * width))
    return "█" * max(n, 1)


def load(path, date_filter):
    rows = []
    with open(path, "r", errors="replace") as fh:
        for line in fh:
            m = LINE.match(line.strip())
            if not m:
                continue
            d = m.groupdict()
            if date_filter and d["date"] != date_filter:
                continue
            net_loss, _, net_rtt = d["net"].partition("/")
            d["loss"] = net_loss.rstrip("%")
            d["rtt"] = net_rtt.rstrip("ms")
            rows.append(
                {
                    "date": d["date"],
                    "minute": int(d["hour"]) * 60 + int(d["min"]),
                    "hour": int(d["hour"]),
                    "iface": d["iface"],
                    "rate": num(d["rate"]),
                    "loss": float(d["loss"]),
                    "rtt": num(d["rtt"]),
                    "rssi": num(d["rssi"]),
                }
            )
    return rows


def bucketise(rows, size):
    buckets = OrderedDict()
    for r in rows:
        key = r["minute"] // size * size
        buckets.setdefault(key, []).append(r)
    return buckets


def stats(items):
    wifi = [x for x in items if x["iface"] == "en0"]
    rates = [x["rate"] for x in wifi if x["rate"]]
    rtts = [x["rtt"] for x in wifi if x["rtt"]]
    rssis = [x["rssi"] for x in wifi if x["rssi"]]
    losses = [x["loss"] for x in wifi]
    return {
        "n": len(items),
        "nwifi": len(wifi),
        "rate": statistics.fmean(rates) if rates else None,
        "minrate": min(rates) if rates else None,
        "rtt": statistics.fmean(rtts) if rtts else None,
        "rssi": statistics.fmean(rssis) if rssis else None,
        "loss": statistics.fmean(losses) if losses else None,
        "slow": (sum(1 for x in rates if x < 30) / len(rates) * 100) if rates else None,
    }


def grade(s):
    if s["rate"] is None:
        return "—"
    if s["loss"] is not None and s["loss"] < 2 and s["rate"] >= 150:
        return "好"
    if s["loss"] is not None and s["loss"] < 5 and s["rate"] >= 80:
        return "中"
    return "差"


def fmt(value, suffix="", digits=0):
    if value is None:
        return "-"
    return f"{value:.{digits}f}{suffix}"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--log", default=os.path.expanduser("~/wifi-watch.log"))
    p.add_argument("--bin", type=int, default=60, choices=[15, 30, 60], help="分钟粒度")
    p.add_argument("--date", default=None, help="只看某一天，例如 2026-10-18")
    args = p.parse_args()

    rows = load(args.log, args.date)
    if not rows:
        print("没有可用数据")
        return

    rows.sort(key=lambda r: (r["date"], r["minute"]))
    buckets = bucketise(rows, args.bin)
    data = []
    for key, items in buckets.items():
        s = stats(items)
        s["label"] = f"{key // 60:02d}:{key % 60:02d}"
        data.append(s)

    first, last = rows[0], rows[-1]
    print(
        f"\n网络分时报告  {first['date']} {first['minute']//60:02d}:{first['minute']%60:02d}"
        f" → {last['date']} {last['minute']//60:02d}:{last['minute']%60:02d}"
        f"   （{len(rows)} 个采样，{len(data)} 个时段）\n"
    )

    head = f"{'时段':<7}{'样本':>5}{'平均RTT':>9}{'丢包':>8}{'平均速率':>10}{'最低':>7}{'低速占比':>9}{'RSSI':>7}{'评价':>6}"
    print(head)
    print("-" * len(head))
    for s in data:
        print(
            f"{s['label']:<7}{s['n']:>5}"
            f"{fmt(s['rtt'], 'ms'):>9}"
            f"{fmt(s['loss'], '%', 1):>8}"
            f"{fmt(s['rate'], 'M'):>10}"
            f"{fmt(s['minrate'], 'M'):>7}"
            f"{fmt(s['slow'], '%'):>9}"
            f"{fmt(s['rssi']):>7}"
            f"{grade(s):>6}"
        )

    peak = max((s["rate"] or 0) for s in data)
    print(f"\n平均协商速率（峰值 {peak:.0f} Mbps）")
    for s in data:
        if s["rate"]:
            print(f"  {s['label']}  {bar(s['rate'], peak)} {s['rate']:.0f}")

    best = max((s for s in data if s["rate"]), key=lambda s: s["rate"])
    worst = min((s for s in data if s["rate"]), key=lambda s: s["rate"])
    print("\n结论")
    print(f"  最快：{best['label']}  {best['rate']:.0f} Mbps / {fmt(best['rtt'],'ms')} / 丢包 {fmt(best['loss'],'%',1)}")
    print(f"  最慢：{worst['label']}  {worst['rate']:.0f} Mbps / {fmt(worst['rtt'],'ms')} / 丢包 {fmt(worst['loss'],'%',1)}")

    good = [s["label"] for s in data if grade(s) == "好"]
    bad = [s["label"] for s in data if grade(s) == "差"]
    if good:
        print(f"  适合跑大流量：{', '.join(good)}")
    if bad:
        print(f"  建议只做轻量任务：{', '.join(bad)}")

    other = [r for r in rows if r["iface"] != "en0"]
    if other:
        print(f"  另有 {len(other)} 个采样走的是非 Wi-Fi 接口（热点）")


if __name__ == "__main__":
    main()
