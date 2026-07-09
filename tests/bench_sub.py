#!/usr/bin/env python3
"""Latency benchmark subscriber.

Subscribes to the topic published by bench_pub.py, measures end-to-end
latency using the embedded nanosecond timestamp, discards a configurable
warmup window, then prints a single JSON object of statistics to stdout
before exiting.

Output JSON keys:
  n          – messages counted after warmup
  mean_ms    – arithmetic mean latency
  p50_ms     – 50th percentile
  p95_ms     – 95th percentile
  p99_ms     – 99th percentile
  max_ms     – maximum observed latency
  min_ms     – minimum observed latency
  gaps       – number of detected sequence gaps (dropped messages)
"""
import argparse
import json
import sys
import time

import rclpy
from rclpy.node import Node
from std_msgs.msg import String


class BenchSubscriber(Node):
    def __init__(self, duration: float, warmup: float, topic: str):
        super().__init__('bench_sub')
        self._warmup_end = time.monotonic() + warmup
        self._deadline = time.monotonic() + duration
        self._latencies: list[float] = []
        self._gaps = 0
        self._last_seq = -1
        self._done = False
        self.create_subscription(String, topic, self._callback, 100)

    def _callback(self, msg: String) -> None:
        recv_ns = time.time_ns()
        now_mono = time.monotonic()

        if now_mono >= self._deadline:
            self._done = True
            return

        try:
            send_ns_str, seq_str = msg.data.split(',', 1)
            seq = int(seq_str)
        except (ValueError, AttributeError):
            return

        # Track sequence gaps regardless of warmup (so gap count is accurate).
        # Skip out-of-order / duplicate arrivals to avoid false gap inflation.
        if self._last_seq >= 0 and seq <= self._last_seq:
            return
        if self._last_seq >= 0 and seq != self._last_seq + 1:
            self._gaps += seq - self._last_seq - 1  # guaranteed positive
        self._last_seq = seq

        if now_mono < self._warmup_end:
            return  # discard warmup messages from latency stats

        latency_ms = (recv_ns - int(send_ns_str)) / 1e6
        self._latencies.append(latency_ms)


def _percentile(data: list[float], p: float) -> float:
    if not data:
        return 0.0
    s = sorted(data)
    k = (len(s) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def main() -> None:
    parser = argparse.ArgumentParser(description='Zenoh latency benchmark subscriber')
    parser.add_argument('--duration', type=float, default=30.0,
                        help='measurement window in seconds (default: 30)')
    parser.add_argument('--warmup', type=float, default=5.0,
                        help='warmup period to discard in seconds (default: 5)')
    parser.add_argument('--topic', default='/bench',
                        help='ROS 2 topic name (default: /bench)')
    args = parser.parse_args()

    rclpy.init()
    node = BenchSubscriber(args.duration, args.warmup, args.topic)
    try:
        while rclpy.ok() and not node._done:
            rclpy.spin_once(node, timeout_sec=0.1)
            if time.monotonic() >= node._deadline:
                break
    except KeyboardInterrupt:
        pass
    finally:
        lats = node._latencies
        stats = {
            'n':       len(lats),
            'mean_ms': round(sum(lats) / len(lats), 3) if lats else 0.0,
            'p50_ms':  round(_percentile(lats, 50),  3),
            'p95_ms':  round(_percentile(lats, 95),  3),
            'p99_ms':  round(_percentile(lats, 99),  3),
            'max_ms':  round(max(lats), 3) if lats else 0.0,
            'min_ms':  round(min(lats), 3) if lats else 0.0,
            'gaps':    node._gaps,
        }
        print(json.dumps(stats), flush=True)
        node.destroy_node()
        rclpy.shutdown()
    sys.exit(0)


if __name__ == '__main__':
    main()
