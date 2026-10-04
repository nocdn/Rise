import XCTest
import AppKit
@testable import Rise

/// The native download flight must move exactly like Playgrounds/download-flight.html.
/// Reference samples come from the playground stepped at 120 Hz, throwing at its
/// archive button at (10, 601, 28, 28); icon values are rounded as CSS serializes them.
final class DownloadFlightTests: XCTestCase {
    struct Sample { var step: Int; var icon: [Double]?; var lid: Double; var recoil: [Double] }
    let archive = CGRect(x: 10, y: 601, width: 28, height: 28)

    func testThrowFromAboveMatchesPlayground() { verify(from: CGPoint(x: 760, y: 140), against: fromAbove) }
    func testLowThrowMatchesPlayground() { verify(from: CGPoint(x: 300, y: 590), against: lowThrow) }
    func verify(from origin: CGPoint, against samples: [Sample]) {
        var model = DownloadFlightModel()
        model.launch(from: origin, into: archive)
        var expected = samples[...]
        for step in 1...120 {
            model.step(1.0/120)
            guard let sample = expected.first, sample.step == step else { continue }
            expected.removeFirst()
            // The playground samples a fully faded icon just before removing it.
            if let icon = sample.icon, icon[3] > 0 {
                let flight = model.flights.first
                XCTAssertEqual(flight?.position.x ?? .nan, icon[0], accuracy: 0.005, "x at step \(step)")
                XCTAssertEqual(flight?.position.y ?? .nan, icon[1], accuracy: 0.005, "y at step \(step)")
                XCTAssertEqual(flight?.scale ?? .nan, icon[2], accuracy: 1e-5, "scale at step \(step)")
                XCTAssertEqual(flight?.opacity ?? .nan, icon[3], accuracy: 1e-5, "opacity at step \(step)")
            } else { XCTAssertTrue(model.flights.isEmpty, "The download has dropped in by step \(step)") }
            XCTAssertEqual(model.lid.value, sample.lid, accuracy: 1e-9, "lid at step \(step)")
            XCTAssertEqual(model.hinge, .left)
            let pose = model.pose
            XCTAssertEqual(pose.offset.x, sample.recoil[0], accuracy: 1e-9, "recoil x at step \(step)")
            XCTAssertEqual(pose.offset.y, sample.recoil[1], accuracy: 1e-9, "recoil y at step \(step)")
            XCTAssertEqual(pose.rotation, sample.recoil[2], accuracy: 1e-9, "tilt at step \(step)")
        }
        XCTAssertTrue(expected.isEmpty)
    }

    func testArchiveSettlesAndTrayLeavesAfterAShortHold() {
        var model = DownloadFlightModel(usesTray: true)
        model.launch(from: CGPoint(x: 600, y: 200), into: archive)
        var landed: Double?, overshoot = 0.0
        while !model.isIdle && model.time < 5 {
            model.step(1.0/120)
            overshoot = max(overshoot, model.tray.value)
            if landed == nil && model.flights.isEmpty { landed = model.time }
            if let landed, model.time < landed+DownloadMotion.trayHold { XCTAssertGreaterThan(model.tray.value, 0.9) }
        }
        XCTAssertTrue(model.isIdle && model.time < 3, "Settles soon after landing: \(model.time)")
        XCTAssertGreaterThan(overshoot, 1.001, "The tile springs in with a slight overshoot")
        XCTAssertLessThan(overshoot, 1.06)
    }

    func testDownloadsAreNumberedLikeFinder() {
        let folder = URL(fileURLWithPath: "/tmp/downloads")
        var taken: Set<String> = ["/tmp/downloads/report.pdf", "/tmp/downloads/report 2.pdf", "/tmp/downloads/notes"]
        func name(_ suggested: String) -> String {
            let url = BrowserController.downloadDestination(for: suggested, in: folder) { taken.contains($0.path) }
            taken.insert(url.path); return url.lastPathComponent
        }
        XCTAssertEqual(name("report.pdf"), "report 3.pdf")
        XCTAssertEqual(name("notes"), "notes 2")
        XCTAssertEqual(name("fresh.zip"), "fresh.zip")
        XCTAssertEqual(name("../etc/passwd"), "..-etc-passwd")
        XCTAssertEqual(name("  "), "Download")
    }

    let fromAbove: [Sample] = [
        Sample(step: 4, icon: [759.116, 139.798, 0.600595, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 8, icon: [756.266, 139.155, 0.768681, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 12, icon: [751.131, 138.033, 0.903943, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 16, icon: [743.362, 136.423, 0.982712, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 20, icon: [732.58, 134.368, 1.01568, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 24, icon: [718.377, 131.981, 1.02182, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 28, icon: [700.319, 129.48, 1.01666, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 32, icon: [677.954, 127.225, 1.00931, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 36, icon: [650.813, 125.77, 1.00367, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 40, icon: [618.428, 125.929, 1.00049, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 44, icon: [580.341, 128.849, 0.999234, 1], lid: 0.08145357607980735, recoil: [0, 0, 0]),
        Sample(step: 48, icon: [536.132, 136.103, 0.999054, 1], lid: 0.44277911525518077, recoil: [0, 0, 0]),
        Sample(step: 52, icon: [485.435, 149.8, 0.999308, 1], lid: 0.7621123264735422, recoil: [0, 0, 0]),
        Sample(step: 56, icon: [427.975, 172.706, 0.999627, 1], lid: 0.9418965649338835, recoil: [0, 0, 0]),
        Sample(step: 60, icon: [363.605, 208.375, 0.999861, 1], lid: 1.0126032319939104, recoil: [0, 0, 0]),
        Sample(step: 64, icon: [292.341, 261.291, 0.999989, 1], lid: 1.0261448331678296, recoil: [0, 0, 0]),
        Sample(step: 68, icon: [214.41, 336.997, 0.907812, 1], lid: 1.0191892646683598, recoil: [0, 0, 0]),
        Sample(step: 72, icon: [130.297, 442.222, 0.680972, 1], lid: 1.0096367994779887, recoil: [0, 0, 0]),
        Sample(step: 76, icon: [40.7776, 584.97, 0.320892, 1], lid: 1.003244489510259, recoil: [0, 0, 0]),
        Sample(step: 80, icon: [24, 615.667, 0.240004, 0.545462], lid: 1.0002562329915883, recoil: [-0.6991133394820851, 1.3067823385468238, -0.7767925994245387]),
        Sample(step: 84, icon: [24, 615.667, 0.240001, 0], lid: 0.9993664946962688, recoil: [-0.8472514358696003, 1.5836820014377682, -0.9413904842995555]),
        Sample(step: 88, icon: nil, lid: 0.8390915255215445, recoil: [-0.6956468009748057, 1.3003026863339775, -0.7729408899720062]),
        Sample(step: 92, icon: nil, lid: 0.4655145095399773, recoil: [-0.441752976644936, 0.8257244645163614, -0.4908366407165957]),
        Sample(step: 96, icon: nil, lid: 0.17985745077190732, recoil: [-0.20586746267754658, 0.38480736829848333, -0.22874162519727415]),
        Sample(step: 100, icon: nil, lid: 0.03228866408281412, recoil: [-0.040254997299851554, 0.07524462277985779, -0.04472777477761307]),
        Sample(step: 104, icon: nil, lid: 0, recoil: [0.04872353147788499, -0.0910740030423377, 0.054137257197649835]),
        Sample(step: 108, icon: nil, lid: 0, recoil: [0.07811439212476658, -0.1460113864950532, 0.08679376902751834]),
        Sample(step: 112, icon: nil, lid: 0, recoil: [0.07158866949409357, -0.13381350869982153, 0.07954296610454838]),
        Sample(step: 116, icon: nil, lid: 0, recoil: [0.0497593157575723, -0.09301009055032693, 0.05528812861952478]),
        Sample(step: 120, icon: nil, lid: 0, recoil: [0.02639533089743441, -0.049338140597373736, 0.0293281454415938]),
    ]
    let lowThrow: [Sample] = [
        Sample(step: 4, icon: [299.498, 589.573, 0.600595, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 8, icon: [297.813, 588.161, 0.768681, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 12, icon: [294.633, 585.583, 0.903943, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 16, icon: [289.566, 581.707, 0.982712, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 20, icon: [282.117, 576.505, 1.01568, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 24, icon: [271.657, 570.137, 1.02182, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 28, icon: [257.38, 563.074, 1.01666, 1], lid: 0, recoil: [0, 0, 0]),
        Sample(step: 32, icon: [238.254, 556.272, 1.00931, 1], lid: 0.25128138376153386, recoil: [0, 0, 0]),
        Sample(step: 36, icon: [212.96, 551.39, 1.00367, 1], lid: 0.618702153478843, recoil: [0, 0, 0]),
        Sample(step: 40, icon: [179.825, 551.074, 1.00049, 1], lid: 0.868851124104627, recoil: [0, 0, 0]),
        Sample(step: 44, icon: [136.751, 559.277, 0.976323, 1], lid: 0.9874731065738223, recoil: [0, 0, 0]),
        Sample(step: 48, icon: [81.1635, 581.586, 0.693778, 1], lid: 1.023740002685003, recoil: [0, 0, 0]),
        Sample(step: 52, icon: [24, 615.667, 0.239834, 0.900671], lid: 1.0237343490438737, recoil: [-0.7664973495221966, 0.5109540408977993, -0.8516637216913293]),
        Sample(step: 56, icon: [24, 615.667, 0.23991, 0.345116], lid: 1.0141825190025575, recoil: [-1.456432191968313, 0.9708708245941544, -1.6182579910759032]),
        Sample(step: 60, icon: nil, lid: 0.9818723527315328, recoil: [-1.4019932792354164, 0.9345813547606378, -1.5577703102615745]),
        Sample(step: 64, icon: nil, lid: 0.6541724150925773, recoil: [-1.0092340916948161, 0.6727645407837817, -1.121371212994241]),
        Sample(step: 68, icon: nil, lid: 0.30467904371428284, recoil: [-0.5590362723303601, 0.37265861719378107, -0.6211514137004006]),
        Sample(step: 72, icon: nil, lid: 0.0900795568945604, recoil: [-0.19947300117267402, 0.13297050024076792, -0.22163666796963827]),
        Sample(step: 76, icon: nil, lid: 0, recoil: [0.023045195351020724, -0.015362134905258742, 0.025605772612245028]),
        Sample(step: 80, icon: nil, lid: 0, recoil: [0.12240795886736658, -0.08159824852665241, 0.13600884318596287]),
        Sample(step: 84, icon: nil, lid: 0, recoil: [0.1374302333783036, -0.09161223209701173, 0.15270025930922632]),
        Sample(step: 88, icon: nil, lid: 0, recoil: [0.10857285102570072, -0.07237564095682505, 0.12063650113966758]),
        Sample(step: 92, icon: nil, lid: 0, recoil: [0.06648551280234283, -0.04431984200427518, 0.07387279200260329]),
        Sample(step: 96, icon: nil, lid: 0, recoil: [0.029148297698611724, -0.019430517931577573, 0.032386997442902084]),
        Sample(step: 100, icon: nil, lid: 0, recoil: [0.0038340471580326847, -0.0025558103881386345, 0.004260052397814228]),
        Sample(step: 104, icon: nil, lid: 0, recoil: [-0.009159519296695213, 0.006105818109149557, -0.010177243662994597]),
        Sample(step: 108, icon: nil, lid: 0, recoil: [-0.012916350441286296, 0.008610155606854037, -0.014351500490318067]),
        Sample(step: 112, icon: nil, lid: 0, recoil: [-0.011314879768660477, 0.007542600823960723, -0.012572088631844967]),
        Sample(step: 116, icon: nil, lid: 0, recoil: [-0.007594658059879435, 0.005062667506093011, -0.008438508955421602]),
        Sample(step: 120, icon: nil, lid: 0, recoil: [-0.00384467318342659, 0.0025628937924283587, -0.004271859092696228]),
    ]
}
