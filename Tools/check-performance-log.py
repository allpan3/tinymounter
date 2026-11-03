#!/usr/bin/env python3
"""Check request correlation in the performance report without accessing a provider or share."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("performance", Path(__file__).with_name("check-performance-regression.py"))
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class PerformanceLogTests(unittest.TestCase):
    app = Path("/Applications/Read Check.app")
    first = "11111111-1111-1111-1111-111111111111"
    second = "22222222-2222-2222-2222-222222222222"

    def event(self, message, provider=False, app=None, second=1):
        suffix = "/Contents/PlugIns/Provider.appex/Contents/MacOS/Provider" if provider else "/Contents/MacOS/App"
        return {"timestamp": f"2026-11-01 00:00:{second:02d}.000000+0000",
                "processImagePath": str(app or self.app) + suffix, "eventMessage": message}

    def proof(self, request, **kwargs):
        message = (f"protected_read request={request} phase=complete mode=blocks cache=hit "
                   "edit_base=1 remote_bytes=16777216 namespace_ms=3000.000 setup_ms=2.000 "
                   "verify_ms=30.000 native_ms=5.000 checksum_ms=2.000 total_ms=3039.000")
        return self.event(message, **kwargs)

    def fetch(self, request, **kwargs):
        return self.event(f"request={request} item=opaque mode=partial kind=demand viewer=false system=false "
                          "offset=0 bytes=16777216 queue_seconds=0.001 callback_seconds=3.1 "
                          "transfer_seconds=0.005 planners=1", provider=True, **kwargs)

    def parse(self, events):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fetch.ndjson"
            path.write_text("not JSON\n" + "\n".join(json.dumps(event) for event in events))
            return performance.parse_fetch_log(path, self.app)

    def testCorrelationUsesRequestAndSelectedAppDespiteLogOrder(self):
        events = [self.proof(self.second), self.fetch(self.first, second=2), self.proof(self.first, second=3),
                  self.proof(self.first, app=Path("/Applications/Other.app")),
                  self.fetch(self.first, app=Path("/Applications/Other.app")),
                  self.event("list entries=1000 total_ms=3000")]
        callbacks = self.parse(events)
        self.assertEqual(len(callbacks), 1)
        records = callbacks[0]["protectedReads"]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["request"], self.first)
        self.assertEqual(records[0]["namespaceMs"], 3000)
        self.assertEqual(records[0]["remoteBytes"], 16777216)
        self.assertTrue(records[0]["editBase"])
        self.assertEqual(records[0]["mode"], "blocks")
        summary = performance.summarize_callbacks(callbacks, callbacks[0]["time"], callbacks[0]["time"])
        self.assertEqual(summary["protectedReads"], records)

    def testEarlierBuildOrNativeReadHasNoInventedVerification(self):
        callbacks = self.parse([self.fetch(self.first), self.proof(self.second)])
        self.assertEqual(callbacks[0]["protectedReads"], [])
        summary = performance.summarize_callbacks(callbacks, 0, float("inf"))
        self.assertEqual(summary["count"], 1)
        self.assertEqual(summary["protectedReads"], [])

    def testParallelPhasesAndPersistedProofAreRetained(self):
        proof = self.proof(self.first)
        proof["eventMessage"] = proof["eventMessage"].replace("cache=hit", "cache=disk") + " parallel=1"
        callbacks = self.parse([proof, self.fetch(self.first), self.proof(self.second), self.fetch(self.second)])
        self.assertTrue(callbacks[0]["protectedReads"][0]["parallel"])
        self.assertEqual(callbacks[0]["protectedReads"][0]["cache"], "disk")
        self.assertEqual(callbacks[0]["protectedReads"][0]["totalMs"], 3039)
        self.assertIsNone(callbacks[1]["protectedReads"][0]["parallel"])

    def testFailureRetainsUnreachedPhaseAndEveryAttempt(self):
        failed = self.proof(self.first)
        failed["eventMessage"] = failed["eventMessage"].replace("phase=complete", "phase=verify")
        failed["eventMessage"] = failed["eventMessage"].replace("native_ms=5.000 checksum_ms=2.000",
                                                              "native_ms=-1.000 checksum_ms=-1.000")
        callbacks = self.parse([failed, self.proof(self.first),
                                self.event(f"request={self.first} failed stage=fetch", provider=True)])
        summary = performance.summarize_callbacks(callbacks, 0, float("inf"))
        self.assertEqual(summary["failed"], 1)
        self.assertEqual(summary["count"], 0)
        self.assertEqual(len(summary["protectedReads"]), 2)
        self.assertEqual(summary["protectedReads"][0]["nativeMs"], -1)
        self.assertEqual(summary["protectedReads"][0]["phase"], "verify")

    def testMalformedRecordAndOtherSampleAreExcluded(self):
        malformed = self.proof(self.first)
        malformed["eventMessage"] = malformed["eventMessage"].replace("verify_ms=30.000", "verify_ms=1.2.3")
        callbacks = self.parse([malformed, self.fetch(self.first), self.fetch(self.second, second=3)])
        summary = performance.summarize_callbacks(callbacks, callbacks[0]["time"], callbacks[0]["time"])
        self.assertEqual(summary["count"], 1)
        self.assertEqual(summary["protectedReads"], [])


if __name__ == "__main__":
    unittest.main()
