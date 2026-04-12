import XCTest
@testable import Somewhere

final class SomewhereTests: XCTestCase {

    // MARK: - Deal Model Tests

    func testDealIsActiveNow() {
        let calendar = Calendar.current
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)

        // Create a deal active in the current hour
        let startHour = max(0, hour - 1)
        let endHour = min(23, hour + 2)

        let deal = makeDeal(
            days: [DayOfWeek.today],
            startTime: String(format: "%02d:00", startHour),
            endTime: String(format: "%02d:00", endHour)
        )

        XCTAssertTrue(deal.isActiveNow, "Deal should be active now")
    }

    func testDealIsNotActiveWrongDay() {
        let today = DayOfWeek.today
        let tomorrow = DayOfWeek.allCases[(DayOfWeek.allCases.firstIndex(of: today)! + 1) % 7]

        let deal = makeDeal(days: [tomorrow], startTime: "00:00", endTime: "23:59")
        XCTAssertFalse(deal.isActiveNow, "Deal should not be active on wrong day")
    }

    func testDealFormattedDays() {
        let weekdayDeal = makeDeal(days: [.monday, .tuesday, .wednesday, .thursday, .friday])
        XCTAssertEqual(weekdayDeal.formattedDays, "Weekdays")

        let weekendDeal = makeDeal(days: [.saturday, .sunday])
        XCTAssertEqual(weekendDeal.formattedDays, "Weekends")

        let allDaysDeal = makeDeal(days: DayOfWeek.allCases)
        XCTAssertEqual(allDaysDeal.formattedDays, "Every Day")
    }

    func testDealFormattedTimeRange() {
        let deal = makeDeal(startTime: "16:00", endTime: "19:00")
        XCTAssertEqual(deal.formattedTimeRange, "4 PM – 7 PM")
    }

    // MARK: - Search Filter Tests

    func testSearchFilterDefault() {
        let filter = SearchFilter.default
        XCTAssertFalse(filter.isFiltered)
        XCTAssertEqual(filter.activeFilterCount, 0)
    }

    func testSearchFilterActiveCount() {
        var filter = SearchFilter.default
        filter.categories = [.drinks]
        filter.showOnlyVerified = true
        XCTAssertEqual(filter.activeFilterCount, 2)
        XCTAssertTrue(filter.isFiltered)
    }

    func testFilterMatchesDealCategory() {
        var filter = SearchFilter.default
        filter.categories = [.drinks]

        let drinksDeal = makeDeal(category: .drinks)
        let foodDeal = makeDeal(category: .food)

        XCTAssertTrue(filter.matches(deal: drinksDeal))
        XCTAssertFalse(filter.matches(deal: foodDeal))
    }

    func testFilterMatchesDealDays() {
        var filter = SearchFilter.default
        filter.selectedDays = [.monday]

        let mondayDeal = makeDeal(days: [.monday, .tuesday])
        let wednesdayDeal = makeDeal(days: [.wednesday])

        XCTAssertTrue(filter.matches(deal: mondayDeal))
        XCTAssertFalse(filter.matches(deal: wednesdayDeal))
    }

    // MARK: - PVA Grid Tests

    func testPVACellIdConsistency() async {
        let service = PVAService.shared
        let coord = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let id1 = await service.cellId(for: coord)
        let id2 = await service.cellId(for: coord)
        XCTAssertEqual(id1, id2, "Same coordinate should produce same cell ID")
    }

    func testPVAGridCoverage() async {
        let service = PVAService.shared
        let coord = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let cells = await service.gridCellIds(for: coord, radiusMiles: 1.0)
        XCTAssertFalse(cells.isEmpty, "Should find grid cells for a 1-mile radius")
        XCTAssertGreaterThan(cells.count, 3, "Should have multiple cells for 1-mile radius")
    }

    // MARK: - Photo Scan Tests

    func testDealTextExtraction() {
        let service = PhotoScanService.shared
        let text = """
        Happy Hour
        Monday-Friday 4pm-7pm
        $2 Draft Beers
        Half-price appetizers
        """
        let result = service.extractDeals(from: text)
        XCTAssertFalse(result.extractedDeals.isEmpty, "Should extract at least one deal")
    }

    func testTimeExtraction() {
        let service = PhotoScanService.shared
        let text = "Happy Hour every day 3pm-6pm"
        let result = service.extractDeals(from: text)

        if let deal = result.extractedDeals.first {
            XCTAssertEqual(deal.suggestedStartTime, "15:00")
            XCTAssertEqual(deal.suggestedEndTime, "18:00")
        }
    }

    // MARK: - String Extensions Tests

    func testEmailValidation() {
        XCTAssertTrue("test@example.com".isValidEmail)
        XCTAssertTrue("user.name+tag@domain.co.uk".isValidEmail)
        XCTAssertFalse("notanemail".isValidEmail)
        XCTAssertFalse("@domain.com".isValidEmail)
        XCTAssertFalse("user@".isValidEmail)
    }

    func testPasswordValidation() {
        XCTAssertTrue("password123".isValidPassword)
        XCTAssertFalse("short".isValidPassword)
        XCTAssertTrue("12345678".isValidPassword)
    }

    func testFormattedTime() {
        XCTAssertEqual("16:00".formattedTime, "4 PM")
        XCTAssertEqual("19:30".formattedTime, "7:30 PM")
        XCTAssertEqual("00:00".formattedTime, "12 AM")
        XCTAssertEqual("12:00".formattedTime, "12 PM")
    }

    // MARK: - Venue Tests

    func testVenueDistanceCalculation() {
        let venue = makeVenue(latitude: 37.7749, longitude: -122.4194)
        let userLocation = CLLocation(latitude: 37.7750, longitude: -122.4195)
        let distance = venue.distanceMiles(from: userLocation)
        XCTAssertLessThan(distance, 0.1, "Very close venues should be less than 0.1 miles")
    }

    // MARK: - Helpers

    private func makeDeal(
        category: DealCategory = .drinks,
        days: [DayOfWeek] = [.monday, .tuesday, .wednesday, .thursday, .friday],
        startTime: String = "16:00",
        endTime: String = "19:00"
    ) -> Deal {
        Deal(
            id: UUID().uuidString,
            venueId: "venue1",
            venueName: "Test Bar",
            venueAddress: "123 Main St",
            venueLatitude: 37.7749,
            venueLongitude: -122.4194,
            title: "Happy Hour",
            description: "Test deal",
            category: category,
            days: days,
            startTime: startTime,
            endTime: endTime,
            source: .manual,
            status: .active,
            isVerified: true,
            upvotes: 0,
            downvotes: 0,
            reportCount: 0,
            imageURL: nil,
            sourceURL: nil,
            createdBy: "user1",
            createdByName: "Test User",
            createdAt: .init(),
            updatedAt: .init()
        )
    }

    private func makeVenue(latitude: Double, longitude: Double) -> Venue {
        Venue(
            id: UUID().uuidString,
            name: "Test Bar",
            address: "123 Main St",
            city: "San Francisco",
            state: "CA",
            zipCode: "94102",
            latitude: latitude,
            longitude: longitude,
            placeId: "test_place_id",
            phone: nil, website: nil,
            category: .bar,
            isPermanentlyClosed: false,
            scanStatus: .scanned,
            lastScanned: nil, lastVerified: nil,
            dealCount: 1,
            rating: 4.5, priceLevel: 2,
            photoReference: nil,
            createdAt: .init(), updatedAt: .init(),
            createdBy: nil, searchCellIds: []
        )
    }
}

import CoreLocation
