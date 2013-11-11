/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageManager.h"
#import "SDImageThumbnailer.h"
#import "UIImage+GIF.h"
#import <objc/message.h>

@interface SDWebImageCombinedOperation : NSObject <SDWebImageOperation>

@property (assign, nonatomic, getter = isCancelled) BOOL cancelled;
@property (copy, nonatomic) void (^cancelBlock)();
@property (strong, nonatomic) NSOperation *cacheOperation;

@end

@interface SDWebImageManager ()

@property (strong, nonatomic, readwrite) SDImageCache *imageCache;
@property (strong, nonatomic, readwrite) SDWebImageDownloader *imageDownloader;
@property (strong, nonatomic) NSMutableArray *failedURLs;
@property (strong, nonatomic) NSMutableArray *runningOperations;

@end

@implementation SDWebImageManager

+ (id)sharedManager
{
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{instance = self.new;});
    return instance;
}

- (id)init
{
    if ((self = [super init]))
    {
        _imageCache = [self createCache];
        _imageDownloader = SDWebImageDownloader.new;
        _failedURLs = NSMutableArray.new;
        _runningOperations = NSMutableArray.new;
    }
    return self;
}

- (SDImageCache *)createCache
{
    return [SDImageCache sharedImageCache];
}

- (NSString *)cacheKeyForURL:(NSURL *)url
{
    if (self.cacheKeyFilter)
    {
        return self.cacheKeyFilter(url);
    }
    else
    {
        return [url absoluteString];
    }
}

- (BOOL)diskImageExistsForURL:(NSURL *)url
{
    NSString *key = [self cacheKeyForURL:url];
    return [self.imageCache diskImageExistsWithKey:key];
}

- (id<SDWebImageOperation>)downloadWithURL:(NSURL *)url
                      byScalingImageToSize:(int) pixelSize
                                   options:(SDWebImageOptions)options
                                  progress:(SDWebImageDownloaderProgressBlock)progressBlock
                                 completed:(SDWebImageCompletedWithFinishedBlock)completedBlock;
{
    // Invoking this method without a completedBlock is pointless
    NSParameterAssert(completedBlock);
    
    // Very common mistake is to send the URL using NSString object instead of NSURL. For some strange reason, XCode won't
    // throw any warning for this type mismatch. Here we failsafe this error by allowing URLs to be passed as NSString.
    if ([url isKindOfClass:NSString.class])
    {
        url = [NSURL URLWithString:(NSString *)url];
    }
    
    // Prevents app crashing on argument type error like sending NSNull instead of NSURL
    if (![url isKindOfClass:NSURL.class])
    {
        url = nil;
    }
    
    __block SDWebImageCombinedOperation *operation = SDWebImageCombinedOperation.new;
    __weak SDWebImageCombinedOperation *weakOperation = operation;
    
    BOOL isFailedUrl = NO;
    @synchronized(self.failedURLs)
    {
        isFailedUrl = [self.failedURLs containsObject:url];
    }
    
    if (!url || (!(options & SDWebImageRetryFailed) && isFailedUrl))
    {
        dispatch_main_sync_safe(^
                                {
                                    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil];
                                    completedBlock(nil, error, SDImageCacheTypeNone, YES);
                                });
        return operation;
    }
    
    @synchronized(self.runningOperations)
    {
        [self.runningOperations addObject:operation];
    }
    NSString *key = [self cacheKeyForURL:url];
    
    operation.cacheOperation = [self.imageCache queryDiskCacheForKey:key scaledtoSize:pixelSize done:^(UIImage *image, SDImageCacheType cacheType)
                                {
                                    if (operation.isCancelled)
                                    {
                                        @synchronized(self.runningOperations)
                                        {
                                            [self.runningOperations removeObject:operation];
                                        }
                                        
                                        return;
                                    }
                                    
                                    if ((!image || options & SDWebImageRefreshCached) && (![self.delegate respondsToSelector:@selector(imageManager:shouldDownloadImageForURL:)] || [self.delegate imageManager:self shouldDownloadImageForURL:url]))
                                    {
                                        if (image && options & SDWebImageRefreshCached)
                                        {
                                            dispatch_main_sync_safe(^
                                                                    {
                                                                        // If image was found in the cache bug SDWebImageRefreshCached is provided, notify about the cached image
                                                                        // AND try to re-download it in order to let a chance to NSURLCache to refresh it from server.
                                                                        completedBlock(image, nil, cacheType, YES);
                                                                    });
                                        }
                                        
                                        // download if no image or requested to refresh anyway, and download allowed by delegate
                                        SDWebImageDownloaderOptions downloaderOptions = 0;
                                        if (options & SDWebImageLowPriority) downloaderOptions |= SDWebImageDownloaderLowPriority;
                                        if (options & SDWebImageProgressiveDownload) downloaderOptions |= SDWebImageDownloaderProgressiveDownload;
                                        if (options & SDWebImageRefreshCached) downloaderOptions |= SDWebImageDownloaderUseNSURLCache;
                                        if (options & SDWebImageContinueInBackground) downloaderOptions |= SDWebImageDownloaderContinueInBackground;
                                        if (image && options & SDWebImageRefreshCached)
                                        {
                                            // force progressive off if image already cached but forced refreshing
                                            downloaderOptions &= ~SDWebImageDownloaderProgressiveDownload;
                                            // ignore image read from NSURLCache if image if cached but force refreshing
                                            downloaderOptions |= SDWebImageDownloaderIgnoreCachedResponse;
                                        }
                                        id<SDWebImageOperation> subOperation = [self.imageDownloader downloadImageWithURL:url options:downloaderOptions progress:progressBlock completed:^(UIImage *downloadedImage, NSData *data, NSError *error, BOOL finished)
                                                                                {
                                                                                    if (weakOperation.isCancelled)
                                                                                    {
                                                                                        dispatch_main_sync_safe(^
                                                                                                                {
                                                                                                                    completedBlock(nil, nil, SDImageCacheTypeNone, finished);
                                                                                                                });
                                                                                    }
                                                                                    else if (error)
                                                                                    {
                                                                                        dispatch_main_sync_safe(^
                                                                                                                {
                                                                                                                    completedBlock(nil, error, SDImageCacheTypeNone, finished);
                                                                                                                });
                                                                                        
                                                                                        if (error.code != NSURLErrorNotConnectedToInternet)
                                                                                        {
                                                                                            @synchronized(self.failedURLs)
                                                                                            {
                                                                                                [self.failedURLs addObject:url];
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                    else
                                                                                    {
                                                                                        BOOL cacheOnDisk = !(options & SDWebImageCacheMemoryOnly);
                                                                                        
                                                                                        if (options & SDWebImageRefreshCached && image && !downloadedImage)
                                                                                        {
                                                                                            // Image refresh hit the NSURLCache cache, do not call the completion block
                                                                                        }
                                                                                        // NOTE: We don't call transformDownloadedImage delegate method on animated images as most transformation code would mangle it
                                                                                        else if (downloadedImage && !downloadedImage.images && [self.delegate respondsToSelector:@selector(imageManager:transformDownloadedImage:withURL:)])
                                                                                            
                                                                                        {
                                                                                            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^
                                                                                                           {
                                                                                                               UIImage *scaledImage = nil;
                                                                                                               if (pixelSize)
                                                                                                               {
                                                                                                                   // Scale the image.
                                                                                                                   scaledImage = [SDImageThumbnailer thumbnailWithImage:downloadedImage thumbnailsize:pixelSize];
                                                                                                               }
                                                                                                               
                                                                                                               UIImage *transformedImage = [self.delegate imageManager:self transformDownloadedImage:downloadedImage withURL:url];
                                                                                                               UIImage *scaledTransformedImage =nil;
                                                                                                               if (scaledImage)
                                                                                                               {
                                                                                                                   scaledTransformedImage = [self.delegate imageManager:self transformDownloadedImage:scaledTransformedImage withURL:url];
                                                                                                               }
                                                                                                               
                                                                                                               dispatch_main_sync_safe(^
                                                                                                                                       {
                                                                                                                                           if (scaledTransformedImage)
                                                                                                                                           {
                                                                                                                                               completedBlock(scaledTransformedImage, nil, SDImageCacheTypeNone, finished);
                                                                                                                                           }
                                                                                                                                           else
                                                                                                                                           {
                                                                                                                                               completedBlock(transformedImage, nil, SDImageCacheTypeNone, finished);
                                                                                                                                           }
                                                                                                                                           
                                                                                                                                       });
                                                                                                               if (transformedImage && finished)
                                                                                                               {
                                                                                                                   // Store both images if we have a scaled image.
                                                                                                                   if (scaledTransformedImage)
                                                                                                                   {
                                                                                                                       NSString *keyForScaledImage = [SDImageCache keyFromOriginalkey:key forScaleSize:pixelSize];
                                                                                                                       [self.imageCache storeImage:scaledTransformedImage imageData:nil forKey:keyForScaledImage toDisk:cacheOnDisk];
                                                                                                                       
                                                                                                                       NSData *dataToStore = [transformedImage isEqual:downloadedImage] ? data : nil;
                                                                                                                       [self.imageCache storeImage:transformedImage imageData:dataToStore forKey:key toMemory:NO toDisk:cacheOnDisk];
                                                                                                                   }
                                                                                                                   else
                                                                                                                   {
                                                                                                                       NSData *dataToStore = [transformedImage isEqual:downloadedImage] ? data : nil;
                                                                                                                       [self.imageCache storeImage:transformedImage imageData:dataToStore forKey:key toDisk:cacheOnDisk];
                                                                                                                   }
                                                                                                               }
                                                                                                           });
                                                                                        }
                                                                                        else
                                                                                        {
                                                                                            if (pixelSize)
                                                                                            {
                                                                                                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^
                                                                                                               {
                                                                                                                   UIImage *scaledImage = [SDImageThumbnailer thumbnailWithImage:downloadedImage thumbnailsize:pixelSize];
                                                                                                                   NSString *keyForScaledImage = [SDImageCache keyFromOriginalkey:key forScaleSize:pixelSize];
                                                                                                                   
                                                                                                                   dispatch_main_sync_safe(^
                                                                                                                                           {
                                                                                                                                               completedBlock(scaledImage, nil, SDImageCacheTypeNone, finished);
                                                                                                                                           });
                                                                                                                   
                                                                                                                   if (downloadedImage && finished)
                                                                                                                   {
                                                                                                                       //Store both images if we have a scaled image.
                                                                                                                       [self.imageCache storeImage:scaledImage imageData:nil forKey:keyForScaledImage toDisk:cacheOnDisk];
                                                                                                                       [self.imageCache storeImage:downloadedImage imageData:data forKey:key toMemory:NO toDisk:cacheOnDisk];
                                                                                                                   }
                                                                                                               });
                                                                                            }
                                                                                            else
                                                                                            {
                                                                                                dispatch_main_sync_safe(^
                                                                                                                        {
                                                                                                                            completedBlock(downloadedImage, nil, SDImageCacheTypeNone, finished);
                                                                                                                        });
                                                                                                
                                                                                                if (downloadedImage && finished)
                                                                                                {
                                                                                                    [self.imageCache storeImage:downloadedImage imageData:data forKey:key toDisk:cacheOnDisk];
                                                                                                }
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                    
                                                                                    if (finished)
                                                                                    {
                                                                                        @synchronized(self.runningOperations)
                                                                                        {
                                                                                            [self.runningOperations removeObject:operation];
                                                                                        }
                                                                                    }
                                                                                }];
                                        operation.cancelBlock = ^{[subOperation cancel];};
                                    }
                                    else if (image)
                                    {
                                        dispatch_main_sync_safe(^
                                                                {
                                                                    completedBlock(image, nil, cacheType, YES);
                                                                });
                                        @synchronized(self.runningOperations)
                                        {
                                            [self.runningOperations removeObject:operation];
                                        }
                                    }
                                    else
                                    {
                                        // Image not in cache and download disallowed by delegate
                                        dispatch_main_sync_safe(^
                                                                {
                                                                    completedBlock(nil, nil, SDImageCacheTypeNone, YES);
                                                                });
                                        @synchronized(self.runningOperations)
                                        {
                                            [self.runningOperations removeObject:operation];
                                        }
                                    }
                                }];
    
    return operation;
}

- (id<SDWebImageOperation>)downloadWithURL:(NSURL *)url options:(SDWebImageOptions)options progress:(SDWebImageDownloaderProgressBlock)progressBlock completed:(SDWebImageCompletedWithFinishedBlock)completedBlock
{
    return [self downloadWithURL:url byScalingImageToSize:nil options:options progress:progressBlock completed:completedBlock];
}

- (void)cancelAll
{
    @synchronized(self.runningOperations)
    {
        [self.runningOperations makeObjectsPerformSelector:@selector(cancel)];
        [self.runningOperations removeAllObjects];
    }
}

- (BOOL)isRunning
{
    return self.runningOperations.count > 0;
}

@end

@implementation SDWebImageCombinedOperation

- (void)setCancelBlock:(void (^)())cancelBlock
{
    if (self.isCancelled)
    {
        if (cancelBlock) cancelBlock();
    }
    else
    {
        _cancelBlock = [cancelBlock copy];
    }
}

- (void)cancel
{
    self.cancelled = YES;
    if (self.cacheOperation)
    {
        [self.cacheOperation cancel];
        self.cacheOperation = nil;
    }
    if (self.cancelBlock)
    {
        self.cancelBlock();
        self.cancelBlock = nil;
    }
}

@end
