import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let rect = NSRect(x: 32, y: 32, width: 960, height: 960)
let shape = NSBezierPath(roundedRect: rect, xRadius: 220, yRadius: 220)
let gradient = NSGradient(colors: [NSColor(red:0.08,green:0.65,blue:0.66,alpha:1),NSColor(red:0.02,green:0.24,blue:0.31,alpha:1)])!
gradient.draw(in: shape, angle: 285)
NSColor.white.withAlphaComponent(0.95).setFill()
let heights: [Double] = [100,230,400,560,350,650,460,290,120]
for (i, h) in heights.enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 203+Double(i)*70,y:512-h/2,width:36,height:h),xRadius:18,yRadius:18).fill()
}
image.unlockFocus()
let folder=URL(filePath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let representation=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:representation)
        image.draw(in:NSRect(x:0,y:0,width:pixels,height:pixels));NSGraphicsContext.restoreGraphicsState()
        let name="icon_\(size)x\(size)\(scale==2 ? "@2x" : "").png"
        try representation.representation(using:.png,properties:[:])!.write(to:folder.appending(path:name))
    }
}
