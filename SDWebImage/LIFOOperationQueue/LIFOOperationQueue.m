//
//  LIFOOperationQueue.m
//
//  Created by Ben Harris on 8/19/12.
//

#import "LIFOOperationQueue.h"
#import "SDWebImageDownloaderOperation.h"

@interface LIFOOperationQueue ()

@property (nonatomic, strong) NSMutableArray *runningOperations;
@property (nonatomic, strong) dispatch_queue_t workingQueue;

- (void)startNextOperation;
- (void)startOperation:(SDWebImageDownloaderOperation *)op;

@end

@implementation LIFOOperationQueue

@synthesize maxConcurrentOperationCount;
@synthesize operations;
@synthesize runningOperations;

#pragma mark - Initialization

- (id)init {
    self = [super init];
    
    if (self) {
        self.operations = [NSMutableArray array];
        self.runningOperations = [NSMutableArray array];
        self.workingQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloader", DISPATCH_QUEUE_SERIAL);
    }
    
    return self;
}

- (id)initWithMaxConcurrentOperationCount:(int)maxOps {
    self = [self init];
    
    if (self) {
        self.maxConcurrentOperationCount = maxOps;
    }
    
    return self;
}

- (NSInteger) operationCount {
    @synchronized(self.operations) {
        return self.operations.count;
    }
}

#pragma mark - Operation Management

//
// Adds an operation to the front of the queue
// Also starts operation on an open thread if possible
//

- (void)addOperation:(SDWebImageDownloaderOperation *)op {
    @synchronized(self.operations)
    {
        if ( [self.operations containsObject:op] )
        {
            if (!op.isExecuting)
            {
                [self.operations removeObject:op];
                [self.operations insertObject:op atIndex:0];
            }
        }
        else
            [self.operations insertObject:op atIndex:0];
        
        if ( (int)self.runningOperations.count < self.maxConcurrentOperationCount )
            [self startNextOperation];
    }
}

//
// Helper method that creates an NSBlockOperation and adds to the queue
//

- (void)addOperationWithBlock:(void (^)(void))block {
    NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:block];
    
    [self addOperation:op];
}

//
// Attempts to cancel all operations
//

- (void)cancelAllOperations {
    
    @synchronized(self.operations)
    {
        self.operations = [NSMutableArray array];
        
        for (int i = 0; i < (int)self.runningOperations.count; i++) {
            SDWebImageDownloaderOperation *runningOp = [self.runningOperations objectAtIndex:i];
            [runningOp cancel];
            
            [self.runningOperations removeObject:runningOp];
            i--;
        }
    }
}

#pragma mark - Running Operations

- (void) setSuspended:(BOOL)suspended {
    if (_suspended != suspended) {
        _suspended = suspended;
        
        if (suspended) {
            @synchronized(self.runningOperations)
            {
                if ( (int)self.runningOperations.count < self.maxConcurrentOperationCount )
                    [self startNextOperation];
            }
        }
    }
}

//
// Finds next operation and starts on first open thread
//

- (void)startNextOperation {
    @synchronized(self.operations)
    {
        if ( !self.operations.count ) {
            return;
        }
        
        if ( (int)self.runningOperations.count < self.maxConcurrentOperationCount ) {
            SDWebImageDownloaderOperation *nextOp = [self nextOperation];
            if (nextOp) {
                if ( !nextOp.isExecuting ) {
                    [self startOperation:nextOp];
                }
                else {
                    [self startNextOperation];
                }
            }
        }
    }
}

//
// Starts operations
//

- (void)startOperation:(SDWebImageDownloaderOperation *)op  {
    // Return if the queue is suspended.
    if (self.suspended)
        return;
    
    SDWebImageDownloaderCompletedBlock completion = [op.completedBlock copy];
    SDWebImageDownloaderOperation *blockOp = op;
    
    [op setCompletedBlock: ^(UIImage *image, NSData *data, NSError *error, BOOL finished){
        @synchronized(self.operations) {
            [self.operations removeObject:blockOp];
            [self.runningOperations removeObject:blockOp];
        }
        
        if (completion) {
            completion(image, data, error, finished);
        }
        
        [self startNextOperation];
    }];

    @synchronized(self.operations) {
        [self.runningOperations addObject:op];
    }
    
    dispatch_async(self.workingQueue, ^{
        [op start];
    });
}

#pragma mark - Queue Information

//
// Returns next operation that is not already running
//

- (SDWebImageDownloaderOperation *)nextOperation {
    @synchronized(self.operations)
    {
        for (int i = 0; i < (int)self.operations.count; i++) {
            SDWebImageDownloaderOperation *operation = [self.operations objectAtIndex:i];
            @synchronized(self.runningOperations)
            {
                if ( ![self.runningOperations containsObject:operation] && !operation.isExecuting && operation.isReady ) {
                    return operation;
                }
            }
        }
    }
    
    return nil;
}

@end
