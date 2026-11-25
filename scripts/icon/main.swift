// Writes an Icon Composer file from AppIconDrawing: icon.json and one image per layer.
// Run through scripts/render-icon.sh, which compiles this with that drawing.
//
//   render-icon <path/to/AppIcon.icon> [design number]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: render-icon <AppIcon.icon> [design number]\n".data(using: .utf8)!)
    exit(2)
}
var design = AppIconDrawing.shipped
if arguments.count >= 3 {
    guard let number = Int(arguments[2]), let chosen = AppIconDrawing.Design(rawValue: number) else {
        let numbers = AppIconDrawing.Design.allCases.map { "\($0.rawValue) \($0.title)" }.joined(separator: ", ")
        FileHandle.standardError.write("error: the design is one of \(numbers)\n".data(using: .utf8)!)
        exit(2)
    }
    design = chosen
}

let icon = URL(fileURLWithPath: arguments[1])
let assets = icon.appendingPathComponent("Assets")
let files = FileManager.default
// Start the assets over, so no image from another design is left behind.
try? files.removeItem(at: assets)
try files.createDirectory(at: assets, withIntermediateDirectories: true)

for layer in design.layers {
    let output = assets.appendingPathComponent("\(layer.name).png")
    guard let image = AppIconDrawing.image(of: layer),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("couldn't draw \(layer.name)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("couldn't write \(output.path)") }
}
try AppIconDrawing.iconJSON(for: design).write(
    to: icon.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Drew design \(design.rawValue), \(design.title), into \(icon.path)")
