import Foundation
import CoreImage
import AppKit
let text = CommandLine.arguments[1], out = CommandLine.arguments[2]
let f = CIFilter(name: "CIQRCodeGenerator")!
f.setValue(Data(text.utf8), forKey: "inputMessage")
f.setValue("M", forKey: "inputCorrectionLevel")
let img = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
let rep = NSBitmapImageRep(ciImage: img)
let white = NSImage(size: NSSize(width: rep.pixelsWide + 96, height: rep.pixelsHigh + 96))
white.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: white.size).fill()
NSImage(cgImage: rep.cgImage!, size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)).draw(at: NSPoint(x: 48, y: 48), from: .zero, operation: .copy, fraction: 1)
white.unlockFocus()
let png = NSBitmapImageRep(data: white.tiffRepresentation!)!.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
