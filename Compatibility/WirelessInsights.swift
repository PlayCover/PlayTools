// Build as module WirelessInsights with library evolution so compiled iOS 26+
// clients can safely use the public WirelessInsights ABI on Mac Catalyst hosts
// where Apple omits the framework.
import Foundation

public struct ServicePrediction: Sendable, Hashable, Codable {
    public enum Impact: Sendable, Hashable, Codable, Comparable {
        case low
        case medium
        case high
    }

    public enum Confidence: Sendable, Hashable, Codable, Comparable {
        case low
        case medium
        case high
    }

    public struct QuantizedInterval: Sendable {
        public static let minimal: Double = 5.0
        public static let short: Double = 15.0
        public static let medium: Double = 60.0
        public static let long: Double = 300.0
    }

    public struct ConfidenceScore: Sendable, Hashable, Codable {
        public let prediction: ServicePrediction.Confidence
        public let startTime: ServicePrediction.Confidence
        public let duration: ServicePrediction.Confidence

        public init(
            predictionConfidence: ServicePrediction.Confidence,
            startTimeConfidence: ServicePrediction.Confidence,
            durationConfidence: ServicePrediction.Confidence
        ) {
            self.prediction = predictionConfidence
            self.startTime = startTimeConfidence
            self.duration = durationConfidence
        }
    }

    public let impact: ServicePrediction.Impact
    public let predictedStartTime: Date
    public let predictedInterval: TimeInterval
    public let confidenceScore: ServicePrediction.ConfidenceScore

    public init(
        impact: ServicePrediction.Impact,
        predictedStartTime: Date,
        predictedInterval: TimeInterval,
        confidenceScore: ServicePrediction.ConfidenceScore
    ) {
        self.impact = impact
        self.predictedStartTime = predictedStartTime
        self.predictedInterval = predictedInterval
        self.confidenceScore = confidenceScore
    }
}

public enum ServicePredictionError: Error, Equatable, Hashable, Sendable {
    case unsupportedDevice
    case connectionError
}

@available(macCatalyst 18.0, iOS 18.0, *)
public final class ServicePredictionProvider {
    public init() {}

    public var servicePredictions: any AsyncSequence<[ServicePrediction], any Error> {
        AsyncThrowingStream<[ServicePrediction], any Error> { continuation in
            continuation.finish(throwing: ServicePredictionError.unsupportedDevice)
        }
    }
}
