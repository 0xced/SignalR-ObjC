//
//  SREventSourceStreamReader.m
//  SignalR
//
//  Created by Alex Billingsley on 6/8/12.
//  Copyright (c) 2011 DyKnow LLC. (http://dyknow.com/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated 
//  documentation files (the "Software"), to deal in the Software without restriction, including without limitation
//  the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and 
//  to permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all copies or substantial portions of 
//  the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
//  THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF 
//  CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER 
//  DEALINGS IN THE SOFTWARE.
//

#import "SREventSourceStreamReader.h"
#import "SRChunkBuffer.h"
#import "SRLog.h"
#import "SRSseEvent.h"

typedef enum {
    initial,
    processing,
    stopped
} SREventSourceStreamReaderState;


@interface SREventSourceStreamReader ()

@property (weak, nonatomic, readwrite) NSOutputStream *stream;
@property (strong, nonatomic, readonly)  SRChunkBuffer *buffer;
@property (assign, nonatomic, readonly)  SREventSourceStreamReaderState reading;
@property (assign, nonatomic, readwrite) NSInteger offset;

- (BOOL)processing;

- (void)processBuffer:(NSData *)buffer read:(NSInteger)read;

- (void)onOpened;
- (void)onMessage:(SRSseEvent *)sseEvent;
- (void)onClosed:(NSError *)error;

@end

@implementation SREventSourceStreamReader   

- (instancetype)initWithStream:(NSOutputStream *)steam {
    if (self = [super init]) {
        _stream = steam;
        _buffer = [[SRChunkBuffer alloc] init];
        _reading = initial;
        _offset = 0;
    }
    return self;
}

- (void)start {
    _stream.delegate = self;
    [_stream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
}

- (BOOL)processing {
    return _reading == processing;
}

- (void)close {
    [self onClosed:nil];
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)eventCode {
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (eventCode) {
            case NSStreamEventOpenCompleted: {
                SRLogServerSentEvents(@"Opened");
                
                _reading = processing;
                [self onOpened];
            } case NSStreamEventHasSpaceAvailable: {
                if (![self processing]) {
                    return;
                }
                
                NSData *buffer = [stream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];
                if ([buffer length] >= 4096) {
                    [self close];
                    return;
                }
                buffer = [buffer subdataWithRange:NSMakeRange(_offset, [buffer length] - _offset)];
                
                NSInteger read = [buffer length];
                if(read > 0) {
                    // Put chunks in the buffer
                    _offset = _offset + read;
                    [self processBuffer:buffer read:read];
                }
                break;
            } case NSStreamEventErrorOccurred: {
                [self onClosed:[stream streamError]];
                break;
            }
            case NSStreamEventEndEncountered:
            case NSStreamEventNone:
            case NSStreamEventHasBytesAvailable:
            default:
                break;
        }
    });
}

- (void)processBuffer:(NSData *)buffer read:(NSInteger)read {
    [_buffer add:buffer length:read];
    
    while ([_buffer hasChunks]) {
        NSString *line = [_buffer readLine];
        
        // No new lines in the buffer so stop processing
        if (line == nil) {
            break;
        }
        
        SRSseEvent *sseEvent = nil;
        if(![SRSseEvent tryParseEvent:line sseEvent:&sseEvent]) {
            continue;
        }
        
        SRLogServerSentEvents(@"SSE READ: %@",sseEvent);
        
        [self onMessage:sseEvent];
    }
}

#pragma mark -
#pragma mark Dispatch Blocks

- (void)onOpened {
    if(self.opened) {
        self.opened();
    }
}

- (void)onMessage:(SRSseEvent *)sseEvent {
    if(self.message) {
        self.message(sseEvent);
    }
}

- (void)onClosed:(NSError *)error; {
    
    SREventSourceStreamReaderState previousState = _reading;
    _reading = stopped;
    
    if (previousState != stopped){
        SRLogServerSentEvents(@"Closed");

        if(self.closed) {
            self.closed(error);
        }
        
        _stream.delegate = nil;
        [_stream close];
    }
}

@end
