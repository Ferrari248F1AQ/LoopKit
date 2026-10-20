//
//  TherapyRegression.swift
//  LoopKit
//
//  15-day regression model for therapy parameter optimization.
//  Analyzes glucose outcomes, insulin delivery, and carb entries to
//  suggest improved basal rates, ISF, and ICR values per time-of-day.
//
//  Pod-agnostic: runs in Loop to help users fine-tune settings
//  regardless of pump type or dosing algorithm.
//

import Foundation

// MARK: - Input Data Models

public struct RegressionGlucoseSample {
    public let date: Date
    public let mgdl: Double

    public init(date: Date, mgdl: Double) {
        self.date = date
        self.mgdl = mgdl
    }
}

public struct RegressionInsulinDelivery {
    public let startDate: Date
    public let endDate: Date
    public let units: Double
    public let isBasal: Bool
    public let isAutomatic: Bool

    public init(startDate: Date, endDate: Date, units: Double, isBasal: Bool, isAutomatic: Bool) {
        self.startDate = startDate
        self.endDate = endDate
        self.units = units
        self.isBasal = isBasal
        self.isAutomatic = isAutomatic
    }
}

public struct RegressionCarbEntry {
    public let date: Date
    public let grams: Double
    public let absorptionTime: TimeInterval

    public init(date: Date, grams: Double, absorptionTime: TimeInterval) {
        self.date = date
        self.grams = grams
        self.absorptionTime = absorptionTime
    }
}

// MARK: - Output Models

public struct BasalSuggestion {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let currentRate: Double
    public let suggestedRate: Double
    public let confidence: Double
    public let reason: String
    public let driftRate: Double

    public var timeBlock: TimeBlockLabel {
        TimeBlockLabel(startTime: startTime, endTime: endTime)
    }

    public var changePercent: Double {
        guard currentRate > 0 else { return 0 }
        return (suggestedRate - currentRate) / currentRate
    }
}

public struct ISFSuggestion {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let currentISF: Double
    public let suggestedISF: Double
    public let confidence: Double
    public let reason: String
    public let observedMedianISF: Double

    public var timeBlock: TimeBlockLabel {
        TimeBlockLabel(startTime: startTime, endTime: endTime)
    }

    public var changePercent: Double {
        guard currentISF > 0 else { return 0 }
        return (suggestedISF - currentISF) / currentISF
    }
}

public struct ICRSuggestion {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let currentICR: Double
    public let suggestedICR: Double
    public let confidence: Double
    public let reason: String
    public let observedMedianICR: Double

    public var timeBlock: TimeBlockLabel {
        TimeBlockLabel(startTime: startTime, endTime: endTime)
    }

    public var changePercent: Double {
        guard currentICR > 0 else { return 0 }
        return (suggestedICR - currentICR) / currentICR
    }
}

public struct RegressionReport {
    public let analysisDate: Date
    public let windowDays: Int
    public let basalSuggestions: [BasalSuggestion]
    public let isfSuggestions: [ISFSuggestion]
    public let icrSuggestions: [ICRSuggestion]
    public let averageGlucose: Double
    public let timeInRange: Double
    public let timeBelowRange: Double
    public let timeAboveRange: Double
    public let glucoseVariability: Double
    public let totalDataPoints: Int
    public let dataQuality: DataQuality
    public let glucoseSampleCount: Int
    public let doseSampleCount: Int
    public let carbEntrySampleCount: Int

    public enum DataQuality: String {
        case excellent = "excellent"
        case good = "good"
        case fair = "fair"
        case insufficient = "insufficient"

        public var displayName: String {
            switch self {
            case .excellent: return "Excellent"
            case .good: return "Good"
            case .fair: return "Fair"
            case .insufficient: return "Insufficient"
            }
        }
    }
}

// MARK: - Time Block Label

public struct TimeBlockLabel: Hashable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(startTime: TimeInterval, endTime: TimeInterval) {
        self.startTime = startTime
        self.endTime = endTime
    }

    public var displayName: String {
        let startHour = Int(startTime) / 3600
        let endHour = Int(endTime) / 3600
        return String(format: "%02d:00–%02d:00", startHour, endHour)
    }
}

// MARK: - Time Block

struct TimeBlock {
    let index: Int
    let startHour: Int
    let endHour: Int
    let glucoseReadings: [RegressionGlucoseSample]
    let basalDeliveries: [RegressionInsulinDelivery]
    let bolusDeliveries: [RegressionInsulinDelivery]
    let carbEntries: [RegressionCarbEntry]
}

// MARK: - Regression Engine

public struct TherapyRegression {

    public static let defaultWindowDays: Int = 15
    static let targetRangeLow: Double = 70.0
    static let targetRangeHigh: Double = 180.0
    static let idealTarget: Double = 110.0
    static let hoursPerBlock: Int = 3
    static let minimumReadingsPerBlock: Int = 5
    static let minimumDaysForSuggestion: Int = 5
    static let maxBasalAdjustment: Double = 0.30
    static let maxISFAdjustment: Double = 0.25
    static let maxICRAdjustment: Double = 0.25

    public static func analyze(
        glucose: [RegressionGlucoseSample],
        insulin: [RegressionInsulinDelivery],
        carbs: [RegressionCarbEntry],
        currentBasalSchedule: [(startTime: TimeInterval, rate: Double)],
        currentISFSchedule: [(startTime: TimeInterval, mgdlPerUnit: Double)],
        currentICRSchedule: [(startTime: TimeInterval, gramsPerUnit: Double)],
        windowDays: Int = defaultWindowDays,
        now: Date = Date()
    ) -> RegressionReport {

        let windowStart = now.addingTimeInterval(-Double(windowDays) * 86400)

        let windowGlucose = glucose.filter { $0.date >= windowStart && $0.date <= now }
        let windowInsulin = insulin.filter { $0.endDate >= windowStart && $0.startDate <= now }
        let windowCarbs = carbs.filter { $0.date >= windowStart && $0.date <= now }

        let glucoseMetrics = computeGlucoseMetrics(windowGlucose)
        let dataQuality = assessDataQuality(glucose: windowGlucose, windowDays: windowDays)

        let blocks = partitionIntoTimeBlocks(
            glucose: windowGlucose,
            insulin: windowInsulin,
            carbs: windowCarbs
        )

        let basalSuggestions = analyzeBasalRates(
            blocks: blocks,
            currentSchedule: currentBasalSchedule,
            dataQuality: dataQuality
        )

        let isfSuggestions = analyzeISF(
            blocks: blocks,
            currentSchedule: currentISFSchedule,
            dataQuality: dataQuality
        )

        let icrSuggestions = analyzeICR(
            blocks: blocks,
            currentSchedule: currentISFSchedule,
            currentICRSchedule: currentICRSchedule,
            dataQuality: dataQuality
        )

        return RegressionReport(
            analysisDate: now,
            windowDays: windowDays,
            basalSuggestions: basalSuggestions,
            isfSuggestions: isfSuggestions,
            icrSuggestions: icrSuggestions,
            averageGlucose: glucoseMetrics.average,
            timeInRange: glucoseMetrics.timeInRange,
            timeBelowRange: glucoseMetrics.timeBelowRange,
            timeAboveRange: glucoseMetrics.timeAboveRange,
            glucoseVariability: glucoseMetrics.cv,
            totalDataPoints: windowGlucose.count,
            dataQuality: dataQuality,
            glucoseSampleCount: windowGlucose.count,
            doseSampleCount: windowInsulin.count,
            carbEntrySampleCount: windowCarbs.count
        )
    }

    // MARK: - Glucose Metrics

    private struct GlucoseMetrics {
        let average: Double
        let stdDev: Double
        let cv: Double
        let timeInRange: Double
        let timeBelowRange: Double
        let timeAboveRange: Double
    }

    private static func computeGlucoseMetrics(_ samples: [RegressionGlucoseSample]) -> GlucoseMetrics {
        guard !samples.isEmpty else {
            return GlucoseMetrics(average: 0, stdDev: 0, cv: 0, timeInRange: 0, timeBelowRange: 0, timeAboveRange: 0)
        }

        let values = samples.map(\.mgdl)
        let avg = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(values.count)
        let sd = sqrt(variance)
        let cv = avg > 0 ? (sd / avg) * 100 : 0

        let inRange = Double(values.filter { $0 >= targetRangeLow && $0 <= targetRangeHigh }.count)
        let below = Double(values.filter { $0 < targetRangeLow }.count)
        let above = Double(values.filter { $0 > targetRangeHigh }.count)
        let total = Double(values.count)

        return GlucoseMetrics(
            average: avg,
            stdDev: sd,
            cv: cv,
            timeInRange: (inRange / total) * 100,
            timeBelowRange: (below / total) * 100,
            timeAboveRange: (above / total) * 100
        )
    }

    // MARK: - Data Quality

    private static func assessDataQuality(glucose: [RegressionGlucoseSample], windowDays: Int) -> RegressionReport.DataQuality {
        let expectedReadings = windowDays * 288
        let ratio = Double(glucose.count) / Double(expectedReadings)

        if ratio > 0.9 { return .excellent }
        if ratio > 0.7 { return .good }
        if ratio > 0.5 { return .fair }
        return .insufficient
    }

    // MARK: - Time Block Partitioning

    private static func partitionIntoTimeBlocks(
        glucose: [RegressionGlucoseSample],
        insulin: [RegressionInsulinDelivery],
        carbs: [RegressionCarbEntry]
    ) -> [TimeBlock] {

        let blockCount = 24 / hoursPerBlock
        var blocks: [TimeBlock] = []

        for i in 0..<blockCount {
            let startHour = i * hoursPerBlock
            let endHour = startHour + hoursPerBlock

            let blockGlucose = glucose.filter { sample in
                let hour = Calendar.current.component(.hour, from: sample.date)
                return hour >= startHour && hour < endHour
            }

            let blockBasal = insulin.filter { delivery in
                let hour = Calendar.current.component(.hour, from: delivery.startDate)
                return hour >= startHour && hour < endHour && delivery.isBasal
            }

            let blockBolus = insulin.filter { delivery in
                let hour = Calendar.current.component(.hour, from: delivery.startDate)
                return hour >= startHour && hour < endHour && !delivery.isBasal
            }

            let blockCarbs = carbs.filter { entry in
                let hour = Calendar.current.component(.hour, from: entry.date)
                return hour >= startHour && hour < endHour
            }

            blocks.append(TimeBlock(
                index: i,
                startHour: startHour,
                endHour: endHour,
                glucoseReadings: blockGlucose,
                basalDeliveries: blockBasal,
                bolusDeliveries: blockBolus,
                carbEntries: blockCarbs
            ))
        }

        return blocks
    }

    // MARK: - Basal Rate Analysis

    private static func analyzeBasalRates(
        blocks: [TimeBlock],
        currentSchedule: [(startTime: TimeInterval, rate: Double)],
        dataQuality: RegressionReport.DataQuality
    ) -> [BasalSuggestion] {

        guard dataQuality != .insufficient else { return [] }

        var suggestions: [BasalSuggestion] = []

        for block in blocks {
            let fastingReadings = filterFastingReadings(
                glucose: block.glucoseReadings,
                carbs: block.carbEntries,
                fastingHours: 4.0
            )

            guard fastingReadings.count >= minimumReadingsPerBlock else { continue }

            let driftRate = linearRegressionSlope(samples: fastingReadings)
            let blockStartSeconds = TimeInterval(block.startHour * 3600)
            let blockEndSeconds = TimeInterval(block.endHour * 3600)
            let currentRate = findScheduleValue(at: blockStartSeconds, in: currentSchedule.map { ($0.startTime, $0.rate) })

            let driftThreshold: Double = 5.0

            if abs(driftRate) > driftThreshold {
                let adjustmentFactor: Double
                if driftRate > 0 {
                    adjustmentFactor = min(maxBasalAdjustment, driftRate / 30.0)
                } else {
                    adjustmentFactor = max(-maxBasalAdjustment, driftRate / 30.0)
                }

                let suggestedRate = currentRate * (1.0 + adjustmentFactor)
                let clampedRate = max(0.05, round(suggestedRate * 20) / 20)

                let confidence = min(1.0, Double(fastingReadings.count) / 50.0)
                    * (dataQuality == .excellent ? 1.0 : dataQuality == .good ? 0.8 : 0.6)

                let direction = driftRate > 0 ? "rising" : "falling"
                suggestions.append(BasalSuggestion(
                    startTime: blockStartSeconds,
                    endTime: blockEndSeconds,
                    currentRate: currentRate,
                    suggestedRate: clampedRate,
                    confidence: confidence,
                    reason: "Fasting BG \(direction) ~\(String(format: "%.1f", abs(driftRate))) mg/dL/hr",
                    driftRate: driftRate
                ))
            }
        }

        return suggestions
    }

    // MARK: - ISF Analysis

    private static func analyzeISF(
        blocks: [TimeBlock],
        currentSchedule: [(startTime: TimeInterval, mgdlPerUnit: Double)],
        dataQuality: RegressionReport.DataQuality
    ) -> [ISFSuggestion] {

        guard dataQuality != .insufficient else { return [] }

        var suggestions: [ISFSuggestion] = []

        for block in blocks {
            let correctionBoluses = block.bolusDeliveries.filter { bolus in
                let bolusTime = bolus.startDate
                let hasMealContext = block.carbEntries.contains { carb in
                    abs(carb.date.timeIntervalSince(bolusTime)) < 900
                }
                return !hasMealContext && bolus.units > 0.05
            }

            guard correctionBoluses.count >= 3 else { continue }

            var observedISFs: [Double] = []
            for bolus in correctionBoluses {
                let bgBefore = findClosestGlucose(to: bolus.startDate, in: block.glucoseReadings, maxOffset: 600)
                let bgAfter = findClosestGlucose(
                    to: bolus.startDate.addingTimeInterval(10800),
                    in: block.glucoseReadings,
                    maxOffset: 1800
                )

                guard let before = bgBefore, let after = bgAfter, bolus.units > 0 else { continue }

                let drop = before - after
                let isf = drop / bolus.units

                if isf > 5 && isf < 500 {
                    observedISFs.append(isf)
                }
            }

            guard observedISFs.count >= 2 else { continue }

            let medianISF = median(observedISFs)
            let blockStartSeconds = TimeInterval(block.startHour * 3600)
            let blockEndSeconds = TimeInterval(block.endHour * 3600)
            let currentISF = findScheduleValue(at: blockStartSeconds, in: currentSchedule.map { ($0.startTime, $0.mgdlPerUnit) })

            let deviation = abs(medianISF - currentISF) / currentISF
            if deviation > 0.10 {
                let clampedISF: Double
                if medianISF > currentISF {
                    clampedISF = min(currentISF * (1.0 + maxISFAdjustment), medianISF)
                } else {
                    clampedISF = max(currentISF * (1.0 - maxISFAdjustment), medianISF)
                }

                let confidence = min(1.0, Double(observedISFs.count) / 10.0)
                    * (dataQuality == .excellent ? 1.0 : dataQuality == .good ? 0.8 : 0.6)

                suggestions.append(ISFSuggestion(
                    startTime: blockStartSeconds,
                    endTime: blockEndSeconds,
                    currentISF: currentISF,
                    suggestedISF: round(clampedISF),
                    confidence: confidence,
                    reason: "Observed ISF ~\(String(format: "%.0f", medianISF)) vs current \(String(format: "%.0f", currentISF)) (\(observedISFs.count) corrections)",
                    observedMedianISF: medianISF
                ))
            }
        }

        return suggestions
    }

    // MARK: - ICR Analysis

    private static func analyzeICR(
        blocks: [TimeBlock],
        currentSchedule: [(startTime: TimeInterval, mgdlPerUnit: Double)],
        currentICRSchedule: [(startTime: TimeInterval, gramsPerUnit: Double)],
        dataQuality: RegressionReport.DataQuality
    ) -> [ICRSuggestion] {

        guard dataQuality != .insufficient else { return [] }

        var suggestions: [ICRSuggestion] = []

        for block in blocks {
            guard !block.carbEntries.isEmpty else { continue }

            var observedICRs: [Double] = []

            for carb in block.carbEntries {
                guard carb.grams > 5 else { continue }

                let mealBolus = block.bolusDeliveries.first { bolus in
                    abs(bolus.startDate.timeIntervalSince(carb.date)) < 1800
                }

                guard let bolus = mealBolus, bolus.units > 0 else { continue }

                let bgAtMeal = findClosestGlucose(to: carb.date, in: block.glucoseReadings, maxOffset: 600)
                let bgPostMeal = findClosestGlucose(
                    to: carb.date.addingTimeInterval(10800),
                    in: block.glucoseReadings,
                    maxOffset: 1800
                )

                guard let preMeal = bgAtMeal, let postMeal = bgPostMeal else { continue }

                let bgDelta = postMeal - preMeal
                let blockStartSeconds = TimeInterval(block.startHour * 3600)
                let currentISFForBlock = findScheduleValue(
                    at: blockStartSeconds,
                    in: currentSchedule.map { ($0.startTime, $0.mgdlPerUnit) }
                )

                let idealBolus = bolus.units + (bgDelta / max(currentISFForBlock, 10))

                if idealBolus > 0 {
                    let observedICR = carb.grams / idealBolus
                    if observedICR > 1 && observedICR < 100 {
                        observedICRs.append(observedICR)
                    }
                }
            }

            guard observedICRs.count >= 3 else { continue }

            let medianICR = median(observedICRs)
            let blockStartSeconds = TimeInterval(block.startHour * 3600)
            let blockEndSeconds = TimeInterval(block.endHour * 3600)
            let currentICR = findScheduleValue(at: blockStartSeconds, in: currentICRSchedule.map { ($0.startTime, $0.gramsPerUnit) })

            let deviation = abs(medianICR - currentICR) / currentICR
            if deviation > 0.10 {
                let clampedICR: Double
                if medianICR > currentICR {
                    clampedICR = min(currentICR * (1.0 + maxICRAdjustment), medianICR)
                } else {
                    clampedICR = max(currentICR * (1.0 - maxICRAdjustment), medianICR)
                }

                let confidence = min(1.0, Double(observedICRs.count) / 10.0)
                    * (dataQuality == .excellent ? 1.0 : dataQuality == .good ? 0.8 : 0.6)

                suggestions.append(ICRSuggestion(
                    startTime: blockStartSeconds,
                    endTime: blockEndSeconds,
                    currentICR: currentICR,
                    suggestedICR: round(clampedICR * 10) / 10,
                    confidence: confidence,
                    reason: "Observed ICR ~\(String(format: "%.1f", medianICR)) vs current \(String(format: "%.1f", currentICR)) (\(observedICRs.count) meals)",
                    observedMedianICR: medianICR
                ))
            }
        }

        return suggestions
    }

    // MARK: - Helpers

    private static func linearRegressionSlope(samples: [RegressionGlucoseSample]) -> Double {
        guard samples.count >= 2 else { return 0 }

        let sorted = samples.sorted { $0.date < $1.date }
        let baseTime = sorted[0].date.timeIntervalSinceReferenceDate

        let n = Double(sorted.count)
        var sumX: Double = 0, sumY: Double = 0, sumXY: Double = 0, sumX2: Double = 0

        for sample in sorted {
            let x = (sample.date.timeIntervalSinceReferenceDate - baseTime) / 3600.0
            let y = sample.mgdl
            sumX += x
            sumY += y
            sumXY += x * y
            sumX2 += x * x
        }

        let denominator = n * sumX2 - sumX * sumX
        guard abs(denominator) > 1e-10 else { return 0 }

        return (n * sumXY - sumX * sumY) / denominator
    }

    private static func filterFastingReadings(
        glucose: [RegressionGlucoseSample],
        carbs: [RegressionCarbEntry],
        fastingHours: Double
    ) -> [RegressionGlucoseSample] {
        let fastingWindow = fastingHours * 3600
        return glucose.filter { sample in
            !carbs.contains { carb in
                let timeSinceCarb = sample.date.timeIntervalSince(carb.date)
                return timeSinceCarb >= 0 && timeSinceCarb < fastingWindow
            }
        }
    }

    private static func findClosestGlucose(to date: Date, in samples: [RegressionGlucoseSample], maxOffset: TimeInterval) -> Double? {
        let closest = samples
            .filter { abs($0.date.timeIntervalSince(date)) <= maxOffset }
            .min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        return closest?.mgdl
    }

    private static func findScheduleValue(at timeOfDay: TimeInterval, in schedule: [(TimeInterval, Double)]) -> Double {
        guard !schedule.isEmpty else { return 1.0 }
        let sorted = schedule.sorted { $0.0 < $1.0 }
        var active = sorted[0].1
        for entry in sorted {
            if entry.0 <= timeOfDay {
                active = entry.1
            } else {
                break
            }
        }
        return active
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let count = sorted.count
        if count == 0 { return 0 }
        if count % 2 == 0 {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        }
        return sorted[count / 2]
    }
}
