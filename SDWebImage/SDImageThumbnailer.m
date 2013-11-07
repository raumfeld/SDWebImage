//
//  Thumbnailer.m
//  RaumfeldControl
//
//  Created by Sven Neumann on 04.03.11.
//  Copyright 2011 Raumfeld. All rights reserved.
//

#import "SDImageThumbnailer.h"
#import "SDWebImageCompat.h"

/**
 Create thumbnails from image data. The implementation
 uses Image I/O and has shown to perform a lot better
 than doing this using UIImage and Core Image.
 */
@implementation SDImageThumbnailer

+ (UIImage *) thumbnailWithImage: (UIImage *) image
                   thumbnailsize: (int) size
{
    NSData *data;
#if TARGET_OS_IPHONE
    data = UIImageJPEGRepresentation(image, (CGFloat)1.0);
#else
    data = [NSBitmapImageRep representationOfImageRepsInArray:image.representations usingType: NSJPEGFileType properties:nil];
#endif
    
    return [self thumbnailWithData: data
                     thumbnailsize: size];
}

+ (UIImage *) thumbnailWithData: (NSData *) data
                  thumbnailsize: (int) size
{
    const CGFloat scale = [[UIScreen mainScreen] scale];
    
    CGImageRef image = SDCreateThumbnailImageFromData (data, size * scale);
    if (! image)
        return nil;
    
    UIImage *thumbnail = [UIImage imageWithCGImage: image
                                             scale: scale
                                       orientation: UIImageOrientationUp];
    CFRelease(image);
    
    return thumbnail;
}

@end
