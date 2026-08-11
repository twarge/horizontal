import Foundation

struct SchematicDisplayOptions: Codable, Equatable, Hashable {
    var grid = true
    var origin = true
    var frame = true
    var drawing = true
    var symbols = true
    var blockSymbols = true
    var nets = true
    var netLabels = true
    var junctions = true
    var netTies = true
    var buses = true
    var power = true
    var text = true
    var scaleBar = false
    var coordinates = true

    mutating func showAll() {
        grid = true
        origin = true
        frame = true
        drawing = true
        symbols = true
        blockSymbols = true
        nets = true
        netLabels = true
        junctions = true
        netTies = true
        buses = true
        power = true
        text = true
        scaleBar = false
        coordinates = true
    }

    mutating func logicalOnly() {
        grid = true
        origin = false
        frame = false
        drawing = false
        symbols = true
        blockSymbols = true
        nets = true
        netLabels = true
        junctions = true
        netTies = true
        buses = true
        power = true
        text = false
        scaleBar = false
        coordinates = true
    }

    mutating func artworkOnly() {
        grid = true
        origin = false
        frame = true
        drawing = true
        symbols = true
        blockSymbols = true
        nets = false
        netLabels = false
        junctions = false
        netTies = false
        buses = false
        power = false
        text = true
        scaleBar = false
        coordinates = true
    }

    mutating func labelsOnly() {
        grid = true
        origin = false
        frame = false
        drawing = false
        symbols = false
        blockSymbols = false
        nets = true
        netLabels = true
        junctions = false
        netTies = false
        buses = true
        power = true
        text = false
        scaleBar = false
        coordinates = true
    }

    mutating func cleanView() {
        showAll()
        origin = false
        scaleBar = false
        coordinates = false
    }
}
