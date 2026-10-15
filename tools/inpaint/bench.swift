// swiftc -O bench.swift -o bench && ./bench models/MIGAN_512.mlpackage models/MIGAN_256.mlpackage
import CoreML
import Foundation

func ms(_ f: () throws -> Void) rethrows -> Double {
    let t = DispatchTime.now().uptimeNanoseconds
    try f()
    return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
}
func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }

let units: [(String, MLComputeUnits)] = [("cpuOnly", .cpuOnly), ("cpuAndGPU", .cpuAndGPU), ("cpuAndNE", .cpuAndNeuralEngine), ("all", .all)]
print("| model | size | compute units | compile ms | load ms | median ms | p90 ms |")
print("|---|---|---|---|---|---|---|")
for path in CommandLine.arguments.dropFirst() {
    let url = URL(fileURLWithPath: path)
    let name = url.deletingPathExtension().lastPathComponent
    let res = name.hasSuffix("256") ? 256 : 512
    var compiled: URL!
    let compileMs = try ms { compiled = try MLModel.compileModel(at: url) }
    // synthetic input: smooth image * mask, mask 1=known, 0=hole (text-like rectangle)
    let x = try MLMultiArray(shape: [1, 4, NSNumber(value: res), NSNumber(value: res)], dataType: .float32)
    let p = x.dataPointer.bindMemory(to: Float.self, capacity: 4 * res * res)
    let hw = res * res
    for y in 0..<res { for c in 0..<res {
        let hole = y > res * 2 / 5 && y < res * 3 / 5 && c > res / 5 && c < res * 4 / 5
        let m: Float = hole ? 0 : 1
        p[y * res + c] = m - 0.5
        for ch in 0..<3 { p[(1 + ch) * hw + y * res + c] = Float(sin(Double(y + c * (ch + 1)) / 40)) * m }
    } }
    let input = try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: x)])
    let size = (try? FileManager.default.subpathsOfDirectory(atPath: path).reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: path + "/" + $1)[.size] as? Int) ?? 0) }) ?? 0
    for (uname, u) in units {
        let cfg = MLModelConfiguration(); cfg.computeUnits = u
        var model: MLModel!
        let loadMs: Double
        do { loadMs = try ms { model = try MLModel(contentsOf: compiled, configuration: cfg) } } catch { print("| \(name) | | \(uname) | \(error) |"); continue }
        do {
            for _ in 0..<3 { _ = try model.prediction(from: input) }
            var t: [Double] = []
            for _ in 0..<20 { t.append(try ms { _ = try model.prediction(from: input) }) }
            print(String(format: "| %@ | %.1f MB | %@ | %.0f | %.0f | %.1f | %.1f |", name, Double(size) / 1e6, uname, compileMs, loadMs, pct(t, 0.5), pct(t, 0.9)))
        } catch { print("| \(name) | | \(uname) | predict failed: \(error) |") }
    }
}
