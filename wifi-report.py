#!/usr/bin/env python3
"""把 wifi-watch.sh 的日志汇总成「分时网络质量报告」。

支持多链路：Wi-Fi（en0）与手机热点（en8）分开统计。
热点没有协商速率和 RSSI，因此评价主要由丢包/延迟决定。

用法：
    python3 wifi-report.py                      # 只看 Wi-Fi，按小时
    python3 wifi-report.py --iface all          # 所有链路各出一张表
    python3 wifi-report.py --iface en8          # 只看某条链路
    python3 wifi-report.py --bin 30 --date 2026-10-18
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
            rows.append(
                {
                    "date": d["date"],
                    "minute": int(d["hour"]) * 60 + int(d["min"]),
                    "iface": d["iface"],
                    "rate": num(d["rate"]),
                    "loss": float(net_loss.rstrip("%")),
                    "rtt": num(net_rtt.rstrip("ms")),
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
    rates = [x["rate"] for x in items if x["rate"]]
    rtts = [x["rtt"] for x in items if x["rtt"]]
    rssis = [x["rssi"] for x in items if x["rssi"]]
    losses = [x["loss"] for x in items]
    return {
        "n": len(items),
        "rate": statistics.fmean(rates) if rates else None,
        "minrate": min(rates) if rates else None,
        "rtt": statistics.fmean(rtts) if rtts else None,
        "rssi": statistics.fmean(rssis) if rssis else None,
        "loss": statistics.fmean(losses) if losses else None,
        "slow": (sum(1 for x in rates if x < 30) / len(rates) * 100) if rates else None,
    }


def grade(s):
    """按丢包优先、其次延迟/速率评级。热点没有速率时只看前两项。"""
    if s["loss"] is None:
        return "—"
    if s["loss"] >= 20:
        return "差"
    if s["loss"] >= 5:
        return "中"
    if s["rate"] is not None and s["rate"] < 80:
        return "中"
    if s["rtt"] is not None and s["rtt"] >= 150:
        return "中"
    return "好"


def fmt(value, suffix="", digits=0):
    if value is None:
        return "-"
    return f"{value:.{digits}f}{suffix}"


def iface_title(name):
    if name == "en0":
        return "Wi-Fi (en0)"
    return f"其他链路 ({name})"


def render(rows, name, bin_size):
    buckets = bucketise(rows, bin_size)
    data = []
    for key, items in buckets.items():
        s = stats(items)
        s["label"] = f"{key // 60:02d}:{key % 60:02d}"
        data.append(s)

    first, last = rows[0], rows[-1]
    print(
        f"\n【{iface_title(name)}】{len(rows)} 个采样 · "
        f"{first['minute']//60:02d}:{first['minute']%60:02d}"
        f" → {last['minute']//60:02d}:{last['minute']%60:02d} · "
        f"{len(data)} 个时段"
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

    rated = [s for s in data if s["rate"]]
    if rated:
        peak = max(s["rate"] for s in rated)
        print(f"\n平均协商速率（峰值 {peak:.0f} Mbps）")
        for s in rated:
            print(f"  {s['label']}  {bar(s['rate'], peak)} {s['rate']:.0f}")

    print("\n结论")
    by_loss = sorted(data, key=lambda s: s["loss"] if s["loss"] is not None else 999)
    best, worst = by_loss[0], by_loss[-1]
    print(f"  丢包最低：{best['label']}  {fmt(best['loss'],'%',1)} / {fmt(best['rtt'],'ms')}")
    print(f"  丢包最高：{worst['label']}  {fmt(worst['loss'],'%',1)} / {fmt(worst['rtt'],'ms')}")

    good = [s["label"] for s in data if grade(s) == "好"]
    bad = [s["label"] for s in data if grade(s) == "差"]
    if good:
        print(f"  适合跑大流量：{', '.join(good)}")
    if bad:
        print(f"  建议只做轻量任务：{', '.join(bad)}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--log", default=os.path.expanduser("~/wifi-watch.log"))
    p.add_argument("--bin", type=int, default=60, choices=[15, 30, 60], help="分钟粒度")
    p.add_argument("--date", default=None, help="只看某一天，例如 2026-10-18")
    p.add_argument(
        "--iface",
        default="en0",
        help="统计哪条链路：en0 / en8 / all（默认 en0）",
    )
    args = p.parse_args()

    rows = load(args.log, args.date)
    if not rows:
        print("没有可用数据")
        return

    rows.sort(key=lambda r: (r["date"], r["minute"]))

    if args.iface == "all":
        names = []
        for r in rows:
            if r["iface"] not in names:
                names.append(r["iface"])
        # "none" 表示当时没有默认路由（正在切换链路），单独提一句即可，不单独出表
        none_count = sum(1 for r in rows if r["iface"] == "none")
        names = [n for n in names if n != "none"]
        # Wi-Fi 优先展示
        names.sort(key=lambda n: (n != "en0", n))
        print(f"\n网络分时报告  {args.date or rows[0]['date']}   （{len(rows)} 个采样）")
        for name in names:
            subset = [r for r in rows if r["iface"] == name]
            if subset:
                render(subset, name, args.bin)
        if none_count:
            print(f"\n另有 {none_count} 个采样处于「无默认路由」状态（链路切换瞬间）")
        print()
        return

    subset = [r for r in rows if r["iface"] == args.iface]
    if not subset:
        print(f"接口 {args.iface} 当天没有采样")
        return

    print(f"\n网络分时报告  {args.date or subset[0]['date']}   （{len(subset)} 个采样）")
    render(subset, args.iface, args.bin)
    print()


if __name__ == "__main__":
    main()