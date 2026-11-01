// Generates the test archive's images, PDF and video (see scripts/make-test-archive.sh).
// usage: generate <archive folder>

import AppKit
import AVFoundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
func text(_ ctx: CGContext, _ string: String, size: CGFloat, at point: CGPoint, color: CGColor = .white, bold: Bool = true) {
    let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!]))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.textPosition = CGPoint(x: point.x - width / 2, y: point.y) // centered on x
    CTLineDraw(line, ctx)
}
func gradient(_ ctx: CGContext, _ a: CGColor, _ b: CGColor, from: CGPoint, to: CGPoint) {
    ctx.drawLinearGradient(CGGradient(colorsSpace: sRGB, colors: [a, b] as CFArray, locations: [0, 1])!, start: from, end: to, options: [])
}
func save(_ images: [CGImage], _ path: String, _ type: UTType, file: [CFString: Any] = [:], frame: [CFString: Any] = [:]) {
    let url = root.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, images.count, nil)!
    CGImageDestinationSetProperties(dest, file as CFDictionary)
    for image in images { CGImageDestinationAddImage(dest, image, frame as CFDictionary) }
    precondition(CGImageDestinationFinalize(dest), path)
}

// A portrait picture stored sideways with EXIF orientation 6: it's upright only if the orientation is applied.
do {
    let (w, h) = (900, 1200)
    let up = bitmap(w, h)
    gradient(up, color(0.1, 0.5, 0.3), color(0.05, 0.15, 0.35), from: .zero, to: CGPoint(x: 0, y: h))
    up.setFillColor(.white)
    up.move(to: CGPoint(x: 450, y: 1080)); up.addLine(to: CGPoint(x: 250, y: 820)); up.addLine(to: CGPoint(x: 380, y: 820))
    up.addLine(to: CGPoint(x: 380, y: 520)); up.addLine(to: CGPoint(x: 520, y: 520)); up.addLine(to: CGPoint(x: 520, y: 820))
    up.addLine(to: CGPoint(x: 650, y: 820)); up.closePath(); up.fillPath()
    text(up, "This side up", size: 72, at: CGPoint(x: 450, y: 380))
    text(up, "Stored sideways, EXIF orientation 6", size: 34, at: CGPoint(x: 450, y: 300), bold: false)
    let stored = bitmap(h, w)
    stored.translateBy(x: CGFloat(h), y: 0)
    stored.rotate(by: .pi / 2)
    stored.draw(up.makeImage()!, in: CGRect(x: 0, y: 0, width: w, height: h))
    save([stored.makeImage()!], "Images/rotated (EXIF orientation 6).jpg", .jpeg,
         frame: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.9])
}

// A PNG with transparency.
do {
    let ctx = bitmap(800, 600)
    ctx.setFillColor(color(0.95, 0.3, 0.4, 0.85)); ctx.fillEllipse(in: CGRect(x: 120, y: 100, width: 400, height: 400))
    ctx.setFillColor(color(0.2, 0.5, 1, 0.6)); ctx.fillEllipse(in: CGRect(x: 300, y: 120, width: 380, height: 380))
    text(ctx, "Transparent PNG", size: 56, at: CGPoint(x: 400, y: 40), color: color(0.2, 0.2, 0.2))
    save([ctx.makeImage()!], "Images/transparent.png", .png)
}

// A 32-pixel image, which should stay small rather than be blown up.
do {
    let ctx = bitmap(32, 32)
    ctx.setFillColor(color(1, 0.6, 0)); ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    ctx.setFillColor(color(0.3, 0.1, 0.5)); ctx.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
    save([ctx.makeImage()!], "Images/tiny 32px.png", .png)
}

// An animated GIF: a bouncing ball.
do {
    var frames: [CGImage] = []
    for i in 0..<24 {
        let ctx = bitmap(320, 320)
        ctx.setFillColor(color(0.12, 0.12, 0.18)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        let t = Double(i) / 24
        let y = 40 + 200 * abs(sin(t * .pi))
        ctx.setFillColor(color(1, 0.75, 0.1)); ctx.fillEllipse(in: CGRect(x: 120, y: y, width: 80, height: 80))
        text(ctx, "Animated GIF", size: 26, at: CGPoint(x: 160, y: 12))
        frames.append(ctx.makeImage()!)
    }
    save(frames, "Images/animated.gif", .gif,
         file: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
         frame: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.05]])
}

// A gallery of 30 numbered pictures, portrait and landscape, JPEG and PNG, for the icon view.
for i in 1...30 {
    let landscape = i % 3 == 0
    let (w, h) = landscape ? (1200, 800) : (900, 1200)
    let ctx = bitmap(w, h)
    let hue = CGFloat(i % 10) / 10
    gradient(ctx, NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor,
             NSColor(hue: (hue + 0.3).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.55, alpha: 1).cgColor,
             from: CGPoint(x: 0, y: h), to: .zero)
    text(ctx, "\(i)", size: 260, at: CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2 - 90))
    let isPNG = i % 3 == 0
    save([ctx.makeImage()!], "Images/Gallery/picture-\(i).\(isPNG ? "png" : "jpg")", isPNG ? .png : .jpeg,
         frame: isPNG ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85])
}

// A three-page PDF with text, shapes and a picture.
do {
    let url = root.appendingPathComponent("Documents/Sample Document.pdf")
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: "Rummage Sample Document"] as CFDictionary)!
    let body = """
    This PDF has three pages, so the preview should let you scroll through them. Page one is text, \
    page two has shapes and a table, and page three has a picture.

    Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore \
    et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut \
    aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse \
    cillum dolore eu fugiat nulla pariatur.
    """
    func page(_ title: String, _ draw: (CGContext) -> Void) {
        pdf.beginPDFPage(nil)
        text(pdf, title, size: 30, at: CGPoint(x: 306, y: 720), color: color(0.1, 0.1, 0.1))
        draw(pdf)
        text(pdf, "Rummage test archive", size: 10, at: CGPoint(x: 306, y: 30), color: .black, bold: false)
        pdf.endPDFPage()
    }
    page("Page 1: Text") { ctx in
        let attributed = NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(), CGPath(rect: CGRect(x: 72, y: 100, width: 468, height: 580), transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }
    page("Page 2: Shapes and a table") { ctx in
        ctx.setFillColor(color(0.9, 0.3, 0.3)); ctx.fillEllipse(in: CGRect(x: 90, y: 500, width: 140, height: 140))
        ctx.setFillColor(color(0.3, 0.6, 0.9)); ctx.fill(CGRect(x: 250, y: 500, width: 140, height: 140))
        ctx.setFillColor(color(0.3, 0.8, 0.4)); ctx.move(to: CGPoint(x: 480, y: 640)); ctx.addLine(to: CGPoint(x: 410, y: 500)); ctx.addLine(to: CGPoint(x: 550, y: 500)); ctx.fillPath()
        ctx.setStrokeColor(.black); ctx.setLineWidth(1)
        for row in 0...4 { ctx.stroke(CGRect(x: 90, y: 380 - row * 40, width: 432, height: 40)) }
        for (row, cells) in [["Item", "Qty", "Price"], ["Apples", "4", "$2.00"], ["Pears", "2", "$1.50"], ["Plums", "12", "$3.60"], ["Total", "18", "$7.10"]].enumerated() {
            for (column, cell) in cells.enumerated() { text(ctx, cell, size: 14, at: CGPoint(x: 162 + column * 144, y: 394 - row * 40), color: .black, bold: row == 0 || row == 4) }
        }
    }
    page("Page 3: A picture") { ctx in
        ctx.saveGState(); ctx.clip(to: CGRect(x: 72, y: 200, width: 468, height: 440))
        gradient(ctx, color(1, 0.55, 0.2), color(0.35, 0.2, 0.6), from: CGPoint(x: 72, y: 200), to: CGPoint(x: 540, y: 640))
        ctx.restoreGState()
        ctx.setFillColor(color(1, 1, 1, 0.9)); ctx.fillEllipse(in: CGRect(x: 380, y: 480, width: 100, height: 100))
    }
    pdf.closePDF()
}

// A four-second H.264 video.
do {
    let url = root.appendingPathComponent("Media/clip.mp4")
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    let (w, h) = (1280, 720)
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for i in 0..<120 {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let t = CGFloat(i) / 120
        ctx.setFillColor(NSColor(hue: t, saturation: 0.5, brightness: 0.35, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(.white); ctx.fillEllipse(in: CGRect(x: 100 + t * 980, y: 300 + 150 * sin(t * 4 * .pi), width: 100, height: 100))
        text(ctx, String(format: "Rummage test clip  %.1f s", Double(i) / 30), size: 44, at: CGPoint(x: 640, y: 60))
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    precondition(writer.status == .completed, "video: \(String(describing: writer.error))")
}
print("generated")
