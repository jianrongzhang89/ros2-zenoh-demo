#!/usr/bin/env python3
"""Latency benchmark publisher.

Publishes std_msgs/msg/String messages at a fixed rate with an embedded
nanosecond timestamp and sequence number so the subscriber can compute
end-to-end latency.

Message format: "<send_ns>,<seq>"
"""
import argparse
import sys
import time

import rclpy
from rclpy.node import Node
from std_msgs.msg import String


class BenchPublisher(Node):
    def __init__(self, rate_hz: float, duration: float, topic: str):
        super().__init__('bench_pub')
        self._pub = self.create_publisher(String, topic, 100)
        self._seq = 0
        self._stop = False
        self._deadline = time.monotonic() + duration
        self.create_timer(1.0 / rate_hz, self._publish)

    def _publish(self) -> None:
        if time.monotonic() >= self._deadline:
            self._stop = True
            return
        msg = String()
        msg.data = f"{time.time_ns()},{self._seq}"
        self._pub.publish(msg)
        self._seq += 1


def main() -> None:
    parser = argparse.ArgumentParser(description='Zenoh latency benchmark publisher')
    parser.add_argument('--rate', type=float, default=10.0,
                        help='publish rate in Hz (default: 10)')
    parser.add_argument('--duration', type=float, default=90.0,
                        help='how long to publish in seconds (default: 90)')
    parser.add_argument('--topic', default='/bench',
                        help='ROS 2 topic name (default: /bench)')
    args = parser.parse_args()

    rclpy.init()
    node = BenchPublisher(args.rate, args.duration, args.topic)
    try:
        while rclpy.ok() and not node._stop:
            rclpy.spin_once(node, timeout_sec=0.05)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.shutdown()
    sys.exit(0)


if __name__ == '__main__':
    main()
