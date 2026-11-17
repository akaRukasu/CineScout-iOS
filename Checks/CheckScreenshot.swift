import AppKit

guard CommandLine.arguments.count == 2,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let bitmap = NSBitmapImageRep(data: data) else { exit(1) }
var visible = 0
var samples = 0
for y in stride(from: bitmap.pixelsHigh / 8, to: bitmap.pixelsHigh * 7 / 8, by: 28) {
    for x in stride(from: bitmap.pixelsWide / 10, to: bitmap.pixelsWide * 9 / 10, by: 28) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        samples += 1
        if max(color.redComponent, max(color.greenComponent, color.blueComponent)) > 0.07 { visible += 1 }
    }
}
guard samples > 0, Double(visible) / Double(samples) > 0.02 else {
    print("The simulator has not rendered the content yet.")
    exit(1)
}
