import CryptoKit
import Foundation
import Testing

@testable import LuloImaging

/// Ensures the owner's approved smaller JPEG retains its shooting, GPS, altitude, timezone, and full-resolution data.
@Test
func realPhotoMetadataAndDecode() throws {
    let url = try #require(
        Bundle.module.url(forResource: "DSCF2143-LR-light", withExtension: "jpg", subdirectory: "Fixtures"))
    let before = SHA256.hash(data: try Data(contentsOf: url))
    let details = try ImageLoader.details(at: url)
    let fields = Dictionary(uniqueKeysWithValues: details.groups.flatMap(\.fields).map { ($0.name, $0.value) })
    #expect(details.width == 4085)
    #expect(details.height == 6128)
    #expect(fields["Make"] == "FUJIFILM")
    #expect(fields["Model"] == "X-S20")
    #expect(fields["Lens"] == "SIGMA 18-50mm F2.8 DC DN | Contemporary 021")
    #expect(fields["Exposure"] == "1/400 s, f/14")
    #expect(fields["ISO Speed Rating"] == "640")
    #expect(fields["Focal Length"] == "28.3 mm")
    #expect(fields["Focal Length 35mm"] == "42 mm")
    #expect(fields["Exposure Bias"] == "0")
    #expect(fields["Flash"] == "0")
    #expect(fields["Exposure Program"] == "1")
    #expect(fields["Metering Mode"] == "5")
    #expect(fields["Date Time Captured"] == "2025/03/17 16:41:58")
    #expect(details.entry.capturedAt == ImageLoader.captureDate("2025:03:17 07:41:58", offset: "+00:00"))
    #expect(fields["Altitude"] == "836 m")
    let coordinates = try #require(fields["GPS"]).components(separatedBy: ", ")
    try #require(coordinates.count == 2)
    let latitude = try #require(Double(coordinates[0].dropLast()))
    let longitude = try #require(Double(coordinates[1].dropLast()))
    #expect(coordinates[0].hasSuffix("N"))
    #expect(coordinates[1].hasSuffix("E"))
    #expect(abs(latitude - (35 + 31.3430333 / 60)) < 0.000001)
    #expect(abs(longitude - (138 + 44.7277833 / 60)) < 0.000001)
    let image = try ImageLoader.decode(at: url)
    #expect(image.width == details.width)
    #expect(image.height == details.height)
    #expect(image.colorSpace != nil)
    #expect(SHA256.hash(data: try Data(contentsOf: url)) == before)
}
