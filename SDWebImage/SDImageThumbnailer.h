//
//  Thumbnailer.h
//  RaumfeldControl
//
//  Created by Sven Neumann on 04.03.11.
//  Copyright 2011 Raumfeld. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface SDImageThumbnailer : NSObject

+ (UIImage *) thumbnailWithImage: (UIImage *) image
                   thumbnailsize: (int) size;
+ (UIImage *) thumbnailWithData: (NSData *) data
                  thumbnailsize: (int) size;

@end
