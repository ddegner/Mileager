import Foundation

public enum DistanceCalculator {
    private static let earthRadiusMeters = 6_371_000.0

    public static func distanceMeters(from first: Coordinate, to second: Coordinate) -> Double {
        let lat1 = first.latitude * .pi / 180
        let lat2 = second.latitude * .pi / 180
        let deltaLat = (second.latitude - first.latitude) * .pi / 180
        let deltaLon = (second.longitude - first.longitude) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusMeters * c
    }

    public static func routeDistanceMeters(
        samples: [LocationSample],
        maxAccuracy: Double = 150,
        maxSegmentSpeedMetersPerSecond: Double = 60
    ) -> Double {
        let usable = samples
            .filter { $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= maxAccuracy }
            .sorted { $0.timestamp < $1.timestamp }

        guard usable.count > 1 else { return 0 }

        return zip(usable, usable.dropFirst()).reduce(0) { total, pair in
            let first = Coordinate(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let second = Coordinate(latitude: pair.1.latitude, longitude: pair.1.longitude)
            let segment = distanceMeters(from: first, to: second)
            let elapsed = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            guard segment.isFinite,
                  elapsed > 0,
                  segment / elapsed <= maxSegmentSpeedMetersPerSecond else {
                return total
            }
            return total + segment
        }
    }

    /// Perpendicular distance in meters from `point` to the segment
    /// (`lineStart`, `lineEnd`) using a local equirectangular projection.
    /// Degenerate (zero-length) segments fall back to the distance to
    /// `lineStart`. Shared by route simplification and route correction.
    package static func perpendicularDistanceMeters(
        from point: Coordinate,
        toSegmentFrom lineStart: Coordinate,
        to lineEnd: Coordinate
    ) -> Double {
        let lineDistance = distanceMeters(from: lineStart, to: lineEnd)
        guard lineDistance > 0 else {
            return distanceMeters(from: point, to: lineStart)
        }

        let referenceLatitude = ((lineStart.latitude + lineEnd.latitude) / 2) * .pi / 180
        let metersPerDegreeLatitude = 111_132.0
        let metersPerDegreeLongitude = max(cos(referenceLatitude) * 111_320.0, 0.000_001)

        let x0 = (point.longitude - lineStart.longitude) * metersPerDegreeLongitude
        let y0 = (point.latitude - lineStart.latitude) * metersPerDegreeLatitude
        let x2 = (lineEnd.longitude - lineStart.longitude) * metersPerDegreeLongitude
        let y2 = (lineEnd.latitude - lineStart.latitude) * metersPerDegreeLatitude

        let numerator = abs(y2 * x0 - x2 * y0)
        let denominator = sqrt(y2 * y2 + x2 * x2)
        guard denominator > 0 else {
            return distanceMeters(from: point, to: lineStart)
        }
        return numerator / denominator
    }
}

public enum RouteSimplifier {
    public static func simplifiedPolyline(samples: [LocationSample], toleranceMeters: Double) -> String? {
        let coordinates = samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { Coordinate(latitude: $0.latitude, longitude: $0.longitude) }

        guard coordinates.count >= 2 else { return nil }
        let simplified = rdp(coordinates, toleranceMeters: toleranceMeters)
        return EncodedPolyline.encode(simplified)
    }

    public static func rdp(_ points: [Coordinate], toleranceMeters: Double) -> [Coordinate] {
        guard points.count > 2 else { return points }

        var maxDistance = 0.0
        var index = 0
        for pointIndex in 1..<(points.count - 1) {
            let distance = DistanceCalculator.perpendicularDistanceMeters(
                from: points[pointIndex],
                toSegmentFrom: points[0],
                to: points[points.count - 1]
            )
            if distance > maxDistance {
                index = pointIndex
                maxDistance = distance
            }
        }

        if maxDistance > toleranceMeters {
            let left = rdp(Array(points[0...index]), toleranceMeters: toleranceMeters)
            let right = rdp(Array(points[index...]), toleranceMeters: toleranceMeters)
            return Array(left.dropLast()) + right
        }

        return [points[0], points[points.count - 1]]
    }

}

public enum EncodedPolyline {
    public static func encode(_ coordinates: [Coordinate]) -> String {
        var previousLatitude = 0
        var previousLongitude = 0
        var result = ""

        for coordinate in coordinates {
            let latitude = Int((coordinate.latitude * 1e5).rounded())
            let longitude = Int((coordinate.longitude * 1e5).rounded())
            result += encodeSigned(latitude - previousLatitude)
            result += encodeSigned(longitude - previousLongitude)
            previousLatitude = latitude
            previousLongitude = longitude
        }

        return result
    }

    public static func encodeSegments(_ segments: [[Coordinate]]) -> String {
        segments.map(encode).joined(separator: "\n")
    }

    public static func decode(_ polyline: String) -> [Coordinate]? {
        let bytes = Array(polyline.utf8)
        var coordinates: [Coordinate] = []
        var index = 0
        var latitude = 0
        var longitude = 0

        while index < bytes.count {
            guard let latitudeDelta = decodeNextValue(bytes: bytes, index: &index),
                  let longitudeDelta = decodeNextValue(bytes: bytes, index: &index) else {
                return nil
            }

            latitude += latitudeDelta
            longitude += longitudeDelta
            coordinates.append(Coordinate(
                latitude: Double(latitude) / 1e5,
                longitude: Double(longitude) / 1e5
            ))
        }

        return coordinates
    }

    public static func decodeSegments(_ value: String) -> [[Coordinate]]? {
        var result: [[Coordinate]] = []
        for part in value.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            guard let decoded = decode(part) else { return nil }
            result.append(decoded)
        }
        return result
    }

    private static func encodeSigned(_ value: Int) -> String {
        var shifted = value << 1
        if value < 0 {
            shifted = ~shifted
        }

        var output = ""
        while shifted >= 0x20 {
            output.unicodeScalars.append(UnicodeScalar((0x20 | (shifted & 0x1f)) + 63)!)
            shifted >>= 5
        }
        output.unicodeScalars.append(UnicodeScalar(shifted + 63)!)
        return output
    }

    private static func decodeNextValue(bytes: [UInt8], index: inout Int) -> Int? {
        var shift = 0
        var result = 0

        while index < bytes.count {
            let byte = Int(bytes[index]) - 63
            guard byte >= 0 else { return nil }
            index += 1
            result |= (byte & 0x1f) << shift
            shift += 5

            if byte < 0x20 {
                return (result & 1) == 1 ? ~(result >> 1) : (result >> 1)
            }
        }

        return nil
    }
}
