/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"
#import "LIFOOperationQueue.h"
#import <ImageIO/ImageIO.h>

NSString *const SDWebImageDownloadStartNotification = @"SDWebImageDownloadStartNotification";
NSString *const SDWebImageDownloadStopNotification = @"SDWebImageDownloadStopNotification";

static NSString *const kProgressCallbackKey = @"progress";
static NSString *const kCompletedCallbackKey = @"completed";

@interface SDWebImageDownloader ()

@property (strong, nonatomic) LIFOOperationQueue *downloadQueue;
@property (strong, nonatomic) NSMutableDictionary *operationsDict;
@property (strong, nonatomic) NSMutableDictionary *URLCallbacks;
@property (strong, nonatomic) NSMutableDictionary *HTTPHeaders;
// This queue is used to serialize the handling of the network responses of all the download operation in a single queue
@property (SDDispatchQueueSetterSementics, nonatomic) dispatch_queue_t barrierQueue;

@end

@implementation SDWebImageDownloader

+ (void)initialize
{
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    if (NSClassFromString(@"SDNetworkActivityIndicator"))
    {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop

        // Remove observer in case it was previously added.
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}

+ (SDWebImageDownloader *)sharedDownloader
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
        _downloadQueue = [[LIFOOperationQueue alloc] initWithMaxConcurrentOperationCount:2];
        _operationsDict = NSMutableDictionary.new;
        _URLCallbacks = NSMutableDictionary.new;
        _HTTPHeaders = [NSMutableDictionary dictionaryWithObject:@"image/webp,image/*;q=0.8" forKey:@"Accept"];
        _barrierQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderBarrierQueue", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)dealloc
{
    [self.downloadQueue cancelAllOperations];
    SDDispatchQueueRelease(_barrierQueue);
}

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field
{
    if (value)
    {
        self.HTTPHeaders[field] = value;
    }
    else
    {
        [self.HTTPHeaders removeObjectForKey:field];
    }
}

- (NSString *)valueForHTTPHeaderField:(NSString *)field
{
    return self.HTTPHeaders[field];
}

- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads
{
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}

- (NSInteger)maxConcurrentDownloads
{
    return _downloadQueue.maxConcurrentOperationCount;
}

- (id<SDWebImageOperation>)downloadImageWithURL:(NSURL *)url resizedTo:(int)pixelSize options:(SDWebImageDownloaderOptions)options progress:(void (^)(NSUInteger, long long))progressBlock completed:(void (^)(UIImage *, NSData *, NSError *, BOOL))completedBlock
{
    __block SDWebImageDownloaderOperation *operation;
    __weak SDWebImageDownloader *wself = self;

    [self addProgressCallback:progressBlock andCompletedBlock:completedBlock forURL:url withScaleSize:pixelSize createCallback:^
    {
        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise
        NSMutableURLRequest *request = [NSMutableURLRequest.alloc initWithURL:url cachePolicy:(options & SDWebImageDownloaderUseNSURLCache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData) timeoutInterval:15];
        request.HTTPShouldHandleCookies = NO;
        request.HTTPShouldUsePipelining = YES;
        request.allHTTPHeaderFields = wself.HTTPHeaders;
        
        NSString *callbackID;
        if (pixelSize)
            callbackID = [[url absoluteString] stringByAppendingString:[NSString stringWithFormat:@"%d",pixelSize]];
        else
            callbackID = [url absoluteString];
        
        operation = [SDWebImageDownloaderOperation.alloc initWithRequest:request resize:pixelSize options:options progress:^(NSUInteger receivedSize, long long expectedSize)
        {
            if (!wself) return;
            SDWebImageDownloader *sself = wself;
            NSArray *callbacksForURL = [sself callbacksForID:callbackID];
            for (NSDictionary *callbacks in callbacksForURL)
            {
                SDWebImageDownloaderProgressBlock callback = callbacks[kProgressCallbackKey];
                if (callback) callback(receivedSize, expectedSize);
            }
        }
        completed:^(UIImage *image, NSData *data, NSError *error, BOOL finished)
        {
            if (!wself) return;
            SDWebImageDownloader *sself = wself;
            NSArray *callbacksForURL = [sself callbacksForID:callbackID];
            if (finished)
            {
                [sself removeCallbacksForID:callbackID];
            }
            for (NSDictionary *callbacks in callbacksForURL)
            {
                SDWebImageDownloaderCompletedBlock callback = callbacks[kCompletedCallbackKey];
                if (callback) callback(image, data, error, finished);
            }
        }
        cancelled:^
        {
            if (!wself) return;
            SDWebImageDownloader *sself = wself;
            [sself removeCallbacksForID:callbackID];
        }];
        
        [wself.operationsDict setObject:operation forKey:callbackID];
        [wself.downloadQueue addOperation:operation];
    }];

    return operation;
}

- (void)addProgressCallback:(void (^)(NSUInteger, long long))progressBlock andCompletedBlock:(void (^)(UIImage *, NSData *data, NSError *, BOOL))completedBlock forURL:(NSURL *)url withScaleSize:(int) pixelSize createCallback:(void (^)())createCallback
{
    // The URL will be used as the key to the callbacks dictionary so it cannot be nil. If it is nil immediately call the completed block with no image or data.
    if(url == nil)
    {
        if (completedBlock != nil)
        {
            completedBlock(nil, nil, nil, NO);
        }
        return;
    }
    
    NSString *callbackID;
    if (pixelSize)
        callbackID = [[url absoluteString] stringByAppendingString:[NSString stringWithFormat:@"%d",pixelSize]];
    else
        callbackID = [url absoluteString];
    
    dispatch_barrier_sync(self.barrierQueue, ^
    {
        BOOL first = NO;
        if (!self.URLCallbacks[callbackID])
        {
            self.URLCallbacks[callbackID] = NSMutableArray.new;
            first = YES;
        }

        // Handle single download of simultaneous download request for the same URL
        NSMutableArray *callbacksForURL = self.URLCallbacks[callbackID];
        NSMutableDictionary *callbacks = NSMutableDictionary.new;
        if (progressBlock) callbacks[kProgressCallbackKey] = [progressBlock copy];
        if (completedBlock) callbacks[kCompletedCallbackKey] = [completedBlock copy];
        [callbacksForURL addObject:callbacks];
        self.URLCallbacks[callbackID] = callbacksForURL;

        if (first)
        {
            createCallback();
        }
        else
        {
            // Reprioritize the operation.
            // LIFOOperationQueue handles this in the addOperation method.
            [self.downloadQueue addOperation:[self.operationsDict objectForKey:callbackID]];
        }
    });
}

- (NSArray *)callbacksForID:(NSString *)callbackID
{
    __block NSArray *callbacksForURL;
    dispatch_sync(self.barrierQueue, ^
    {
        callbacksForURL = self.URLCallbacks[callbackID];
    });
    return [callbacksForURL copy];
}

- (void)removeCallbacksForID:(NSString *)callbackID
{
    dispatch_barrier_sync(self.barrierQueue, ^
    {
        [self.URLCallbacks removeObjectForKey:callbackID];
        [self.operationsDict removeObjectForKey:callbackID];
    });
}

@end
