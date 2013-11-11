//
//  LIFOOperationQueue.m
//
//  Created by Ben Harris on 8/19/12.
//

#import "LIFOOperationQueue.h"

@interface LIFOOperationQueue ()

@property (nonatomic, strong) NSMutableArray *runningOperations;
@property (assign, nonatomic) dispatch_queue_t workingQueue;

- (void)startNextOperation;
- (void)startOperation:(NSOperation *)op;

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

- (void) dealloc
{
    dispatch_release(_workingQueue);
    
}

#pragma mark - Operation Management

//
// Adds an operation to the front of the queue
// Also starts operation on an open thread if possible
//

- (void)addOperation:(NSOperation *)op {
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
    }

    @synchronized(self.runningOperations)
    {
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
    self.operations = [NSMutableArray array];
    
    @synchronized(self.runningOperations)
    {
        for (int i = 0; i < (int)self.runningOperations.count; i++) {
            NSOperation *runningOp = [self.runningOperations objectAtIndex:i];
            [runningOp cancel];
            
            [self.runningOperations removeObject:runningOp];
            i--;
        }
    }
}

#pragma mark - Running Operations

//
// Finds next operation and starts on first open thread
//

- (void)startNextOperation {
    @synchronized(self.operations)
    {
        @synchronized(self.runningOperations)
        {
            if ( !self.operations.count ) {
                return;
            }
        }
//        int runningOpCount;
//        @synchronized(self.runningOperations)
//        {
//            runningOpCount = (int)self.runningOperations.count;
//        }
//        if ( runningOpCount < self.maxConcurrentOperationCount ) {
        if ( (int)self.runningOperations.count < self.maxConcurrentOperationCount ) {
            NSOperation *nextOp = [self nextOperation];
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

- (void)startOperation:(NSOperation *)op  {
    void (^completion)() = [op.completionBlock copy];
    
    NSOperation *blockOp = op;
    
    [op setCompletionBlock:^{
        if (completion) {
            completion();
        }

        @synchronized(self.operations) {
            [self.operations removeObject:blockOp];
        }
        @synchronized(self.runningOperations) {
            [self.runningOperations removeObject:blockOp];
        }

        [self startNextOperation];
    }];

    @synchronized(self.runningOperations) {
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

- (NSOperation *)nextOperation {
    @synchronized(self.operations)
    {
        for (int i = 0; i < (int)self.operations.count; i++) {
            NSOperation *operation = [self.operations objectAtIndex:i];
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
