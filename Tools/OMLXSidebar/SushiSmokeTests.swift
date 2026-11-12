import Foundation

@main struct SushiSmokeTests {
    static func main() throws {
        let metrics = #"""
        {"counters":{"prompt_tokens_total":100,"prefix_cache_tokens_total":75},
         "gauges":{"memory_mb":4096,"prefill_tokens_live":40,"prefill_tokens_expected":80,
                   "generation_tokens_live":110},
         "sessions":[{"model":"local-sushi","request_id":7,"phase":"prefill",
                      "generated_tokens":0,"cached_tokens":25}]}
        """#
        let data = Data(metrics.utf8)
        let snapshot = try SushiTelemetryParser.live(from: data)
        precondition(snapshot.reading.phase == .processing)
        precondition(snapshot.reading.modelID == "local-sushi")
        precondition(snapshot.reading.progress == 0.5)
        let totals = try SushiTelemetryParser.totals(from: data)
        precondition(totals.prefillTokens == 100)
        precondition(totals.cachedTokens == 75)
        precondition(totals.cacheHitPercent == 75)
        var estimator = SushiRateEstimator()
        var first = snapshot.reading
        estimator.update(&first, cumulativeGenerated: nil, at: 10)
        var later = first
        later.tokens = 60
        estimator.update(&later, cumulativeGenerated: nil, at: 12)
        precondition(later.speed == 10)
        print("PASS oMLX/Sushi telemetry smoke tests")
    }
}
